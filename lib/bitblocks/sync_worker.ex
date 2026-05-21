defmodule Bitblocks.SyncWorker do
  @moduledoc """
  GenServer that manages blockchain synchronization jobs.
  Supports different sync scopes: all blocks, range, or from block to chain tip.
  """
  use GenServer
  require Logger

  alias Bitblocks.{Repo, Chain}
  alias Bitblocks.Chain.SyncJob
  alias Phoenix.PubSub

  @pubsub Bitblocks.PubSub
  @sync_poll_interval 100

  # Allow tests to inject mock Bitcoin CLI
  defp bitcoin_cli do
    Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)
  end

  defmodule State do
    defstruct [
      :scope,
      :start_block,
      :end_block,
      :current_block,
      :total_blocks,
      :status,
      :started_at,
      :blocks_synced,
      :errors,
      :current_block_tx_count,
      :sync_job_id,
      :current_range,
      :current_block_inflight,
      :current_block_started_at,
      :last_block_started_at,
      :last_block_duration_ms,
      :last_batch_end,
      pending_ranges: [],
      lazy_mode: false
    ]
  end

  # Client API

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Start syncing blocks in the specified range.

  ## Parameters
  - `{start_block, end_block}` - Range of blocks to sync (inclusive)

  ## Examples
      # Sync blocks 0 to current tip
      start_sync({0, 900_000})

      # Sync specific range
      start_sync({750_000, 900_000})

      # Sync from block to tip
      start_sync({800_000, 900_000})
  """
  def start_sync({start_block, end_block} = range, server \\ __MODULE__)
      when is_integer(start_block) and is_integer(end_block) do
    GenServer.call(server, {:start_sync, range}, 60_000)
  end

  def stop_sync(server \\ __MODULE__) do
    GenServer.call(server, :stop_sync)
  end

  def get_status(server \\ __MODULE__) do
    GenServer.call(server, :get_status)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, %State{status: :idle}}
  end

  @impl true
  def handle_call({:start_sync, _range}, _from, %State{status: :running} = state) do
    {:reply, {:error, :already_running}, state}
  end

  @impl true
  def handle_call({:start_sync, {start_block, end_block} = range}, _from, _state) do
    Logger.info("SyncWorker: Starting sync range #{start_block}..#{end_block}")

    range_size = end_block - start_block + 1

    # Use lazy discovery for large ranges to avoid loading entire range into memory
    # Small ranges (<=1000 blocks): Load all missing blocks upfront
    # Large ranges (>1000 blocks): Batch discovery in chunks of 100 blocks
    {initial_ranges, total_missing, is_lazy, batch_end_height} =
      if range_size <= 1_000 do
        # Small range: Calculate all missing blocks eagerly
        ranges = calculate_missing_ranges_chunked(start_block, end_block, 1_000)
        count = count_blocks_in_ranges(ranges)

        Logger.info(
          "SyncWorker: Small range (#{range_size} blocks) - found #{count} missing blocks in #{length(ranges)} ranges"
        )

        {ranges, count, false, nil}
      else
        # Large range: Use lazy mode - check first 100 blocks, then fetch more as needed
        batch_size = 100
        batch_end = min(start_block + batch_size - 1, end_block)
        ranges = calculate_missing_ranges_chunked(start_block, batch_end, 1_000)
        count = count_blocks_in_ranges(ranges)

        Logger.info(
          "SyncWorker: Large range (#{range_size} blocks) - lazy mode, checking first #{batch_size} blocks, found #{count} missing"
        )

        {ranges, count, true, batch_end}
      end

    {current_range, pending_ranges} = pop_next_range(initial_ranges)

    {:ok, sync_job} = create_sync_job(range, start_block, end_block, total_missing)
    Logger.info("SyncWorker: Created sync job ##{sync_job.id}")

    # For lazy mode, always start as :running to allow batch fetching logic to continue
    # even if first batch has no missing blocks
    status =
      if is_lazy do
        :running
      else
        if total_missing > 0, do: :running, else: :completed
      end

    current_block =
      case current_range do
        {range_start, _range_end} -> range_start
        nil -> max(start_block, 0)
      end

    new_state = %State{
      scope: range,
      start_block: start_block,
      end_block: end_block,
      current_block: current_block,
      total_blocks: total_missing,
      status: status,
      started_at: DateTime.utc_now(),
      blocks_synced: 0,
      errors: [],
      current_block_tx_count: 0,
      sync_job_id: sync_job.id,
      current_range: current_range,
      pending_ranges: pending_ranges,
      current_block_inflight: nil,
      current_block_started_at: nil,
      last_block_started_at: nil,
      last_block_duration_ms: nil,
      lazy_mode: is_lazy,
      last_batch_end: batch_end_height
    }

    case status do
      :running ->
        send(self(), :sync_next_block)

      :completed ->
        update_sync_job(sync_job.id, %{
          status: "completed",
          blocks_synced: 0,
          total_blocks: total_missing,
          errors_count: 0,
          completed_at: DateTime.utc_now()
        })
    end

    broadcast_progress(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stop_sync, _from, state) do
    new_state = %{
      state
      | status: :stopped,
        pending_ranges: [],
        current_range: nil,
        current_block_inflight: nil,
        current_block_started_at: nil
    }

    # Update sync job
    if state.sync_job_id do
      update_sync_job(state.sync_job_id, %{
        status: "stopped",
        blocks_synced: state.blocks_synced,
        errors_count: length(state.errors || []),
        error_message: format_errors_for_storage(state.errors),
        completed_at: DateTime.utc_now()
      })
    end

    broadcast_progress(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    # Convert state to a map with calculated fields for display
    status_map =
      state
      |> Map.from_struct()
      |> Map.drop([:pending_ranges, :current_range])
      |> Map.put(:errors_count, if(is_list(state.errors), do: length(state.errors), else: 0))

    {:reply, status_map, state}
  end

  @impl true
  def handle_info(:sync_next_block, %State{status: status} = state)
      when status in [:stopped, :completed] do
    {:noreply, state}
  end

  @impl true
  def handle_info(:sync_next_block, state) do
    case ensure_active_range(state) do
      {:no_work, idle_state} ->
        finalized_state = complete_sync(idle_state)
        {:noreply, finalized_state}

      {:ok, ready_state} ->
        process_current_block(ready_state)
    end
  end

  defp process_current_block(%State{} = state) do
    current_height = state.current_block
    start_time = System.monotonic_time()
    started_at = DateTime.utc_now()

    inflight_state = %{
      state
      | current_block_inflight: current_height,
        current_block_started_at: started_at
    }

    broadcast_progress(inflight_state)

    {updated_state, status, tx_count, error_reason} =
      case sync_block(current_height) do
        {:ok, tx_count} when is_integer(tx_count) ->
          blocks_synced = state.blocks_synced + 1

          new_state = %{
            inflight_state
            | current_block: current_height + 1,
              blocks_synced: blocks_synced,
              current_block_tx_count: tx_count
          }

          {new_state, :success, tx_count, nil}

        {:ok, :skipped} ->
          new_state = %{
            inflight_state
            | current_block: current_height + 1,
              current_block_tx_count: 0
          }

          {new_state, :skipped, 0, nil}

        {:error, reason} ->
          Logger.error("Failed to sync block #{current_height}: #{inspect(reason)}")
          errors = [{current_height, reason} | state.errors || []]

          new_state = %{
            inflight_state
            | current_block: current_height + 1,
              errors: errors,
              current_block_tx_count: 0
          }

          {new_state, :error, 0, reason}
      end

    duration_native = System.monotonic_time() - start_time
    duration_ms = System.convert_time_unit(duration_native, :native, :millisecond)

    telemetry_metadata =
      %{
        mode: :sequential,
        status: status,
        height: current_height,
        scope: state.scope
      }
      |> maybe_put_error(error_reason)

    :telemetry.execute(
      [:bitblocks, :sync, :block_sync],
      %{duration: duration_native, tx_count: tx_count},
      telemetry_metadata
    )

    extended_state =
      updated_state
      |> Map.put(:current_block_inflight, nil)
      |> Map.put(:current_block_started_at, nil)
      |> Map.put(:last_block_started_at, started_at)
      |> Map.put(:last_block_duration_ms, duration_ms)

    broadcast_progress(extended_state)

    if has_pending_work?(extended_state) do
      Process.send_after(self(), :sync_next_block, @sync_poll_interval)
      {:noreply, extended_state}
    else
      final_state = complete_sync(extended_state)
      {:noreply, final_state}
    end
  end

  # Private Functions

  # Sync a block from the Bitcoin node
  # NOTE: We already calculated missing_ranges, so we know this block doesn't exist
  # No need to check DB again - just fetch from RPC
  #
  # Uses header-only mode (verbosity 0) by default for maximum speed.
  # This downloads ~1KB per block instead of up to 256MB for blocks with millions of txs.
  defp sync_block(block_height, opts \\ []) do
    # Default to header-only sync for efficiency
    verbosity = Keyword.get(opts, :verbosity, :header_only)

    try do
      case bitcoin_cli().getblockhash(block_height) do
        {:error, %{"code" => -8}} ->
          Logger.debug("Block height #{block_height} out of range (not yet mined)")
          {:error, :height_out_of_range}

        {:error, reason} ->
          Logger.error("Failed to get block hash for height #{block_height}: #{inspect(reason)}")
          {:error, reason}

        block_hash when is_binary(block_hash) ->
          case verbosity do
            :header_only -> sync_block_header_only(block_height, block_hash)
            :with_txids -> sync_block_by_hash(block_height, block_hash)
            0 -> sync_block_header_only(block_height, block_hash)
            1 -> sync_block_by_hash(block_height, block_hash)
          end

        other ->
          Logger.error(
            "Unexpected response from getblockhash(#{block_height}): #{inspect(other)}"
          )

          {:error, :unexpected_response}
      end
    rescue
      error ->
        Logger.error("Exception syncing block #{block_height}: #{inspect(error)}")
        {:error, error}
    end
  end

  # Sync block header only using getblockheader (verbosity 1)
  # This is ~250,000x faster for blocks with millions of transactions
  # Returns JSON with just header data (~400 bytes) instead of full block (up to 2.3 GB)
  defp sync_block_header_only(block_height, block_hash) do
    try do
      case bitcoin_cli().getblockheader(block_hash, true) do
        {:error, reason} ->
          Logger.error("Failed to fetch block header #{block_height}: #{inspect(reason)}")
          {:error, reason}

        %{
          "hash" => hash,
          "version" => version,
          "previousblockhash" => prevblockhash,
          "merkleroot" => merkleroot,
          "time" => time,
          "bits" => bits,
          "nonce" => nonce,
          "num_tx" => num_tx
        } = header
        when is_map(header) ->
          # Verify hash matches
          if hash != block_hash do
            Logger.error(
              "Hash mismatch for block #{block_height}: expected #{block_hash}, got #{hash}"
            )

            {:error, :hash_mismatch}
          else
            # Extract optional fields
            chainwork = Map.get(header, "chainwork", "")
            difficulty = Map.get(header, "difficulty", "")
            mediantime = Map.get(header, "mediantime", time)
            nextblockhash = Map.get(header, "nextblockhash", "")

            # Store minimal block data
            block_struct = %Bitblocks.Chain.Block{
              hash: hash,
              height: block_height,
              num_tx: num_tx,
              time: time,
              bits: bits,
              chainwork: chainwork,
              difficulty: to_string(difficulty),
              mediantime: mediantime,
              merkleroot: merkleroot,
              prevblockhash: prevblockhash,
              nextblockhash: nextblockhash,
              nonce: nonce,
              version: version,
              tx: [],
              # Mark as header_only sync state
              sync_state: "header_only"
            }

            case Repo.insert(block_struct |> Ecto.Changeset.change(%{}),
                   on_conflict: :nothing
                 ) do
              {:ok, _} ->
                {:ok, num_tx}

              {:error, changeset} ->
                Logger.error(
                  "Failed to insert block #{block_height}: #{inspect(changeset.errors)}"
                )

                {:error, :insert_failed}
            end
          end

        other ->
          Logger.error(
            "Unexpected response from getblockheader(#{block_hash}): #{inspect(other)}"
          )

          {:error, :unexpected_response}
      end
    rescue
      e ->
        Logger.error("Exception syncing block header #{block_height}: #{inspect(e)}")
        {:error, e}
    end
  end

  defp sync_block_by_hash(block_height, block_hash) do
    try do
      case bitcoin_cli().getblock(block_hash, 1) do
        {:error, reason} ->
          # Check if this is a parse error due to response size
          case reason do
            {:parse_error, %{skip: skip_bytes}} when is_integer(skip_bytes) ->
              Logger.warning(
                "Block #{block_height} response too large (#{skip_bytes} bytes skipped), " <>
                  "falling back to header-only sync"
              )

              # Fall back to header-only sync for this massive block
              sync_block_header_only(block_height, block_hash)

            _ ->
              Logger.error(
                "Failed to fetch block #{block_height} (#{block_hash}): #{inspect(reason)}"
              )

              {:error, reason}
          end

        %{
          "hash" => hash,
          "num_tx" => num_tx,
          "time" => timestamp,
          "bits" => bits,
          "chainwork" => chainwork,
          "difficulty" => difficulty,
          "height" => height,
          "mediantime" => mediantime,
          "merkleroot" => merkleroot,
          "nonce" => nonce,
          "size" => size,
          "version" => version,
          "tx" => tx_list
        } = block ->
          # Extract block data successfully
          nextblockhash = Map.get(block, "nextblockhash", "")
          prevblockhash = Map.get(block, "previousblockhash", "")

          # Memory optimization: Don't store tx array for huge blocks (>10k transactions)
          # We store num_tx which is sufficient, and can query transactions table if needed
          tx_array_to_store =
            if length(tx_list) > 10_000 do
              Logger.debug(
                "Block #{height} has #{length(tx_list)} txs, not storing tx array to save memory"
              )

              []
            else
              tx_list
            end

          # Store block with header_synced state (has txid array from verbosity 1)
          block_struct = %Bitblocks.Chain.Block{
            hash: hash,
            num_tx: num_tx,
            time: timestamp,
            bits: bits,
            chainwork: chainwork,
            difficulty: to_string(difficulty),
            height: height,
            mediantime: mediantime,
            merkleroot: merkleroot,
            nextblockhash: nextblockhash,
            prevblockhash: prevblockhash,
            nonce: nonce,
            size: size,
            version: version,
            tx: tx_array_to_store,
            sync_state: "header_synced"
          }

          case Bitblocks.Repo.insert(block_struct |> Ecto.Changeset.change(%{}),
                 on_conflict: :nothing,
                 conflict_target: :hash
               ) do
            {:ok, _} ->
              # Sync transactions if they exist in the response
              if is_list(tx_list) and length(tx_list) > 0 do
                case hd(tx_list) do
                  tx when is_map(tx) ->
                    # Full transaction data
                    sync_transactions(tx_list, hash)

                  _ ->
                    # Just transaction IDs
                    :ok
                end
              end

              {:ok, num_tx}

            {:error, changeset} ->
              {:error, changeset}
          end

        nil ->
          Logger.error("getblock returned nil for #{block_height} (#{block_hash})")
          {:error, :block_not_found}

        other ->
          Logger.error("Unexpected response from getblock for #{block_height}: #{inspect(other)}")
          {:error, :unexpected_response}
      end
    rescue
      e -> {:error, e}
    end
  end

  defp sync_transactions(tx_list, block_hash) do
    Enum.each(tx_list, fn tx ->
      case tx do
        %{"txid" => txid, "hex" => raw} ->
          transaction = %Bitblocks.Chain.Transaction{
            txid: txid,
            raw: raw,
            block_hash: block_hash,
            inputs: [],
            outputs: []
          }

          Bitblocks.Repo.insert(transaction |> Ecto.Changeset.change(%{}))

        _ ->
          :ok
      end
    end)
  end

  defp ensure_active_range(
         %State{current_range: nil, pending_ranges: [], lazy_mode: true} = state
       ) do
    # Lazy mode: fetch next batch of blocks
    if state.last_batch_end && state.last_batch_end < state.end_block do
      batch_size = 100
      batch_start = state.last_batch_end + 1
      batch_end = min(batch_start + batch_size - 1, state.end_block)

      Logger.info("SyncWorker: Lazy mode - fetching next batch #{batch_start}..#{batch_end}")

      new_ranges = calculate_missing_ranges_chunked(batch_start, batch_end, 1_000)
      missing_count = count_blocks_in_ranges(new_ranges)

      if missing_count > 0 do
        Logger.info("SyncWorker: Found #{missing_count} missing blocks in next batch")
        {current_range, pending_ranges} = pop_next_range(new_ranges)

        updated_state = %{
          state
          | current_range: current_range,
            pending_ranges: pending_ranges,
            last_batch_end: batch_end,
            current_block: elem(current_range, 0)
        }

        {:ok, updated_state}
      else
        # No missing blocks in this batch, try next batch
        Logger.debug("SyncWorker: No missing blocks in batch, advancing")

        updated_state = %{state | last_batch_end: batch_end}
        ensure_active_range(updated_state)
      end
    else
      # Reached the end
      {:no_work, state}
    end
  end

  defp ensure_active_range(%State{current_range: nil, pending_ranges: []} = state) do
    {:no_work, %{state | current_block: state.current_block}}
  end

  defp ensure_active_range(%State{current_range: nil, pending_ranges: pending} = state) do
    case pop_next_range(pending) do
      {nil, _rest} ->
        {:no_work, %{state | pending_ranges: []}}

      {range = {range_start, _range_end}, rest} ->
        {:ok, %{state | current_range: range, pending_ranges: rest, current_block: range_start}}
    end
  end

  defp ensure_active_range(%State{current_range: {range_start, _}} = state)
       when state.current_block < range_start do
    {:ok, %{state | current_block: range_start}}
  end

  defp ensure_active_range(%State{current_range: {_, range_end}} = state)
       when state.current_block > range_end do
    ensure_active_range(%{state | current_range: nil})
  end

  defp ensure_active_range(state), do: {:ok, state}

  defp has_pending_work?(%State{current_range: nil, pending_ranges: pending}) do
    pending != []
  end

  defp has_pending_work?(%State{
         current_range: {_start, range_end},
         current_block: current_block,
         pending_ranges: pending
       }) do
    current_block <= range_end or pending != []
  end

  defp complete_sync(%State{status: :completed} = state), do: state
  defp complete_sync(%State{status: :stopped} = state), do: state

  defp complete_sync(%State{} = state) do
    Logger.info("Sync completed! Synced #{state.blocks_synced} blocks")

    new_state = %{
      state
      | status: :completed,
        current_range: nil,
        pending_ranges: [],
        current_block_inflight: nil,
        current_block_started_at: nil
    }

    if state.sync_job_id do
      update_sync_job(state.sync_job_id, %{
        status: "completed",
        blocks_synced: state.blocks_synced,
        total_blocks: state.total_blocks,
        errors_count: length(state.errors || []),
        error_message: format_errors_for_storage(state.errors),
        completed_at: DateTime.utc_now()
      })
    end

    broadcast_progress(new_state)
    new_state
  end

  defp remaining_current_range(%State{current_range: nil}), do: 0

  defp remaining_current_range(%State{current_range: {_range_start, range_end}} = state) do
    cond do
      state.current_block_inflight && state.current_block_inflight <= range_end ->
        max(range_end - state.current_block_inflight, 0)

      state.current_block && state.current_block <= range_end ->
        max(range_end - state.current_block + 1, 0)

      true ->
        0
    end
  end

  defp remaining_current_range(_), do: 0

  defp maybe_put_error(metadata, nil), do: metadata

  defp maybe_put_error(metadata, error) do
    Map.put(metadata, :error, format_error(error))
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  defp format_errors_for_storage(nil), do: nil
  defp format_errors_for_storage([]), do: nil

  defp format_errors_for_storage(errors) when is_list(errors) do
    # Take first 10 errors to avoid extremely long messages
    errors
    |> Enum.take(10)
    |> Enum.map(fn {height, reason} ->
      "Block #{height}: #{format_error(reason)}"
    end)
    |> Enum.join("\n")
    |> then(fn message ->
      if length(errors) > 10 do
        message <> "\n... and #{length(errors) - 10} more errors"
      else
        message
      end
    end)
  end

  defp count_blocks_in_ranges(ranges) do
    Enum.reduce(ranges, 0, fn {range_start, range_end}, acc ->
      acc + range_size({range_start, range_end})
    end)
  end

  defp range_size({range_start, range_end}) when range_start <= range_end do
    range_end - range_start + 1
  end

  defp range_size({_range_start, _range_end}), do: 0

  defp pop_next_range([]), do: {nil, []}
  defp pop_next_range([range | rest]), do: {range, rest}


  defp broadcast_progress(state) do
    progress_percent =
      if state.total_blocks && state.blocks_synced && state.total_blocks > 0 do
        (state.blocks_synced / state.total_blocks * 100) |> Float.round(2)
      else
        0.0
      end

    pending_ranges = state.pending_ranges || []
    pending_blocks = count_blocks_in_ranges(pending_ranges)
    current_range_remaining = remaining_current_range(state)
    queue_depth = pending_blocks + current_range_remaining
    inflight_block = state.current_block_inflight

    PubSub.broadcast(@pubsub, "sync_progress", {
      :sync_progress,
      %{
        status: state.status || :idle,
        scope: state.scope,
        start_block: state.start_block || 0,
        end_block: state.end_block || 0,
        current_block: state.current_block || 0,
        total_blocks: state.total_blocks || 0,
        blocks_synced: state.blocks_synced || 0,
        progress_percent: progress_percent,
        current_block_tx_count: state.current_block_tx_count || 0,
        errors_count: if(is_list(state.errors), do: length(state.errors), else: 0),
        pending_ranges_count: length(pending_ranges),
        pending_blocks: pending_blocks,
        remaining_current_range: current_range_remaining,
        queue_depth: queue_depth,
        current_block_inflight: inflight_block,
        current_block_started_at: state.current_block_started_at,
        last_block_started_at: state.last_block_started_at,
        last_block_duration_ms: state.last_block_duration_ms
      }
    })

    # Update sync job progress periodically
    if state.sync_job_id do
      update_sync_job(state.sync_job_id, %{
        blocks_synced: state.blocks_synced,
        errors_count: length(state.errors || []),
        total_blocks: state.total_blocks
      })
    end
  end

  defp create_sync_job({start_block, end_block}, start_block, end_block, total_blocks) do
    attrs = %{
      scope: "range",
      start_block: start_block,
      end_block: end_block,
      total_blocks: total_blocks,
      status: "running",
      started_at: DateTime.utc_now(),
      blocks_synced: 0,
      errors_count: 0
    }

    %SyncJob{}
    |> SyncJob.changeset(attrs)
    |> Repo.insert()
  end

  defp update_sync_job(sync_job_id, attrs) do
    case Repo.get(SyncJob, sync_job_id) do
      nil ->
        {:error, :not_found}

      sync_job ->
        sync_job
        |> Ecto.Changeset.change(attrs)
        |> Repo.update()
    end
  end

  # Calculates missing block ranges in chunks to avoid loading too many heights into memory.
  # For large ranges, this breaks the calculation into smaller chunks to prevent OOM errors.
  defp calculate_missing_ranges_chunked(start_height, end_height, chunk_size) do
    range_size = end_height - start_height + 1

    if range_size <= chunk_size do
      # Small enough to process in one go
      Chain.missing_block_ranges(start_height, end_height)
    else
      # Break into chunks and process each chunk
      start_height
      |> Stream.iterate(&(&1 + chunk_size))
      |> Stream.take_while(&(&1 <= end_height))
      |> Enum.flat_map(fn chunk_start ->
        chunk_end = min(chunk_start + chunk_size - 1, end_height)
        Chain.missing_block_ranges(chunk_start, chunk_end)
      end)
      |> merge_adjacent_ranges()
    end
  end

  defp merge_adjacent_ranges([]), do: []

  defp merge_adjacent_ranges(ranges) do
    ranges
    |> Enum.sort_by(fn {start, _end} -> start end)
    |> Enum.reduce([], fn {range_start, range_end}, acc ->
      case acc do
        [] ->
          [{range_start, range_end}]

        [{prev_start, prev_end} | rest] when range_start == prev_end + 1 ->
          # Merge adjacent ranges
          [{prev_start, range_end} | rest]

        acc ->
          [{range_start, range_end} | acc]
      end
    end)
    |> Enum.reverse()
  end
end
