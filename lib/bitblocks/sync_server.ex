defmodule Bitblocks.SyncServer do
  @moduledoc """
  Single sequential sync loop. Finds the next incomplete block,
  fetches its transactions, marks it complete, moves on.

  One block at a time. No parallelism. No Oban.

  Start/stop via the /sync UI or:

      Bitblocks.SyncServer.start_sync()
      Bitblocks.SyncServer.stop_sync()
      Bitblocks.SyncServer.status()
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Bitblocks.{Repo, Chain}
  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.TransactionParser

  @batch_size Application.compile_env(:bitblocks, :tx_fetch_batch_size, 100)

  # -- Public API --------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_sync, do: GenServer.cast(__MODULE__, :start)
  def stop_sync, do: GenServer.cast(__MODULE__, :stop)

  def status do
    GenServer.call(__MODULE__, :status)
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{running: false, current_block: nil, blocks_completed: 0}}
  end

  @impl true
  def handle_cast(:start, %{running: true} = state) do
    {:noreply, state}
  end

  def handle_cast(:start, state) do
    Logger.info("SyncServer: starting")
    send(self(), :next)
    {:noreply, %{state | running: true, blocks_completed: 0}}
  end

  def handle_cast(:stop, state) do
    Logger.info("SyncServer: stopping")
    {:noreply, %{state | running: false, current_block: nil}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:next, %{running: false} = state) do
    {:noreply, state}
  end

  def handle_info(:next, state) do
    case next_incomplete_block() do
      nil ->
        Logger.info("SyncServer: all blocks complete (#{state.blocks_completed} this run)")
        {:noreply, %{state | running: false, current_block: nil}}

      block ->
        state = %{state | current_block: %{height: block.height, hash: block.hash}}

        case sync_block(block) do
          :ok ->
            state = %{state | blocks_completed: state.blocks_completed + 1}
            # Small delay to avoid hammering the node
            Process.send_after(self(), :next, 100)
            {:noreply, state}

          {:error, reason} ->
            Logger.error("SyncServer: block #{block.height} failed: #{inspect(reason)}, pausing 5s")
            Process.send_after(self(), :next, 5_000)
            {:noreply, state}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Block sync --------------------------------------------------------------

  defp next_incomplete_block do
    from(b in Block,
      where: b.sync_state in ["header_only", "header_synced", "failed"],
      order_by: [asc: b.height],
      limit: 1
    )
    |> Repo.one()
  end

  defp sync_block(block) do
    with {:ok, block} <- ensure_txids(block),
         {:ok, block} <- mark_syncing(block) do
      txids = block.tx || []
      existing = existing_txids(block.hash)
      missing = Enum.reject(txids, &MapSet.member?(existing, &1))

      if missing == [] do
        mark_completed(block)
        :ok
      else
        Logger.info("SyncServer: block #{block.height} — #{length(missing)} txs to fetch")

        case fetch_in_batches(missing, block) do
          :ok ->
            mark_completed(block)
            :ok

          {:error, reason} ->
            mark_failed(block, reason)
            {:error, reason}
        end
      end
    end
  end

  # -- Transaction fetching ----------------------------------------------------

  defp fetch_in_batches(txids, block) do
    txids
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case fetch_and_store_batch(batch, block) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp fetch_and_store_batch(txids, block) do
    case BitcoinsvCli.batch_getrawtransaction(txids, 1) do
      {:ok, results} ->
        Enum.each(txids, fn txid ->
          case Map.get(results, txid) do
            tx when is_map(tx) -> store_tx(tx, block)
            {:error, reason} -> Logger.warning("SyncServer: tx #{txid}: #{inspect(reason)}")
            nil -> Logger.warning("SyncServer: tx #{txid}: no result")
          end
        end)
        :ok

      {:error, reason} ->
        Logger.error("SyncServer: batch RPC failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp store_tx(tx, block) do
    raw = tx["hex"]

    analysis =
      case TransactionParser.analyze(raw) do
        {:ok, meta} -> meta
        _ -> %{}
      end

    inputs = (tx["vin"] || []) |> Enum.map(&Jason.encode!/1)
    outputs = (tx["vout"] || []) |> Enum.map(&Jason.encode!/1)

    tx_data =
      Map.merge(
        %{
          txid: tx["txid"],
          raw: raw,
          block_hash: tx["blockhash"] || block.hash,
          block_height: tx["height"] || block.height,
          version: to_string(tx["version"] || 1),
          inputs: inputs,
          input_txids: TransactionParser.extract_input_txids(inputs),
          outputs: outputs,
          output_addresses: TransactionParser.extract_output_addresses(outputs)
        },
        analysis
      )

    changeset = Transaction.changeset(%Transaction{}, tx_data)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :txid) do
      {:ok, stored_tx} -> Chain.record_spends(stored_tx)
      _ -> :ok
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp ensure_txids(%Block{tx: tx} = block) when is_list(tx) and tx != [] do
    {:ok, block}
  end

  defp ensure_txids(%Block{hash: hash}) do
    Chain.upgrade_block_to_header_synced(hash)
  end

  defp existing_txids(block_hash) do
    from(t in Transaction,
      where: t.block_hash == ^block_hash,
      select: t.txid
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp mark_syncing(block) do
    block
    |> Ecto.Changeset.change(%{
      sync_state: "txs_syncing",
      tx_sync_started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
    |> tap(fn {:ok, b} -> Chain.broadcast_block_update(b); _ -> :ok end)
  end

  defp mark_completed(block) do
    block
    |> Ecto.Changeset.change(%{
      sync_state: "completed",
      tx_sync_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
    |> tap(fn {:ok, b} -> Chain.broadcast_block_update(b); _ -> :ok end)
  end

  defp mark_failed(block, error) do
    block
    |> Ecto.Changeset.change(%{
      sync_state: "failed",
      tx_sync_error: inspect(error),
      tx_sync_attempts: (block.tx_sync_attempts || 0) + 1
    })
    |> Repo.update()
    |> tap(fn {:ok, b} -> Chain.broadcast_block_update(b); _ -> :ok end)
  end
end
