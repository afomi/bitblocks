defmodule Bitblocks.Projections do
  @moduledoc """
  Managed projections (#29): a tenant registers a filter over the ingest-time
  tag columns, and Bitblocks serves the matching transactions. Step 1 of the
  prototype slice in docs/MANAGED_SERVICES.md: the record and its query.
  Hydrate, status and follow build on `query/1`.
  """

  import Ecto.Query

  alias Bitblocks.Chain.Transaction
  alias Bitblocks.Projections.Projection
  alias Bitblocks.Repo

  @doc "Registers a projection; its filter is validated and hashed."
  @spec create(map()) :: {:ok, Projection.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Projection{}
    |> Projection.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetches a projection by id."
  @spec get!(integer()) :: Projection.t()
  def get!(id), do: Repo.get!(Projection, id)

  @doc "Fetches a projection by id, or nil."
  @spec get(integer()) :: Projection.t() | nil
  def get(id), do: Repo.get(Projection, id)

  @doc "Lists projections, optionally for one tenant."
  @spec list(keyword()) :: [Projection.t()]
  def list(opts \\ []) do
    Projection
    |> then(fn q ->
      case opts[:tenant] do
        nil -> q
        tenant -> where(q, [p], p.tenant == ^tenant)
      end
    end)
    |> order_by([p], asc: p.tenant, asc: p.name)
    |> Repo.all()
  end

  @doc """
  The transactions a projection matches, as a query.

  Each filter column becomes `column @> values` (array containment), which the
  column's GIN index serves. Avoid `value = ANY(column)` here: GIN can't serve
  it, so on the full `transactions` table it is a sequential scan.
  """
  @spec query(Projection.t()) :: Ecto.Query.t()
  def query(%Projection{filter: filter}) do
    Enum.reduce(filter, from(t in Transaction), fn {column, values}, q ->
      # Validated against Projection.tag_columns/0, so the atom is known.
      field = String.to_existing_atom(column)
      where(q, [t], fragment("? @> ?", field(t, ^field), type(^values, {:array, :string})))
    end)
  end

  @default_limit 100
  @max_limit 500

  @doc """
  Hydrate: one page of a projection's confirmed history, oldest first.

  Ordered by `(block_height, txid)` and frozen at `snapshot_height`, so a block
  that confirms mid-paging never shifts a page; the tenant switches to follow
  for anything newer. The first page's snapshot is the highest stored block
  (or `:snapshot_height`); later pages carry it inside the opaque cursor.

  Options: `:cursor`, `:limit` (default #{@default_limit}, max #{@max_limit}),
  `:snapshot_height` (first page only).

  Starts at the projection's `from_height`. `complete` says whether every
  block from there to the snapshot is fully synced (see `status/1`). When it
  is false, the set is partial: a tx backfilled below a cursor after that page
  was served is not revisited, so the tenant re-hydrates once it is true.
  """
  @spec hydrate(Projection.t(), keyword()) ::
          {:ok,
           %{
             txs: [Transaction.t()],
             next_cursor: String.t() | nil,
             snapshot_height: integer() | nil,
             complete: boolean()
           }}
          | {:error, :invalid_cursor}
  def hydrate(%Projection{} = projection, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)

    with {:ok, position} <- start_position(projection, opts) do
      {snapshot, after_key} = position
      page = if snapshot, do: fetch_page(projection, snapshot, after_key, limit), else: []
      {txs, rest} = Enum.split(page, limit)

      next_cursor =
        case {rest, List.last(txs)} do
          {[_ | _], last} -> encode_cursor(projection.id, snapshot, last)
          _ -> nil
        end

      {:ok,
       %{
         txs: txs,
         next_cursor: next_cursor,
         snapshot_height: snapshot,
         complete: complete_through?(projection, snapshot)
       }}
    end
  end

  defp start_position(projection, opts) do
    case Keyword.get(opts, :cursor) do
      nil -> {:ok, {Keyword.get_lazy(opts, :snapshot_height, &tip_height/0), nil}}
      cursor -> decode_cursor(projection.id, cursor)
    end
  end

  defp tip_height, do: Repo.one(from b in Bitblocks.Chain.Block, select: max(b.height))

  # Fetches one row past the limit, so a full last page doesn't hand out a
  # cursor to an empty page.
  defp fetch_page(projection, snapshot, after_key, limit) do
    projection
    |> query()
    |> where([t], t.block_height >= ^projection.from_height and t.block_height <= ^snapshot)
    |> after_key(after_key)
    |> order_by([t], asc: t.block_height, asc: t.txid)
    |> limit(^(limit + 1))
    |> Repo.all()
  end

  defp after_key(query, nil), do: query

  defp after_key(query, {height, txid}),
    do: where(query, [t], fragment("(?, ?) > (?, ?)", t.block_height, t.txid, ^height, ^txid))

  # A cursor is opaque to tenants: base64url JSON of
  # [projection_id, snapshot_height, last_block_height, last_txid].
  defp encode_cursor(id, snapshot, %Transaction{block_height: height, txid: txid}),
    do: [id, snapshot, height, txid] |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp decode_cursor(id, cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [^id, snapshot, height, txid]}
         when is_integer(snapshot) and is_integer(height) and is_binary(txid) <-
           Jason.decode(json) do
      {:ok, {snapshot, {height, txid}}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_id, _cursor), do: {:error, :invalid_cursor}

  @doc """
  Status: how far a projection's index is complete, from its `from_height`.

  `indexed_through_height` is the last height `h` such that every block in
  `[from_height, h]` is stored and `completed` (its transactions fetched and
  analyzed). A missing block is a gap, never a pass. `index_state` is
  `"ready"` when that reaches the tip, else `"backfilling"`; `lag_blocks` is
  the distance to the tip.

  Block-level: a `completed` block with a tx-count deficit is caught by
  `Release.audit_completeness/1`, which is too heavy to run per request.
  """
  @spec status(Projection.t()) :: %{
          projection_id: integer(),
          from_height: non_neg_integer(),
          tip_height: integer() | nil,
          indexed_through_height: integer(),
          lag_blocks: non_neg_integer(),
          index_state: String.t()
        }
  def status(%Projection{} = projection) do
    tip = tip_height()
    through = indexed_through(projection.from_height, tip)
    lag = if tip, do: max(tip - through, 0), else: 0

    %{
      projection_id: projection.id,
      from_height: projection.from_height,
      tip_height: tip,
      indexed_through_height: through,
      lag_blocks: lag,
      index_state: if(tip && through >= tip, do: "ready", else: "backfilling")
    }
  end

  defp complete_through?(_projection, nil), do: false

  defp complete_through?(projection, snapshot),
    do: indexed_through(projection.from_height, snapshot) >= snapshot

  # Last height h in [from, to] with every block from..h completed; from - 1
  # when the first block is already incomplete. The count is an index-only
  # scan on (sync_state, height); the gap search runs only when it falls short.
  defp indexed_through(from, nil), do: from - 1
  defp indexed_through(from, to) when to < from, do: from - 1

  defp indexed_through(from, to) do
    completed =
      Repo.one(
        from b in Bitblocks.Chain.Block,
          where: b.sync_state == "completed" and b.height >= ^from and b.height <= ^to,
          select: count()
      )

    if completed == to - from + 1 do
      to
    else
      %{rows: [[first_gap]]} =
        Repo.query!(
          """
          SELECT min(h) FROM generate_series($1::integer, $2::integer) AS h
          WHERE NOT EXISTS (
            SELECT 1 FROM blocks b WHERE b.height = h AND b.sync_state = 'completed'
          )
          """,
          [from, to]
        )

      first_gap - 1
    end
  end
end
