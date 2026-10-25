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

  Pages are only complete if the blocks up to the snapshot are fully synced: a
  tx backfilled below a cursor after that page was served is not revisited.
  Status (#29 step 3) reports that, so a tenant knows when to re-hydrate.
  """
  @spec hydrate(Projection.t(), keyword()) ::
          {:ok,
           %{
             txs: [Transaction.t()],
             next_cursor: String.t() | nil,
             snapshot_height: integer() | nil
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

      {:ok, %{txs: txs, next_cursor: next_cursor, snapshot_height: snapshot}}
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
    |> where([t], not is_nil(t.block_height) and t.block_height <= ^snapshot)
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
end
