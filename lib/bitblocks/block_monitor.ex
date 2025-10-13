defmodule Bitblocks.BlockMonitor do
  @moduledoc """
  Monitors the Bitcoin SV blockchain for new blocks in real-time.

  This GenServer polls the Bitcoin node periodically to detect new blocks
  as they're mined and syncs them automatically. It complements the historical
  sync system (SyncWorker) which handles catch-up syncing of past blocks.

  ## Architecture

  - **Historical Sync** (SyncWorker): Downloads blocks from the past (e.g., blocks 0-100000)
  - **Real-time Monitor** (BlockMonitor): Polls for new blocks at the chain tip

  ## Events Broadcasted

  - `{:new_block, block_height, block_hash}` - New block detected
  - `{:block_synced, block}` - Block fully synced with transactions
  - `{:reorg_detected, old_tip, new_tip}` - Blockchain reorganization detected

  ## Usage

  The BlockMonitor starts automatically with the application. Subscribe to events:

  ```elixir
  Phoenix.PubSub.subscribe(Bitblocks.PubSub, "blockchain_events")
  ```

  Control the monitor:

  ```elixir
  # Start monitoring (default: every 10 seconds)
  Bitblocks.BlockMonitor.start_monitoring()

  # Start with custom interval (in milliseconds)
  Bitblocks.BlockMonitor.start_monitoring(5000)

  # Stop monitoring
  Bitblocks.BlockMonitor.stop_monitoring()

  # Get current status
  Bitblocks.BlockMonitor.status()
  ```
  """

  use GenServer
  require Logger

  alias Bitblocks.{Repo, Chain, Sync}
  alias Phoenix.PubSub

  @pubsub Bitblocks.PubSub
  # Poll every 10 seconds
  @default_interval 10_000

  defmodule State do
    defstruct [
      :monitoring,
      :interval,
      :timer_ref,
      :last_known_height,
      :last_known_hash,
      :consecutive_errors
    ]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts monitoring for new blocks.

  ## Parameters
  - `interval` - Polling interval in milliseconds (default: 10000)
  """
  def start_monitoring(interval \\ @default_interval) do
    GenServer.call(__MODULE__, {:start_monitoring, interval})
  end

  @doc """
  Stops monitoring for new blocks.
  """
  def stop_monitoring do
    GenServer.call(__MODULE__, :stop_monitoring)
  end

  @doc """
  Gets the current monitoring status.

  Returns a map with:
  - `:monitoring` - Boolean, whether monitoring is active
  - `:interval` - Polling interval in milliseconds
  - `:last_known_height` - Last synced block height
  - `:last_known_hash` - Last synced block hash
  - `:consecutive_errors` - Number of consecutive polling errors
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Manually triggers a check for new blocks.
  """
  def check_now do
    GenServer.cast(__MODULE__, :check_for_new_blocks)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Get the current chain tip from our database
    initial_state = %State{
      monitoring: false,
      interval: @default_interval,
      timer_ref: nil,
      last_known_height: get_db_tip_height(),
      last_known_hash: get_db_tip_hash(),
      consecutive_errors: 0
    }

    {:ok, initial_state}
  end

  @impl true
  def handle_call({:start_monitoring, interval}, _from, state) do
    # Cancel existing timer if any
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    # Schedule first check
    timer_ref = Process.send_after(self(), :poll_for_blocks, 0)

    new_state = %{state | monitoring: true, interval: interval, timer_ref: timer_ref}

    Logger.info("BlockMonitor: Started monitoring (interval: #{interval}ms)")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stop_monitoring, _from, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    new_state = %{state | monitoring: false, timer_ref: nil}

    Logger.info("BlockMonitor: Stopped monitoring")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      monitoring: state.monitoring,
      interval: state.interval,
      last_known_height: state.last_known_height,
      last_known_hash: state.last_known_hash,
      consecutive_errors: state.consecutive_errors
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:check_for_new_blocks, state) do
    send(self(), :poll_for_blocks)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll_for_blocks, state) do
    new_state = check_for_new_blocks(state)

    # Schedule next poll if still monitoring
    timer_ref =
      if new_state.monitoring do
        Process.send_after(self(), :poll_for_blocks, new_state.interval)
      else
        nil
      end

    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  # Private Functions

  defp check_for_new_blocks(state) do
    case BitcoinsvCli.getblockchaininfo() do
      %{"blocks" => node_height, "bestblockhash" => node_hash} ->
        handle_node_response(state, node_height, node_hash)

      nil ->
        handle_node_error(state)

      error ->
        Logger.error("BlockMonitor: Unexpected response from node: #{inspect(error)}")
        handle_node_error(state)
    end
  end

  defp handle_node_response(state, node_height, node_hash) do
    cond do
      # First time or after restart - initialize
      is_nil(state.last_known_height) ->
        Logger.info("BlockMonitor: Initialized at height #{node_height}")
        broadcast_event({:monitor_initialized, node_height, node_hash})

        %{
          state
          | last_known_height: node_height,
            last_known_hash: node_hash,
            consecutive_errors: 0
        }

      # New block(s) detected
      node_height > state.last_known_height ->
        sync_new_blocks(state, node_height, node_hash)

      # Chain reorganization detected (same height, different hash)
      node_height == state.last_known_height && node_hash != state.last_known_hash ->
        handle_reorg(state, node_height, node_hash)

      # No change
      true ->
        %{state | consecutive_errors: 0}
    end
  end

  defp sync_new_blocks(state, node_height, node_hash) do
    start_height = (state.last_known_height || 0) + 1
    blocks_to_sync = node_height - start_height + 1

    Logger.info(
      "BlockMonitor: New blocks detected! Syncing #{blocks_to_sync} blocks (#{start_height}..#{node_height})"
    )

    broadcast_event({:new_blocks_detected, start_height, node_height, blocks_to_sync})

    # Sync the blocks using the existing Sync module
    case Sync.get_blocks(start_height..node_height) do
      {:ok, synced_blocks} ->
        Logger.info("BlockMonitor: Successfully synced #{length(synced_blocks)} blocks")

        Enum.each(synced_blocks, fn block ->
          broadcast_event({:block_synced, block})
        end)

        %{
          state
          | last_known_height: node_height,
            last_known_hash: node_hash,
            consecutive_errors: 0
        }

      {:error, reason} ->
        Logger.error("BlockMonitor: Failed to sync blocks: #{inspect(reason)}")
        broadcast_event({:sync_error, start_height, node_height, reason})

        # Don't update last_known_height on error, will retry next poll
        %{state | consecutive_errors: state.consecutive_errors + 1}
    end
  end

  defp handle_reorg(state, node_height, node_hash) do
    Logger.warning("BlockMonitor: Chain reorganization detected at height #{node_height}")
    Logger.warning("  Old hash: #{state.last_known_hash}")
    Logger.warning("  New hash: #{node_hash}")

    broadcast_event({:reorg_detected, state.last_known_hash, node_hash, node_height})

    # TODO: Implement reorg handling
    # This would involve:
    # 1. Finding the common ancestor block
    # 2. Marking invalidated blocks/transactions
    # 3. Syncing the new chain branch

    %{state | last_known_height: node_height, last_known_hash: node_hash, consecutive_errors: 0}
  end

  defp handle_node_error(state) do
    consecutive_errors = state.consecutive_errors + 1

    if consecutive_errors == 1 do
      Logger.warning("BlockMonitor: Failed to connect to Bitcoin node")
    end

    if rem(consecutive_errors, 10) == 0 do
      Logger.error("BlockMonitor: #{consecutive_errors} consecutive errors connecting to node")
    end

    %{state | consecutive_errors: consecutive_errors}
  end

  defp get_db_tip_height do
    case Chain.get_latest_block() do
      nil -> nil
      block -> block.height
    end
  end

  defp get_db_tip_hash do
    case Chain.get_latest_block() do
      nil -> nil
      block -> block.hash
    end
  end

  defp broadcast_event(event) do
    PubSub.broadcast(@pubsub, "blockchain_events", event)
  end
end
