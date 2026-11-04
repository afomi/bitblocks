defmodule Bitblocks.SyncProgress do
  @moduledoc """
  One shared, live picture of the sync for the public `/syncing` page.

  Every viewer reads the same snapshot, computed here and nowhere else, so N
  viewers cost the database nothing more than one. The page itself never
  queries.

  ## Where the numbers come from

    * **Per-block progress** (synced x of y, processed x of y) is counted by
      the tx-fetch workers as they walk a block (`SyncProgress.Tracker`) and
      arrives here over PubSub, at most once a second per block. Nothing on
      a timer counts rows in `transactions`.
    * **Which blocks are syncing, and the recently completed ones**, come
      from small bounded queries on `blocks` every `@refresh_ms`, plus the
      `{:block_updated, block}` events `Chain.broadcast_block_update/1`
      already sends on each transition.
    * **The overall picture**: blocks by `sync_state`, our tip, the node's
      tip (`RpcCache`, cached for 10 minutes), the public tip (WhatsOnChain
      `/chain/info`, asked at most every `@public_tip_ms`) and header
      coverage (`StatsCache.blocks_count/0` against our tip).
    * **Processed** means stored with `script_analysis_version` at
      `TransactionParser.script_analysis_version/0` or later.

  A recently completed block finished by a worker on this boot carries the
  worker's final counts. One completed before this boot is counted once, by
  `block_hash` with a 5 second statement timeout, and remembered.

  ## Updates

  Changes mark the snapshot dirty. A one-second tick publishes a dirty
  snapshot on `"sync_progress:snapshot"` as `{:sync_snapshot, snapshot}`,
  so viewers re-render at most once a second whatever the workers do.
  `snapshot/0` reads the latest from ETS without calling the server.

  In tests (`auto_refresh: false`) nothing runs on a timer: call
  `refresh/0` and `flush/0`.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias Bitblocks.{Repo, StatsCache, TransactionParser, Woc}
  alias Bitblocks.Chain.{Block, Transaction, TxidSource}
  alias Bitblocks.SyncProgress.Tracker

  @table __MODULE__
  @topic "sync_progress:snapshot"
  @tick_ms 1_000
  @refresh_ms 30_000
  @public_tip_ms 5 * 60_000
  @recent_limit 10
  @queued_limit 10
  @syncing_limit 20
  @count_timeout_ms 5_000
  @remembered_counts 100

  @syncing_states ["txs_queued", "txs_syncing"]

  # -- Client ------------------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The PubSub topic snapshots are published on."
  def topic, do: @topic

  @doc "Subscribes the caller to snapshot updates."
  def subscribe, do: Phoenix.PubSub.subscribe(Bitblocks.PubSub, @topic)

  @doc "The latest snapshot. An ETS read: never calls the server or the DB."
  def snapshot do
    case :ets.lookup(@table, :snapshot) do
      [{:snapshot, snapshot}] -> snapshot
      [] -> empty_snapshot()
    end
  rescue
    ArgumentError -> empty_snapshot()
  end

  @doc "Reloads from the database now and publishes. Synchronous."
  def refresh, do: GenServer.call(__MODULE__, :refresh, 30_000)

  @doc "Publishes the snapshot now if anything changed. Synchronous."
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc false
  def empty_snapshot do
    %{
      syncing: [],
      queued: [],
      recent: [],
      overview: %{
        our_tip: nil,
        node_tip: nil,
        node_headers: nil,
        public_tip: nil,
        headers_stored: 0,
        states: [],
        queued_count: 0
      },
      analyzer_version: TransactionParser.script_analysis_version(),
      updated_at: nil
    }
  end

  # -- Server ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    :ets.insert(@table, {:snapshot, empty_snapshot()})

    Phoenix.PubSub.subscribe(Bitblocks.PubSub, Tracker.topic())
    Phoenix.PubSub.subscribe(Bitblocks.PubSub, "blocks")

    state = %{
      active: %{},
      recent: [],
      counts: %{},
      counted: MapSet.new(),
      overview: empty_snapshot().overview,
      public_tip: nil,
      public_tip_at: nil,
      dirty: false,
      refreshing: false
    }

    if auto_refresh?() do
      send(self(), :refresh)
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    state = state |> apply_loaded(load(state)) |> publish()
    {:reply, snapshot(), state}
  end

  def handle_call(:flush, _from, state) do
    state = if state.dirty, do: publish(state), else: state
    {:reply, snapshot(), state}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, if(state.dirty, do: publish(state), else: state)}
  end

  # The load runs in a task: a node RPC or a slow count must not stall the
  # progress events this server is merging meanwhile.
  def handle_info(:refresh, %{refreshing: true} = state), do: {:noreply, state}

  def handle_info(:refresh, state) do
    server = self()
    loading = Map.take(state, [:counts, :counted, :public_tip, :public_tip_at])

    Task.start(fn ->
      result =
        try do
          {:ok, load(loading)}
        rescue
          e -> {:error, Exception.message(e)}
        end

      send(server, {:loaded, result})
    end)

    {:noreply, %{state | refreshing: true}}
  end

  def handle_info({:loaded, result}, state) do
    Process.send_after(self(), :refresh, @refresh_ms)
    state = %{state | refreshing: false}

    case result do
      {:ok, loaded} ->
        {:noreply, state |> apply_loaded(loaded) |> Map.put(:dirty, true)}

      {:error, message} ->
        Logger.warning("SyncProgress: refresh failed: #{message}")
        {:noreply, state}
    end
  end

  def handle_info({:sync_progress, progress}, state) do
    entry =
      state.active
      |> Map.get(progress.hash, entry_from_progress(progress))
      |> Map.merge(%{
        sync_state: "txs_syncing",
        lane: progress.lane,
        expected: progress.total,
        stored: progress.stored,
        processed: progress.processed
      })

    {:noreply, %{state | active: Map.put(state.active, progress.hash, entry), dirty: true}}
  end

  def handle_info({:block_updated, %Block{} = block}, state) do
    {:noreply, %{block_updated(state, block) | dirty: true}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Transitions -------------------------------------------------------------

  defp block_updated(state, %Block{sync_state: s} = block) when s in @syncing_states do
    previous = Map.get(state.active, block.hash)

    entry =
      block
      |> entry_from_block()
      |> Map.merge(Map.take(previous || %{}, [:lane, :stored, :processed, :expected]))
      |> Map.put(:sync_state, s)

    %{state | active: Map.put(state.active, block.hash, entry)}
  end

  defp block_updated(state, %Block{sync_state: "completed"} = block) do
    {previous, active} = Map.pop(state.active, block.hash)
    expected = expected(block.num_tx, length(block.tx || []))

    counts =
      case previous do
        %{stored: stored, processed: processed} when is_integer(stored) ->
          remember(state.counts, block.hash, {stored, processed})

        _ ->
          state.counts
      end

    entry =
      block
      |> entry_from_block()
      |> Map.merge(%{sync_state: "completed", lane: previous && previous.lane})
      |> Map.put(:expected, expected)
      |> with_counts(counts)

    recent =
      [entry | Enum.reject(state.recent, &(&1.hash == block.hash))]
      |> Enum.take(@recent_limit)

    %{state | active: active, recent: recent, counts: counts}
  end

  defp block_updated(state, %Block{} = block) do
    %{state | active: Map.delete(state.active, block.hash)}
  end

  # -- Loading (bounded queries only) ------------------------------------------

  defp load(state) do
    syncing = load_syncing()
    recent = load_recent()

    {counts, counted} = count_unknown(recent, state.counts, state.counted)

    {public_tip, public_tip_at} = public_tip(state)

    node = node_tip()
    states = state_counts()
    our_tip = our_tip()

    %{
      active: syncing,
      recent: recent,
      counts: counts,
      counted: counted,
      public_tip: public_tip,
      public_tip_at: public_tip_at,
      overview: %{
        our_tip: our_tip,
        node_tip: node[:blocks],
        node_headers: node[:headers],
        public_tip: public_tip,
        headers_stored: StatsCache.blocks_count(),
        states: states,
        queued_count: Enum.find_value(states, 0, fn {s, n} -> s == "txs_queued" && n end)
      }
    }
  end

  defp apply_loaded(state, loaded) do
    # Progress counted by the workers is fresher than anything loaded: keep it.
    active =
      Map.new(loaded.active, fn entry ->
        previous = Map.get(state.active, entry.hash, %{})
        kept = Map.take(previous, [:stored, :processed, :expected])
        lane = entry.lane || previous[:lane]
        {entry.hash, entry |> Map.merge(kept) |> Map.put(:lane, lane)}
      end)

    counts = Map.merge(loaded.counts, state.counts)

    %{
      state
      | active: active,
        recent: Enum.map(loaded.recent, &with_counts(&1, counts)),
        counts: counts,
        counted: MapSet.union(state.counted, loaded.counted),
        overview: loaded.overview,
        public_tip: loaded.public_tip,
        public_tip_at: loaded.public_tip_at
    }
  end

  @block_fields [:hash, :height, :time, :num_tx, :sync_state, :tx_sync_completed_at]

  # Columns only: the `tx` array can hold 10,000 txids, so it is measured,
  # never loaded. Served by blocks_sync_state_index.
  defp load_syncing do
    syncing =
      from(b in Block,
        where: b.sync_state == "txs_syncing",
        order_by: [desc: b.height],
        limit: @syncing_limit,
        select: map(b, ^@block_fields),
        select_merge: %{tx_len: fragment("coalesce(array_length(?, 1), 0)", b.tx)}
      )
      |> Repo.all()

    queued =
      from(b in Block,
        where: b.sync_state == "txs_queued",
        order_by: [desc: b.height],
        limit: @queued_limit,
        select: map(b, ^@block_fields),
        select_merge: %{tx_len: fragment("coalesce(array_length(?, 1), 0)", b.tx)}
      )
      |> Repo.all()

    rows = syncing ++ queued
    lanes = lanes(Enum.map(rows, & &1.hash))

    Enum.map(rows, fn row ->
      row
      |> entry_from_row()
      |> Map.put(:lane, lane_for(row, lanes))
    end)
  end

  # Served by blocks_tx_sync_completed_at_index (partial, non-null).
  defp load_recent do
    from(b in Block,
      where: not is_nil(b.tx_sync_completed_at) and b.sync_state == "completed",
      order_by: [desc: b.tx_sync_completed_at, desc: b.height],
      limit: @recent_limit,
      select: map(b, ^@block_fields),
      select_merge: %{tx_len: fragment("coalesce(array_length(?, 1), 0)", b.tx)}
    )
    |> Repo.all()
    |> Enum.map(&entry_from_row/1)
  end

  # The live fetch job's queue names the lane. A syncing block with no job is
  # the sequential backfill's (it runs without a per-block job).
  defp lanes([]), do: %{}

  defp lanes(hashes) do
    from(j in Oban.Job,
      where: j.worker == "Bitblocks.Workers.FetchTransactionsWorker",
      where: j.state in ["available", "scheduled", "executing", "retryable"],
      where: fragment("?->>'block_hash'", j.args) in ^hashes,
      select: {fragment("?->>'block_hash'", j.args), j.queue}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp lane_for(%{hash: hash, sync_state: s}, lanes) do
    case Map.get(lanes, hash) do
      nil when s == "txs_syncing" -> "transactions_backfill"
      queue -> queue
    end
  end

  # Index-only scan of blocks_sync_state_index: one row per state.
  defp state_counts do
    from(b in Block, group_by: b.sync_state, select: {b.sync_state, count()})
    |> Repo.all()
    |> Enum.sort_by(fn {_s, n} -> -n end)
  end

  defp our_tip do
    from(b in Block, order_by: [desc: b.height], limit: 1, select: b.height)
    |> Repo.one()
  end

  # RpcCache holds getblockchaininfo for 10 minutes; this asks the cache, and
  # only a cache miss reaches the node.
  defp node_tip do
    case Bitblocks.RpcCache.get_blockchain_info() do
      %{"blocks" => blocks} = info when is_integer(blocks) ->
        %{blocks: blocks, headers: info["headers"]}

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp public_tip(%{public_tip_at: at} = state) when is_integer(at) do
    if System.monotonic_time(:millisecond) - at < @public_tip_ms,
      do: {state.public_tip, at},
      else: fetch_public_tip(state)
  end

  defp public_tip(state), do: fetch_public_tip(state)

  defp fetch_public_tip(state) do
    now = System.monotonic_time(:millisecond)

    case Woc.chain_tip() do
      {:ok, height} -> {height, now}
      # Keep the last good height; try again after the same interval.
      _ -> {state.public_tip, now}
    end
  rescue
    _ -> {state.public_tip, System.monotonic_time(:millisecond)}
  end

  # A completed block finished before this boot: count it once, by
  # block_hash, under a statement timeout. Never retried on failure.
  defp count_unknown(recent, counts, counted) do
    version = TransactionParser.script_analysis_version()

    Enum.reduce(recent, {counts, counted}, fn entry, {counts, counted} ->
      if Map.has_key?(counts, entry.hash) or MapSet.member?(counted, entry.hash) do
        {counts, counted}
      else
        counted = MapSet.put(counted, entry.hash)

        case count_block(entry.hash, version) do
          {:ok, pair} -> {remember(counts, entry.hash, pair), counted}
          :error -> {counts, counted}
        end
      end
    end)
  end

  defp count_block(hash, version) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL statement_timeout = #{@count_timeout_ms}")

      from(t in Transaction,
        where: t.block_hash == ^hash,
        select: {count(), filter(count(), t.script_analysis_version >= ^version)}
      )
      |> Repo.one()
    end)
    |> case do
      {:ok, pair} -> {:ok, pair}
      _ -> :error
    end
  rescue
    e ->
      Logger.info("SyncProgress: skipped counting block #{hash}: #{Exception.message(e)}")
      :error
  end

  defp remember(counts, hash, pair) do
    counts = Map.put(counts, hash, pair)

    if map_size(counts) > @remembered_counts,
      do: counts |> Enum.take(@remembered_counts) |> Map.new() |> Map.put(hash, pair),
      else: counts
  end

  # -- Entries -----------------------------------------------------------------

  defp entry_from_row(row) do
    %{
      hash: row.hash,
      height: row.height,
      time: row.time,
      num_tx: row.num_tx,
      expected: expected(row.num_tx, row.tx_len),
      sync_state: row.sync_state,
      lane: nil,
      stored: nil,
      processed: nil
    }
  end

  defp entry_from_block(%Block{} = block) do
    %{
      hash: block.hash,
      height: block.height,
      time: block.time,
      num_tx: block.num_tx,
      expected: expected(block.num_tx, length(block.tx || [])),
      sync_state: block.sync_state,
      lane: nil,
      stored: nil,
      processed: nil
    }
  end

  defp entry_from_progress(progress) do
    %{
      hash: progress.hash,
      height: progress.height,
      time: progress.time,
      num_tx: progress.num_tx,
      expected: progress.total,
      sync_state: "txs_syncing",
      lane: progress.lane,
      stored: 0,
      processed: 0
    }
  end

  # The header's num_tx is the denominator of record (TxidSource); the stored
  # array's length only stands in when the header carried no count.
  defp expected(num_tx, tx_len) do
    case TxidSource.expected_tx_count(%Block{num_tx: num_tx, tx: nil}) do
      0 -> tx_len || 0
      n -> n
    end
  end

  # A completed block passed the worker's completeness gate, so all of its
  # expected txs are stored. Processed comes from the worker's final count or
  # the one-time count; nil means it was not counted.
  defp with_counts(entry, counts) do
    case Map.get(counts, entry.hash) do
      {_stored, processed} -> %{entry | stored: entry.expected, processed: processed}
      nil -> %{entry | stored: entry.expected, processed: nil}
    end
  end

  # -- Publishing --------------------------------------------------------------

  defp publish(state) do
    snapshot = build(state)
    :ets.insert(@table, {:snapshot, snapshot})
    Phoenix.PubSub.broadcast(Bitblocks.PubSub, @topic, {:sync_snapshot, snapshot})
    %{state | dirty: false}
  end

  defp build(state) do
    entries = Map.values(state.active)

    lane_order = fn entry -> if entry.lane == "transactions_tip", do: 0, else: 1 end

    %{
      syncing:
        entries
        |> Enum.filter(&(&1.sync_state == "txs_syncing"))
        |> Enum.sort_by(&{lane_order.(&1), -&1.height})
        |> Enum.take(@syncing_limit),
      queued:
        entries
        |> Enum.filter(&(&1.sync_state == "txs_queued"))
        |> Enum.sort_by(&(-&1.height))
        |> Enum.take(@queued_limit),
      recent: state.recent,
      overview: state.overview,
      analyzer_version: TransactionParser.script_analysis_version(),
      updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp auto_refresh? do
    Application.get_env(:bitblocks, __MODULE__, []) |> Keyword.get(:auto_refresh, true)
  end
end
