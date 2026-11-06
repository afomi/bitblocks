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
  alias Bitblocks.Workers.ProjectionWebhookWorker

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

  @doc """
  Updates a projection's operational settings: `from_height` and `status`
  (active | paused). The filter is the definition, so changing it means a new
  projection.
  """
  @spec update_settings(Projection.t(), map()) ::
          {:ok, Projection.t()} | {:error, Ecto.Changeset.t()}
  def update_settings(%Projection{} = projection, attrs) do
    projection
    |> Projection.changeset(Map.take(attrs, [:from_height, :status]))
    |> Repo.update()
  end

  @doc """
  Sets or clears a projection's webhook. Setting it always rotates the
  secret, so a leaked secret is replaced by re-registering the URL, and clears
  the record of failed deliveries.
  """
  @spec set_webhook(Projection.t(), String.t() | nil) ::
          {:ok, Projection.t()} | {:error, Ecto.Changeset.t()}
  def set_webhook(%Projection{} = projection, url) do
    # Nil the stored secret as a real change, so clearing persists and setting
    # makes Projection.changeset generate a fresh one.
    projection
    |> Ecto.Changeset.change(
      webhook_secret: nil,
      webhook_failures: 0,
      webhook_failed_at: nil,
      webhook_failed_event: nil,
      webhook_failed_status: nil
    )
    |> Projection.changeset(%{webhook_url: url})
    |> Repo.update()
  end

  @doc """
  Records a delivery given up on: its event, and the last status or error,
  scrubbed. Oban keeps a discarded job for only a minute, so this is the record.
  """
  @spec record_webhook_failure(Projection.t(), String.t(), String.t()) :: :ok
  def record_webhook_failure(%Projection{id: id}, event, status) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(p in Projection, where: p.id == ^id)
    |> Repo.update_all(
      inc: [webhook_failures: 1],
      set: [
        webhook_failed_at: now,
        webhook_failed_event: event,
        webhook_failed_status: Bitblocks.Ops.Scrub.line(status),
        updated_at: now
      ]
    )

    :ok
  end

  @doc "Projections with deliveries given up on, the latest first (/syncing)."
  @spec webhook_failures(pos_integer()) :: [Projection.t()]
  def webhook_failures(limit \\ 20) do
    Repo.all(
      from p in Projection,
        where: p.webhook_failures > 0,
        order_by: [desc: p.webhook_failed_at],
        limit: ^limit
    )
  end

  @doc """
  Follow: enqueues one webhook delivery per tx in `block` matching each active
  projection that has a webhook and covers the block's height. Called when a
  block completes on the tip lane. Returns the number of deliveries newly
  enqueued (a repeat call for the same block enqueues none).
  """
  @spec notify_block(Bitblocks.Chain.Block.t()) :: non_neg_integer()
  def notify_block(%Bitblocks.Chain.Block{height: height, hash: hash}) do
    jobs =
      for projection <- webhook_projections(),
          projection.from_height <= height,
          txid <- matching_txids(projection, hash) do
        ProjectionWebhookWorker.new(%{
          projection_id: projection.id,
          event: "tx",
          txid: txid,
          block_height: height,
          block_hash: hash
        })
      end

    jobs |> Enum.map(&Oban.insert!/1) |> Enum.count(&(not &1.conflict?))
  end

  @doc """
  Enqueues a `reorg` event for every active webhook projection: blocks above
  `rewind_height` (the fork point) were orphaned. Returns the count enqueued.
  """
  @spec notify_reorg(integer()) :: non_neg_integer()
  def notify_reorg(rewind_height) do
    for projection <- webhook_projections() do
      %{projection_id: projection.id, event: "reorg", rewind_height: rewind_height}
      # Not unique: two reorgs to the same height are two events.
      |> ProjectionWebhookWorker.new(unique: false)
      |> Oban.insert!()
    end
    |> length()
  end

  defp webhook_projections do
    Repo.all(
      from p in Projection,
        where: p.status == "active" and not is_nil(p.webhook_url),
        order_by: p.id
    )
  end

  defp matching_txids(projection, block_hash) do
    projection
    |> query()
    |> where([t], t.block_hash == ^block_hash)
    |> select([t], t.txid)
    |> Repo.all()
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

  Starts at the projection's `from_height`. `stable_through_height` is the
  last height with every block from there fully synced (see `status/1`), so
  nothing can still appear at or below it. `complete` says this page, and every
  page before it, lies within that stable prefix. A tenant keeps pages while
  `complete` is true, and when it turns false holds that page's cursor and
  comes back from the same place: rows above the first incomplete block aren't
  final, and a tx stored below a cursor already served is not revisited.
  """
  @spec hydrate(Projection.t(), keyword()) ::
          {:ok,
           %{
             txs: [Transaction.t()],
             next_cursor: String.t() | nil,
             snapshot_height: integer() | nil,
             stable_through_height: integer() | nil,
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

      stable = stable_through(projection, snapshot)
      covered = if next_cursor, do: List.last(txs).block_height, else: snapshot

      {:ok,
       %{
         txs: txs,
         next_cursor: next_cursor,
         snapshot_height: snapshot,
         stable_through_height: stable,
         complete: is_integer(covered) and is_integer(stable) and covered <= stable
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
    # A row left under an orphan until `Reorgs.Reconcile` settles it (#34)
    # joins no stored block, so hydrate never returns it.
    |> join(:inner, [t], b in Bitblocks.Chain.Block,
      on: b.hash == t.block_hash and b.height == t.block_height
    )
    |> where([t], t.block_height >= ^projection.from_height and t.block_height <= ^snapshot)
    |> after_key(after_key)
    |> order_by([t], asc: t.block_height, asc: t.txid)
    |> limit(^(limit + 1))
    |> Repo.all()
  end

  defp after_key(query, nil), do: query

  defp after_key(query, {height, txid}),
    do: where(query, [t, _b], fragment("(?, ?) > (?, ?)", t.block_height, t.txid, ^height, ^txid))

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
  analyzed), and `stable_through_height` is the same height under the name
  hydrate uses. A missing block is a gap, never a pass.

  `tip_height` is our newest header, and `node_tip_height` the node's, when we
  know it. `index_state` is `"ready"` when the stable prefix has reached both,
  else `"backfilling"`; `lag_blocks` is the distance to the further of them.

  Block-level: a `completed` block with a tx-count deficit is caught by
  `Release.audit_completeness/1`, which is too heavy to run per request.
  """
  @spec status(Projection.t()) :: %{
          projection_id: integer(),
          from_height: non_neg_integer(),
          tip_height: integer() | nil,
          node_tip_height: integer() | nil,
          indexed_through_height: integer(),
          stable_through_height: integer(),
          lag_blocks: non_neg_integer(),
          index_state: String.t()
        }
  def status(%Projection{} = projection) do
    tip = tip_height()
    node_tip = Bitblocks.SyncProgress.snapshot().overview[:node_tip]
    through = indexed_through(projection.from_height, tip)
    head = [tip, node_tip] |> Enum.filter(&is_integer/1) |> Enum.max(fn -> nil end)
    lag = if head, do: max(head - through, 0), else: 0

    %{
      projection_id: projection.id,
      from_height: projection.from_height,
      tip_height: tip,
      node_tip_height: node_tip,
      indexed_through_height: through,
      stable_through_height: through,
      lag_blocks: lag,
      index_state: if(head && through >= head, do: "ready", else: "backfilling")
    }
  end

  defp stable_through(_projection, nil), do: nil
  defp stable_through(projection, snapshot), do: indexed_through(projection.from_height, snapshot)

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
