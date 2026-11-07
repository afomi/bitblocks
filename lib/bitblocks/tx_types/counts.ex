defmodule Bitblocks.TxTypes.Counts do
  @moduledoc """
  How many transactions have each type, for `/types` and `/api/v1/types`
  (afomi/bitblocks#49 phase 2), and the first block each type was seen in.

  Summed from `blocks.type_counts` (the `type_counts` pipeline step), never
  from `transactions`. The range is exact: blocks `0..through_height`, where
  every block is verified complete (`Bitblocks.Sync.complete_through/0`) and
  typed at the current `TxPipeline.version(:type_counts)`. Short of the tip
  the counts are partial, and the summary says which range they cover.

  A tx with two types counts once under each, so the counts don't add up to
  the number of transactions.

  `adoption` holds each type's first appearance and growth over the same range
  (#51): the first height's block time and a txid, and its txs per
  10,000-block bucket. The first txid is one lookup per type, through
  the `block_hash` index, in the one block where that type first appears.

  Cached: this process refreshes the summary every 10
  minutes and keeps it in ETS, so a page view only reads memory (`get/0`).
  The refresh is two queries on `blocks`: the lowest untyped height (on the
  `height` index) and one aggregate over the typed range's `type_counts`.
  Tests and operators can call `refresh/0` directly.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Bitblocks.Chain.{Block, Transaction, TxPipeline}
  alias Bitblocks.Repo

  @table __MODULE__
  @interval :timer.minutes(10)
  @query_timeout 60_000
  # Inlined in the bucket query, so GROUP BY and SELECT match.
  @bucket 10_000

  @type count :: %{txs: non_neg_integer(), first_height: non_neg_integer() | nil}
  @type summary :: %{
          required(:status) => :ok | :pending | :unavailable,
          optional(:through_height) => integer(),
          optional(:complete_through) => integer(),
          optional(:tip) => integer() | nil,
          optional(:version) => pos_integer(),
          optional(:computed_at) => DateTime.t(),
          optional(:types) => %{String.t() => count()},
          optional(:adoption) => %{String.t() => adoption()}
        }
  @type adoption :: %{
          first_txid: String.t() | nil,
          first_time: integer() | nil,
          per_10000_blocks: [%{from_height: non_neg_integer(), txs: non_neg_integer()}]
        }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The cached summary: `%{status: :ok, through_height:, complete_through:,
  tip:, version:, computed_at:, types: %{id => %{txs:, first_height:}}}`, or
  `%{status: :pending}` before the first refresh.
  """
  @spec get() :: summary()
  def get do
    case :ets.lookup(@table, :summary) do
      [{:summary, summary}] -> summary
      [] -> %{status: :pending}
    end
  rescue
    ArgumentError -> %{status: :pending}
  end

  @doc """
  One type's count from a summary: `%{txs:, first_height:}`, with 0 txs for
  a type not seen in the range; nil when the summary has no counts yet.
  """
  @spec count(summary(), String.t()) :: count() | nil
  def count(%{status: :ok, types: types}, id),
    do: Map.get(types, id, %{txs: 0, first_height: nil})

  def count(_summary, _id), do: nil

  @doc "One type's first appearance and buckets from a summary, or nil."
  @spec adoption(summary(), String.t()) :: adoption() | nil
  def adoption(%{status: :ok, adoption: adoption}, id), do: Map.get(adoption, id)
  def adoption(_summary, _id), do: nil

  @doc """
  The range a summary's counts cover, in plain sentences, for the API and
  anywhere else that can't render the page's version.
  """
  @spec coverage_note(summary()) :: String.t()
  def coverage_note(%{status: :ok, through_height: through} = summary) when through >= 0 do
    untyped =
      if through < summary.complete_through,
        do:
          " Blocks #{through + 1} to #{summary.complete_through} are complete and not typed yet.",
        else: ""

    "Counts cover blocks 0 to #{through}, every one verified complete and typed; " <>
      "the highest block we know is #{summary.tip}." <>
      untyped <> " A transaction with several types counts once under each."
  end

  def coverage_note(%{status: :ok, complete_through: complete}) when complete >= 0 do
    "Blocks 0 to #{complete} are verified complete and waiting to be typed, so there are no counts yet."
  end

  def coverage_note(%{status: :ok}),
    do: "No block is verified complete yet, so there are no counts."

  def coverage_note(%{status: :pending}), do: "Counts are being computed."
  def coverage_note(_summary), do: "Counts are unavailable right now."

  @doc "Computes the summary now, stores it for `get/0`, and returns it."
  @spec refresh() :: summary()
  def refresh do
    summary = compute()
    store(summary)
    summary
  rescue
    error ->
      Logger.error("TxTypes.Counts: refresh failed: #{Exception.message(error)}")
      summary = %{status: :unavailable}
      if get().status != :ok, do: store(summary)
      summary
  end

  @doc "Computes the summary from `blocks`, without caching it."
  @spec compute() :: summary()
  def compute do
    tip = Bitblocks.Sync.tip()
    complete_through = Bitblocks.Sync.complete_through(tip)
    version = TxPipeline.version(:type_counts)
    through = typed_through(complete_through, version)
    types = if through >= 0, do: sums(through), else: %{}

    %{
      status: :ok,
      through_height: through,
      complete_through: complete_through,
      tip: tip,
      version: version,
      computed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      types: types,
      adoption: if(types == %{}, do: %{}, else: adoption_of(through, types))
    }
  end

  # The highest H <= complete_through with every block 0..H typed at the
  # current version; -1 when block 0 isn't.
  defp typed_through(complete_through, _version) when complete_through < 0, do: -1

  defp typed_through(complete_through, version) do
    first_untyped =
      Repo.one(
        from(b in Block,
          where: b.height <= ^complete_through,
          where: is_nil(b.type_counts_version) or b.type_counts_version != ^version,
          select: min(b.height)
        ),
        timeout: @query_timeout
      )

    if first_untyped, do: first_untyped - 1, else: complete_through
  end

  defp sums(through) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.key, sum(c.value::bigint)::bigint, min(b.height)
        FROM blocks b, jsonb_each_text(b.type_counts) AS c(key, value)
        WHERE b.height <= $1 AND b.type_counts IS NOT NULL
        GROUP BY c.key
        """,
        [through],
        timeout: @query_timeout
      )

    Map.new(rows, fn [id, txs, first] -> {id, %{txs: txs, first_height: first}} end)
  end

  defp adoption_of(through, types) do
    buckets = buckets(through)
    heights = types |> Enum.map(fn {_id, count} -> count.first_height end) |> Enum.uniq()

    blocks =
      Repo.all(
        from(b in Block,
          where: b.height in ^heights,
          select: {b.height, %{hash: b.hash, time: b.time, tx: b.tx}}
        ),
        timeout: @query_timeout
      )
      |> Map.new()

    Map.new(types, fn {id, %{first_height: height}} ->
      block = Map.get(blocks, height, %{hash: nil, time: nil, tx: []})

      {id,
       %{
         first_txid: first_txid(id, block),
         first_time: block.time,
         per_10000_blocks: Map.get(buckets, id, [])
       }}
    end)
  end

  defp buckets(through) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.key, (b.height / #{@bucket}) * #{@bucket} AS bucket, sum(c.value::bigint)::bigint
        FROM blocks b, jsonb_each_text(b.type_counts) AS c(key, value)
        WHERE b.height <= $1 AND b.type_counts IS NOT NULL
        GROUP BY c.key, bucket
        ORDER BY c.key, bucket
        """,
        [through],
        timeout: @query_timeout
      )

    Enum.group_by(rows, &hd/1, fn [_id, from_height, txs] ->
      %{from_height: from_height, txs: txs}
    end)
  end

  # The earliest in the block's own order when it keeps its list, else the
  # lowest txid, so the answer doesn't move between refreshes.
  defp first_txid(_id, %{hash: nil}), do: nil

  defp first_txid(id, %{hash: hash, tx: list}) do
    typed =
      Repo.all(
        from(t in Transaction,
          where: t.block_hash == ^hash,
          where: fragment("? @> ?::varchar[]", t.tx_types, ^[id]),
          select: t.txid
        ),
        timeout: @query_timeout
      )

    in_order = Enum.find(list || [], &(&1 in typed))
    in_order || Enum.min(typed, fn -> nil end)
  end

  defp store(summary), do: :ets.insert(@table, {:summary, summary})

  # -- Server ------------------------------------------------------------------

  @impl true
  def init(opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    refresh? =
      Keyword.get(opts, :refresh, Application.get_env(:bitblocks, :tx_type_counts_refresh, true))

    if refresh?, do: send(self(), :refresh)
    {:ok, %{refresh: refresh?}}
  end

  @impl true
  def handle_info(:refresh, state) do
    refresh()
    Process.send_after(self(), :refresh, @interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
