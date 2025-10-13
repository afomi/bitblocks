defmodule Bitblocks.Sync.Pipeline do
  @moduledoc """
  GenStage-based pipeline for parallel blockchain synchronization.

  The pipeline has three stages:
  1. BlockProducer - Fetches block headers (lightweight)
  2. TransactionFetcher - Fetches transactions for each block (heavy, parallel)
  3. DatabaseWriter - Stores blocks and transactions to database

  This allows us to:
  - Download block headers quickly in batches
  - Parallelize transaction fetching across multiple blocks
  - Throttle the pipeline to control load on the Bitcoin node
  - Handle errors gracefully with retry logic

  ## Configuration

  Configure in config/config.exs:

      config :bitblocks, Bitblocks.Sync.Pipeline,
        block_producer_batch_size: 10,
        transaction_fetcher_concurrency: 5,
        database_writer_batch_size: 1

  ## Usage

      # Start the pipeline for a range
      Bitblocks.Sync.Pipeline.start_sync(0, 1000)

      # Get status
      Bitblocks.Sync.Pipeline.status()

      # Stop the pipeline
      Bitblocks.Sync.Pipeline.stop_sync()
  """

  use GenServer
  require Logger
  alias Phoenix.PubSub

  @pubsub Bitblocks.PubSub

  defmodule State do
    defstruct [
      :start_height,
      :end_height,
      :current_height,
      :status,
      :started_at,
      :producer_pid,
      :fetchers_pids,
      :writer_pid,
      :blocks_processed,
      :errors
    ]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_sync(start_height, end_height) do
    GenServer.call(__MODULE__, {:start_sync, start_height, end_height})
  end

  def stop_sync do
    GenServer.call(__MODULE__, :stop_sync)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    state = %State{
      status: :idle,
      blocks_processed: 0,
      errors: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_sync, start_height, end_height}, _from, state) do
    if state.status == :running do
      {:reply, {:error, :already_running}, state}
    else
      # Start the pipeline stages
      {:ok, producer} =
        Bitblocks.Sync.BlockProducer.start_link(
          start_height: start_height,
          end_height: end_height,
          parent: self()
        )

      concurrency = Application.get_env(:bitblocks, :transaction_fetcher_concurrency, 5)

      {:ok, fetchers} =
        Enum.map(1..concurrency, fn id ->
          {:ok, pid} =
            Bitblocks.Sync.TransactionFetcher.start_link(
              id: id,
              subscribe_to: [producer],
              parent: self()
            )

          pid
        end)

      {:ok, writer} =
        Bitblocks.Sync.DatabaseWriter.start_link(
          subscribe_to: fetchers,
          parent: self()
        )

      new_state = %{
        state
        | start_height: start_height,
          end_height: end_height,
          current_height: start_height,
          status: :running,
          started_at: DateTime.utc_now(),
          producer_pid: producer,
          fetchers_pids: fetchers,
          writer_pid: writer,
          blocks_processed: 0
      }

      Logger.info("Sync pipeline started: blocks #{start_height}..#{end_height}")
      broadcast_event({:pipeline_started, start_height, end_height})

      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:stop_sync, _from, state) do
    if state.status == :running do
      stop_pipeline(state)
      new_state = %{state | status: :stopped}
      Logger.info("Sync pipeline stopped")
      broadcast_event(:pipeline_stopped)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_running}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    progress =
      if state.status == :running do
        total = state.end_height - state.start_height + 1
        (state.blocks_processed / total * 100) |> Float.round(2)
      else
        0
      end

    status = %{
      status: state.status,
      start_height: state.start_height,
      end_height: state.end_height,
      current_height: state.current_height,
      blocks_processed: state.blocks_processed,
      progress_percent: progress,
      errors_count: if(is_list(state.errors), do: length(state.errors), else: 0)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:block_processed, height}, state) do
    new_state = %{
      state
      | blocks_processed: state.blocks_processed + 1,
        current_height: max(state.current_height, height)
    }

    broadcast_progress(new_state)

    # Check if complete
    if new_state.blocks_processed >= new_state.end_height - new_state.start_height + 1 do
      Logger.info("Sync pipeline completed: #{new_state.blocks_processed} blocks")
      broadcast_event(:pipeline_completed)
      stop_pipeline(new_state)
      {:noreply, %{new_state | status: :completed}}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:block_error, height, error}, state) do
    Logger.error("Error syncing block #{height}: #{inspect(error)}")

    new_errors = [{height, error} | state.errors || []]
    new_state = %{state | errors: new_errors}

    broadcast_event({:block_error, height, error})

    {:noreply, new_state}
  end

  # Private Functions

  defp stop_pipeline(state) do
    if state.producer_pid, do: GenServer.stop(state.producer_pid, :normal)
    if state.writer_pid, do: GenServer.stop(state.writer_pid, :normal)
    Enum.each(state.fetchers_pids || [], &GenServer.stop(&1, :normal))
  end

  defp broadcast_event(event) do
    PubSub.broadcast(@pubsub, "sync_pipeline", event)
  end

  defp broadcast_progress(state) do
    total = state.end_height - state.start_height + 1
    progress = (state.blocks_processed / total * 100) |> Float.round(2)

    broadcast_event(
      {:pipeline_progress,
       %{
         blocks_processed: state.blocks_processed,
         current_height: state.current_height,
         total_blocks: total,
         progress_percent: progress
       }}
    )
  end
end
