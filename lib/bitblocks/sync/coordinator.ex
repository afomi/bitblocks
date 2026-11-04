defmodule Bitblocks.Sync.Coordinator do
  @moduledoc """
  The one process that leads the sync. It owns the cursor
  (`Sync.complete_through/0`), dispatch (which block each worker slot gets,
  lowest first), the concurrency setting, and the state broadcast for
  /syncing and /sync.

  ## One leader in the cluster
  It runs on every node but acts only while its node is Oban's leader
  (`Oban.Peer.leader?/0`, checked every tick). If leadership moves, the old
  leader stops at its next tick and the new one takes over at its own; both
  only read rows and insert jobs that are unique per block, so a tick of
  overlap during a hand-over can't assign a block twice.

  ## Workers are Oban jobs
  Each block is worked by a `FetchTransactionsWorker` job, unique on the
  block hash, holding one worker slot. Jobs are durable: a deploy or a crash
  leaves them in the database, and they resume from their saved offset on
  whichever node picks them up. Supervised tasks would die with the
  coordinator's node and need their own bookkeeping to resume.

  ## Each tick (every second while leader)
    * every `@header_ms`: header sync to the node's tip, with reorgs, and a
      bounded fill of the lowest header gap, in a separate process so a slow
      node never stalls the tick;
    * when a block changed, or every `@dispatch_ms`: dispatch, then
      broadcast `Sync.overview/0` on `"sync_progress"` as
      `{:sync_overview, overview}`. `SyncProgress` merges it into the one
      shared snapshot every viewer reads, so a broadcast costs the same for
      any number of viewers.

  The per-minute `SyncWorker` cron only makes sure this process is alive.
  """

  use GenServer
  require Logger

  alias Bitblocks.Sync
  alias Bitblocks.SyncProgress.Tracker
  alias Bitblocks.Workers.SyncHeadersWorker

  @tick_ms 1_000
  @dispatch_ms 5_000
  @header_ms 60_000
  @gap_headers_per_run 10_000

  # -- Client ------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one tick now and returns the coordinator's state. For tests and the cron."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, 30_000)

  @doc "Starts the coordinator if it isn't running (the cron's job)."
  def ensure_running do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        send(pid, :changed)
        :ok

      nil ->
        Logger.warning("Sync.Coordinator: not running; restarting it")
        Supervisor.restart_child(Bitblocks.Supervisor, __MODULE__)
    end
  end

  # -- Server ------------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Application.get_env(:bitblocks, __MODULE__, [])
    auto? = Keyword.get(opts, :auto, Keyword.get(config, :auto, true))

    Phoenix.PubSub.subscribe(Bitblocks.PubSub, "blocks")
    Phoenix.PubSub.subscribe(Bitblocks.PubSub, Sync.control_topic())

    if auto?, do: Process.send_after(self(), :tick, @tick_ms)

    {:ok,
     %{
       leader?: Keyword.get(opts, :leader?, fn -> Oban.Peer.leader?() end),
       headers?: Keyword.get(opts, :headers, Keyword.get(config, :headers, true)),
       auto?: auto?,
       leading: false,
       changed: true,
       concurrency: nil,
       last_dispatch: nil,
       last_headers: nil,
       header_task: nil
     }}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    state = run_tick(state)
    {:reply, Map.take(state, [:leading, :concurrency]), state}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, run_tick(state)}
  end

  # A block changed state (any node, over PubSub): dispatch on the next tick.
  def handle_info({:block_updated, _block}, state), do: {:noreply, %{state | changed: true}}
  def handle_info({:concurrency, _n}, state), do: {:noreply, %{state | changed: true}}
  def handle_info(:changed, state), do: {:noreply, %{state | changed: true}}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{header_task: ref} = state),
    do: {:noreply, %{state | header_task: nil}}

  def handle_info(_msg, state), do: {:noreply, state}

  # -- The tick ----------------------------------------------------------------

  defp run_tick(state) do
    leader? = safe(fn -> state.leader?.() end, false)

    cond do
      leader? and not state.leading ->
        Logger.info("Sync.Coordinator: leading the sync on #{node()}")
        lead(%{state | leading: true, changed: true, concurrency: nil})

      leader? ->
        lead(state)

      state.leading ->
        Logger.info("Sync.Coordinator: no longer leader on #{node()}; handing over")
        if state.header_task, do: Process.demonitor(state.header_task, [:flush])
        %{state | leading: false, header_task: nil, concurrency: nil}

      true ->
        state
    end
  end

  defp lead(state) do
    now = System.monotonic_time(:millisecond)
    state = maybe_sync_headers(state, now)

    if state.changed or is_nil(state.last_dispatch) or now - state.last_dispatch >= @dispatch_ms do
      concurrency = Sync.concurrency()
      if concurrency != state.concurrency, do: scale_queue(concurrency)

      safe(fn -> Sync.dispatch(concurrency) end, 0)

      safe(
        fn ->
          Phoenix.PubSub.broadcast(
            Bitblocks.PubSub,
            Tracker.topic(),
            {:sync_overview, Map.put(Sync.overview(), :leader, node())}
          )
        end,
        :ok
      )

      %{state | changed: false, last_dispatch: now, concurrency: concurrency}
    else
      state
    end
  end

  defp maybe_sync_headers(%{headers?: false} = state, _now), do: state
  defp maybe_sync_headers(%{header_task: ref} = state, _now) when is_reference(ref), do: state

  defp maybe_sync_headers(state, now) do
    if is_nil(state.last_headers) or now - state.last_headers >= @header_ms do
      {_pid, ref} = spawn_monitor(&sync_headers/0)
      %{state | header_task: ref, last_headers: now}
    else
      state
    end
  end

  # Headers to the node's tip (reorgs resolved), then the lowest gap below
  # our tip, a bounded batch per run.
  defp sync_headers do
    safe(&SyncHeadersWorker.sync_tip/0, :error)

    safe(
      fn ->
        with tip when is_integer(tip) <- Sync.tip(),
             missing when missing < tip <- Sync.first_missing_below(tip) do
          SyncHeadersWorker.sync_range(missing, min(missing + @gap_headers_per_run - 1, tip))
        end
      end,
      :error
    )
  end

  # Worker slots run on any node, so every node's queue may run up to the
  # whole concurrency; dispatch is what bounds the cluster to it.
  defp scale_queue(limit) do
    if Oban.config().testing == :disabled, do: Oban.scale_queue(queue: :sync_blocks, limit: limit)
  rescue
    e -> Logger.warning("Sync.Coordinator: scale_queue failed: #{Exception.message(e)}")
  end

  defp safe(fun, default) do
    fun.()
  rescue
    e ->
      Logger.warning("Sync.Coordinator: #{Exception.message(e)}")
      default
  catch
    :exit, reason ->
      Logger.warning("Sync.Coordinator: #{inspect(reason)}")
      default
  end
end
