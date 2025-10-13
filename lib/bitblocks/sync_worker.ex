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
      pending_ranges: []
    ]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start syncing with a specific scope.

  Scopes:
  - {:all} - Sync all blocks from 0 to current chain tip
  - {:range, start_block, end_block} - Sync specific range
  - {:from_block, start_block} - Sync from block to chain tip (continuous)
  """
  def start_sync(scope) do
    GenServer.call(__MODULE__, {:start_sync, scope})
  end

  def stop_sync do
    GenServer.call(__MODULE__, :stop_sync)
  end

  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, %State{status: :idle}}
  end

  @impl true
  def handle_call({:start_sync, _scope}, _from, %State{status: :running} = state) do
    {:reply, {:error, :already_running}, state}
  end

  @impl true
  def handle_call({:start_sync, scope}, _from, _state) do
    {start_block, end_block, _range_size} = calculate_range(scope)

    missing_ranges = Chain.missing_block_ranges(start_block, end_block)
    total_missing = count_blocks_in_ranges(missing_ranges)
    {current_range, pending_ranges} = pop_next_range(missing_ranges)

    {:ok, sync_job} = create_sync_job(scope, start_block, end_block, total_missing)

    status = if total_missing > 0, do: :running, else: :completed

    current_block =
      case current_range do
        {range_start, _range_end} -> range_start
        nil -> max(start_block, 0)
      end

    new_state = %State{
      scope: scope,
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
      pending_ranges: pending_ranges
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
    new_state = %{state | status: :stopped, pending_ranges: [], current_range: nil}

    # Update sync job
    if state.sync_job_id do
      update_sync_job(state.sync_job_id, %{
        status: "stopped",
        blocks_synced: state.blocks_synced,
        errors_count: length(state.errors || []),
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

    {updated_state, broadcast?} =
      case sync_block(current_height) do
        {:ok, tx_count} when is_integer(tx_count) ->
          blocks_synced = state.blocks_synced + 1

          new_state = %{
            state
            | current_block: current_height + 1,
              blocks_synced: blocks_synced,
              current_block_tx_count: tx_count
          }

          {new_state, rem(blocks_synced, 10) == 0 or blocks_synced == new_state.total_blocks}

        {:ok, :skipped} ->
          new_state = %{state | current_block: current_height + 1, current_block_tx_count: 0}

          {new_state, false}

        {:error, reason} ->
          Logger.error("Failed to sync block #{current_height}: #{inspect(reason)}")
          errors = [{current_height, reason} | state.errors || []]

          new_state = %{
            state
            | current_block: current_height + 1,
              errors: errors,
              current_block_tx_count: 0
          }

          {new_state, false}
      end

    extended_state = maybe_extend_continuous_scope(updated_state)

    if broadcast? do
      broadcast_progress(extended_state)
    end

    if has_pending_work?(extended_state) do
      Process.send_after(self(), :sync_next_block, @sync_poll_interval)
      {:noreply, extended_state}
    else
      final_state = complete_sync(extended_state)
      {:noreply, final_state}
    end
  end

  # Private Functions

  defp sync_block(block_height) do
    try do
      case BitcoinsvCli.getblockhash(block_height) do
        {:error, reason} ->
          Logger.error("Failed to get block hash for height #{block_height}: #{inspect(reason)}")
          {:error, reason}

        block_hash when is_binary(block_hash) ->
          sync_block_by_hash(block_height, block_hash)

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

  defp sync_block_by_hash(block_height, block_hash) do
    try do
      block = BitcoinsvCli.getblock(block_hash, 1)

      if block do
        # Extract block data
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
        } = block

        nextblockhash = Map.get(block, "nextblockhash", "")
        prevblockhash = Map.get(block, "previousblockhash", "")

        # Store block
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
          tx: tx_list
        }

        case Bitblocks.Repo.insert(block_struct |> Ecto.Changeset.change(%{})) do
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
            if unique_violation?(changeset) do
              Logger.debug("Block #{block_height} already persisted, skipping")
              {:ok, :skipped}
            else
              {:error, changeset}
            end
        end
      else
        {:error, :block_not_found}
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

    new_state = %{state | status: :completed, current_range: nil, pending_ranges: []}

    if state.sync_job_id do
      update_sync_job(state.sync_job_id, %{
        status: "completed",
        blocks_synced: state.blocks_synced,
        total_blocks: state.total_blocks,
        errors_count: length(state.errors || []),
        completed_at: DateTime.utc_now()
      })
    end

    broadcast_progress(new_state)
    new_state
  end

  defp maybe_extend_continuous_scope(%State{scope: {:from_block, _}} = state) do
    case get_chain_tip() do
      {:ok, tip} when is_integer(tip) and tip > state.end_block ->
        new_range = {state.end_block + 1, tip}
        new_blocks = range_size(new_range)

        cond do
          state.current_range == nil and state.pending_ranges == [] ->
            %{
              state
              | end_block: tip,
                total_blocks: state.total_blocks + new_blocks,
                current_range: new_range,
                pending_ranges: [],
                current_block: elem(new_range, 0)
            }

          true ->
            %{
              state
              | end_block: tip,
                total_blocks: state.total_blocks + new_blocks,
                pending_ranges: append_pending_range(state.pending_ranges, new_range)
            }
        end

      _ ->
        state
    end
  end

  defp maybe_extend_continuous_scope(state), do: state

  defp append_pending_range([], range), do: [range]

  defp append_pending_range(pending, {new_start, new_end} = new_range) do
    case List.last(pending) do
      {last_start, last_end} when last_end + 1 == new_start ->
        List.replace_at(pending, length(pending) - 1, {last_start, new_end})

      _ ->
        pending ++ [new_range]
    end
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

  defp unique_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp unique_violation?(_), do: false

  defp calculate_range({:all}) do
    case get_chain_tip() do
      {:ok, tip} -> {0, tip, tip + 1}
      _ -> {0, 0, 1}
    end
  end

  defp calculate_range({:range, start_block, end_block}) do
    total = end_block - start_block + 1
    {start_block, end_block, total}
  end

  defp calculate_range({:from_block, start_block}) do
    case get_chain_tip() do
      {:ok, tip} -> {start_block, tip, tip - start_block + 1}
      _ -> {start_block, start_block, 1}
    end
  end

  defp get_chain_tip do
    case BitcoinsvCli.getblockchaininfo() do
      %{"blocks" => blocks} -> {:ok, blocks}
      _ -> {:error, :no_connection}
    end
  end

  defp broadcast_progress(state) do
    progress_percent =
      if state.total_blocks > 0 do
        (state.blocks_synced / state.total_blocks * 100) |> Float.round(2)
      else
        0.0
      end

    PubSub.broadcast(@pubsub, "sync_progress", {
      :sync_progress,
      %{
        status: state.status,
        scope: state.scope,
        start_block: state.start_block,
        end_block: state.end_block,
        current_block: state.current_block,
        total_blocks: state.total_blocks,
        blocks_synced: state.blocks_synced,
        progress_percent: progress_percent,
        current_block_tx_count: state.current_block_tx_count,
        errors_count: if(is_list(state.errors), do: length(state.errors), else: 0)
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

  defp create_sync_job(scope, start_block, end_block, total_blocks) do
    scope_str =
      case scope do
        {:all} -> "all"
        {:range, _, _} -> "range"
        {:from_block, _} -> "from_block"
        _ -> "unknown"
      end

    attrs = %{
      scope: scope_str,
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
end
