defmodule Bitblocks.TipSyncWorker do
  @moduledoc """
  GenServer that continuously monitors and syncs the blockchain tip.

  Simple logic:
  - Check chain tip
  - Find all missing block headers from 0 to tip
  - Sync them as fast as possible
  - Repeat every N seconds

  Use this for continuous monitoring of new blocks as they're mined.
  Use SyncWorker or Pipeline for syncing historical block ranges.
  """
  use GenServer
  require Logger

  alias Bitblocks.{Repo, Chain}

  # Check for new blocks every 10 seconds
  @poll_interval_ms 10_000
  # Limit concurrent DB queries
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
    {:ok, %State{status: :idle, blocks_synced: 0, errors: []}}
  end

  @impl true
  def handle_call(:start_sync, _from, %State{status: :running} = state) do
    {:reply, {:error, :already_running}, state}
  end

  @impl true
  def handle_call(:start_sync, _from, _state) do
    Logger.info("TipSyncWorker: Starting continuous tip sync")

    # Get current tip
    current_tip = get_chain_tip()

    # Get last synced block from database
    last_synced =
      case Chain.get_latest_block() do
        nil -> 0
        block -> block.height
      end

    new_state = %State{
      status: :running,
      last_synced_height: last_synced,
      current_tip: current_tip,
      blocks_synced: 0,
      started_at: DateTime.utc_now(),
      last_check_at: DateTime.utc_now(),
      errors: []
    }

    # Start checking immediately
    send(self(), :check_tip)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stop_sync, _from, state) do
    Logger.info("TipSyncWorker: Stopping tip sync")

    new_state = %{state | status: :stopped}

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status_map = Map.from_struct(state)
    {:reply, status_map, state}
  end

  @impl true
  def handle_info({:block_synced, _height}, state) do
    # Get highest block from DB (assumes no missing blocks)
    last_synced =
      case Chain.get_latest_block() do
        nil -> 0
        block -> block.height
      end

    # Update state with latest from DB
    new_state = %{state | blocks_synced: state.blocks_synced + 1, last_synced_height: last_synced}

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check_tip, %State{status: :stopped} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_tip, state) do
    current_tip = get_chain_tip()

    Logger.debug("TipSyncWorker: Checking tip at #{current_tip}")

    # Queue up jobs for 0..tip with limited concurrency
    parent = self()

    # Use Task.async_stream to limit concurrent DB queries
    Task.start(fn ->
      0..current_tip
      |> Task.async_stream(
        fn height -> sync_single_block(height, parent) end,
        max_concurrency: @max_concurrent_tasks,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Stream.run()
    end)

    new_state = %{state | current_tip: current_tip, last_check_at: DateTime.utc_now()}

    # Schedule next check
    Process.send_after(self(), :check_tip, @poll_interval_ms)

    {:noreply, new_state}
  end

  # Private Functions

  defp get_chain_tip do
    case Bitblocks.RpcCache.get_blockchain_info() do
      %{"blocks" => tip} when is_integer(tip) -> tip
      _ -> 0
    end
  end

  defp sync_single_block(height, parent) do
    # Check if block exists in DB
    case Repo.get_by(Chain.Block, height: height) do
      %Chain.Block{} ->
        # Already have it, skip
        :ok

      nil ->
        # Missing, fetch it
        case BitcoinsvCli.getblockhash(height) do
          {:error, _reason} ->
            :error

          block_hash when is_binary(block_hash) ->
            case BitcoinsvCli.getblockheader(block_hash, true) do
              {:error, _reason} ->
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
end
