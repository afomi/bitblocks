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
      :errors,
      fetcher_stats: %{}
    ]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_sync(start_height, end_height) do
    GenServer.call(__MODULE__, {:start_sync, start_height, end_height}, 30_000)
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
      errors: [],
      fetcher_stats: %{}
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

      fetchers =
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
      broadcast_fetcher_stats(new_state)
      broadcast_event({:pipeline_started, start_height, end_height})

      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:stop_sync, _from, state) do
    if state.status == :running do
      stop_pipeline(state)

      new_state = %{
        state
        | status: :stopped,
          fetcher_stats: mark_fetchers_idle(state.fetcher_stats)
      }

      Logger.info("Sync pipeline stopped")
      broadcast_fetcher_stats(new_state)
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
  def handle_info({:fetcher_started, fetcher_id, heights, started_at}, state) do
    fetcher_stats =
      Map.update(
        state.fetcher_stats,
        fetcher_id,
        %{
          status: :running,
          heights: heights,
          started_at: started_at,
          inflight_blocks: length(heights),
          last_duration_ms: nil,
          failures: 0,
          finished_at: nil
        },
        fn existing ->
          existing
          |> Map.put(:status, :running)
          |> Map.put(:heights, heights)
          |> Map.put(:started_at, started_at)
          |> Map.put(:inflight_blocks, length(heights))
        end
      )

    new_state = %{state | fetcher_stats: fetcher_stats}
    broadcast_fetcher_stats(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(
        {:fetcher_finished, fetcher_id, heights, started_at, duration_ms, success_count,
         failure_count},
        state
      ) do
    fetcher_stats =
      Map.update(
        state.fetcher_stats,
        fetcher_id,
        %{
          status: :idle,
          heights: [],
          started_at: started_at,
          inflight_blocks: 0,
          last_duration_ms: duration_ms,
          failures: failure_count,
          finished_at: DateTime.utc_now(),
          last_heights: heights,
          success_count: success_count
        },
        fn existing ->
          existing
          |> Map.put(:status, :idle)
          |> Map.put(:heights, [])
          |> Map.put(:inflight_blocks, 0)
          |> Map.put(:last_duration_ms, duration_ms)
          |> Map.put(:failures, failure_count)
          |> Map.put(:finished_at, DateTime.utc_now())
          |> Map.put(:last_heights, heights)
          |> Map.put(:success_count, success_count)
        end
      )

    new_state = %{state | fetcher_stats: fetcher_stats}
    broadcast_fetcher_stats(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:block_processed, height}, state) do
    # Immediately flush additional block_processed messages to batch process them
    additional_blocks = flush_block_processed_messages([height])

    total_processed = length(additional_blocks)
    max_height = Enum.max(additional_blocks)

    new_state = %{
      state
      | blocks_processed: state.blocks_processed + total_processed,
        current_height: max(state.current_height, max_height)
    }

    # Broadcast progress every 10 blocks (or if we processed more than 10)
    should_broadcast =
      rem(new_state.blocks_processed, 10) == 0 or
        total_processed >= 10

    if should_broadcast do
      broadcast_progress(new_state)

      total = new_state.end_height - new_state.start_height + 1
      percent = (new_state.blocks_processed / total * 100) |> Float.round(2)

      Logger.info(
        "Pipeline progress: #{new_state.blocks_processed}/#{total} blocks (#{percent}%) - current height: #{max_height} (batched #{total_processed})"
      )
    end

    # Check if complete
    if new_state.blocks_processed >= new_state.end_height - new_state.start_height + 1 do
      Logger.info("Sync pipeline completed: #{new_state.blocks_processed} blocks")
      broadcast_event(:pipeline_completed)
      stop_pipeline(new_state)

      final_state = %{
        new_state
        | status: :completed,
          fetcher_stats: mark_fetchers_idle(new_state.fetcher_stats)
      }

      broadcast_fetcher_stats(final_state)
      {:noreply, final_state}
    else
      broadcast_fetcher_stats(new_state)
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

  defp flush_block_processed_messages(acc, max_iterations \\ 1000) do
    # Flush up to max_iterations messages to prevent infinite loops
    if max_iterations > 0 do
      receive do
        {:block_processed, height} ->
          flush_block_processed_messages([height | acc], max_iterations - 1)
      after
        0 -> acc
      end
    else
      acc
    end
  end

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

  defp broadcast_fetcher_stats(%State{} = state) do
    fetchers =
      Enum.map(state.fetcher_stats, fn {id, stats} ->
        stats
        |> Map.put(:id, id)
        |> Map.put(:inflight_blocks, stats[:inflight_blocks] || length(stats[:heights] || []))
      end)

    inflight_blocks =
      Enum.reduce(fetchers, 0, fn stats, acc ->
        case stats[:status] do
          :running -> acc + (stats[:inflight_blocks] || 0)
          _ -> acc
        end
      end)

    total_blocks =
      if state.start_height && state.end_height do
        state.end_height - state.start_height + 1
      else
        0
      end

    remaining_blocks =
      total_blocks
      |> Kernel.-(state.blocks_processed || 0)
      |> Kernel.-(inflight_blocks)
      |> max(0)

    PubSub.broadcast(@pubsub, "sync_pipeline", {
      :fetcher_metrics,
      %{
        status: state.status,
        fetchers: fetchers,
        inflight_blocks: inflight_blocks,
        queue_depth: remaining_blocks
      }
    })
  end

  defp mark_fetchers_idle(fetcher_stats) do
    Enum.reduce(fetcher_stats, %{}, fn {id, stats}, acc ->
      updated =
        stats
        |> Map.put(:status, :idle)
        |> Map.put(:heights, [])
        |> Map.put(:inflight_blocks, 0)

      Map.put(acc, id, updated)
    end)
  end
end
