defmodule Bitblocks.TipSyncWorker do
  @moduledoc """
  GenServer that continuously monitors and syncs the blockchain tip.

  On each poll cycle it only checks heights from the last known synced
  height up to the current chain tip — typically just a handful of new
  blocks per cycle rather than scanning the entire chain.

  Starts automatically on boot and begins syncing immediately.
  Use SyncWorker or Pipeline for syncing historical block ranges.
  """
  use GenServer
  require Logger

  alias Bitblocks.{Repo, Chain}

  # Check for new blocks every 10 seconds
  @poll_interval_ms 10_000
  # Limit concurrent RPC + DB calls per cycle
  @max_concurrent_tasks 10

  defmodule State do
    defstruct [
      :status,
      :last_synced_height,
      :current_tip,
      :blocks_synced,
      :started_at,
      :last_check_at,
      :errors
    ]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start continuous tip syncing.
  """
  def start_sync do
    GenServer.call(__MODULE__, :start_sync)
  end

  @doc """
  Stop tip syncing.
  """
  def stop_sync do
    GenServer.call(__MODULE__, :stop_sync)
  end

  @doc """
  Get current status.
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Auto-start on boot after a short delay to allow Repo and RpcCache to be ready.
    Process.send_after(self(), :auto_start, 2_000)
    {:ok, %State{status: :idle, blocks_synced: 0, errors: []}}
  end

  @impl true
  def handle_call(:start_sync, _from, %State{status: :running} = state) do
    {:reply, {:error, :already_running}, state}
  end

  @impl true
  def handle_call(:start_sync, _from, _state) do
    {:reply, :ok, running_state()}
  end

  @impl true
  def handle_call(:stop_sync, _from, state) do
    Logger.info("TipSyncWorker: Stopping tip sync")
    {:reply, :ok, %{state | status: :stopped}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  def handle_info(:auto_start, %State{status: :idle} = _state) do
    Logger.info("TipSyncWorker: Auto-starting on boot")
    {:noreply, running_state()}
  end

  def handle_info(:auto_start, state) do
    # Already running or stopped — don't override
    {:noreply, state}
  end

  @impl true
  def handle_info({:block_synced, height}, state) do
    new_height = max(state.last_synced_height || 0, height)

    # Queue transaction fetches for recently synced blocks that don't have txs yet.
    # Only for blocks near the tip — the backfill handles historical blocks.
    maybe_queue_tx_fetch(height)

    {:noreply, %{state | blocks_synced: state.blocks_synced + 1, last_synced_height: new_height}}
  end

  @impl true
  def handle_info(:check_tip, %State{status: :stopped} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_tip, state) do
    current_tip = get_chain_tip()
    from_height = max((state.last_synced_height || 0) - 1, 0)

    if current_tip > from_height do
      Logger.debug("TipSyncWorker: Checking heights #{from_height}..#{current_tip}")
      parent = self()

      Task.start(fn ->
        from_height..current_tip
        |> Task.async_stream(
          fn height -> sync_single_block(height, parent) end,
          max_concurrency: @max_concurrent_tasks,
          timeout: 30_000,
          on_timeout: :kill_task
        )
        |> Stream.run()
      end)
    end

    new_state = %{state | current_tip: current_tip, last_check_at: DateTime.utc_now()}
    Process.send_after(self(), :check_tip, @poll_interval_ms)
    {:noreply, new_state}
  end

  # Private Functions

  defp running_state do
    last_synced =
      case Chain.get_latest_block() do
        nil -> 0
        block -> block.height
      end

    send(self(), :check_tip)

    %State{
      status: :running,
      last_synced_height: last_synced,
      current_tip: get_chain_tip(),
      blocks_synced: 0,
      started_at: DateTime.utc_now(),
      last_check_at: DateTime.utc_now(),
      errors: []
    }
  end

  defp get_chain_tip do
    case Bitblocks.RpcCache.get_blockchain_info() do
      %{"blocks" => tip} when is_integer(tip) -> tip
      _ -> 0
    end
  end

  defp sync_single_block(height, parent) do
    case Repo.get_by(Chain.Block, height: height) do
      %Chain.Block{} ->
        :ok

      nil ->
        case BitcoinsvCli.getblockhash(height) do
          {:error, reason} ->
            Logger.error("TipSyncWorker: Failed to get block hash for height #{height}: #{inspect(reason)}")
            :error

          block_hash when is_binary(block_hash) ->
            case BitcoinsvCli.getblockheader(block_hash, true) do
              {:error, reason} ->
                Logger.error("TipSyncWorker: Failed to fetch header #{height}: #{inspect(reason)}")
                :error

              header when is_map(header) ->
                block_struct = %Chain.Block{
                  hash: block_hash,
                  height: height,
                  num_tx: header["num_tx"] || header["nTx"] || 0,
                  time: header["time"],
                  bits: header["bits"],
                  chainwork: Map.get(header, "chainwork", ""),
                  difficulty: to_string(Map.get(header, "difficulty", "")),
                  mediantime: Map.get(header, "mediantime", header["time"]),
                  merkleroot: header["merkleroot"],
                  prevblockhash: header["previousblockhash"] || "",
                  nextblockhash: Map.get(header, "nextblockhash", ""),
                  nonce: header["nonce"],
                  version: header["version"],
                  tx: [],
                  sync_state: "header_only",
                  timestamp: DateTime.from_unix!(header["time"]) |> DateTime.to_naive()
                }

                case Repo.insert(block_struct |> Ecto.Changeset.change(%{}),
                       on_conflict: :nothing
                     ) do
                  {:ok, _} ->
                    send(parent, {:block_synced, height})
                    :ok

                  {:error, _changeset} ->
                    :error
                end
            end
        end
    end
  end

  # Queue transaction fetch for a newly synced block.
  # Only queues if the block is in a state that needs transactions
  # (header_only or header_synced). Already-completed or queued blocks
  # are skipped. The FetchTransactionsWorker handles confirmation gating.
  defp maybe_queue_tx_fetch(height) do
    case Repo.get_by(Chain.Block, height: height) do
      %Chain.Block{sync_state: state} = block when state in ["header_only", "header_synced"] ->
        Logger.info("TipSyncWorker: Queuing tx fetch for block #{height}")
        Chain.queue_transaction_fetch(block)

      _ ->
        :ok
    end
  end
end
