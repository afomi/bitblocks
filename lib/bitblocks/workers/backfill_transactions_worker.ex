defmodule Bitblocks.Workers.BackfillTransactionsWorker do
  @moduledoc """
  Sequential backfill: finds the next incomplete block and fetches its
  transactions, then re-enqueues itself for the next one.

  One block at a time, from lowest height upward. Uses batch RPC.

  ## Usage

      # Start backfill
      Bitblocks.Workers.BackfillTransactionsWorker.new(%{})
      |> Oban.insert()

      # Or via Release
      Bitblocks.Release.start_backfill_transactions()
  """

  # Runs on the backfill lane (concurrency 1) so it never competes with tip
  # tx fetching. See Chain.queue_transaction_fetch/2.
  use Oban.Worker,
    queue: :transactions_backfill,
    max_attempts: 3,
    unique: [period: 60, fields: [:worker]]

  require Logger
  import Ecto.Query

  alias Bitblocks.{Repo, Chain}
  alias Bitblocks.Chain.{Block, Transaction}
  alias Bitblocks.TransactionParser

  @batch_size Application.compile_env(:bitblocks, :tx_fetch_batch_size, 100)

  @impl Oban.Worker
  def perform(_job) do
    case next_incomplete_block() do
      nil ->
        Logger.info("BackfillTxs: all blocks complete")
        :ok

      block ->
        Logger.info("BackfillTxs: block #{block.height} (#{block.sync_state})")

        case sync_block(block) do
          :ok ->
            Logger.info("BackfillTxs: block #{block.height} done, scheduling next")
            reschedule()
            :ok

          {:error, reason} ->
            Logger.error("BackfillTxs: block #{block.height} failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  # Find the lowest-height block that isn't completed.
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
        Logger.info("BackfillTxs: block #{block.height} — #{length(missing)} txs to fetch (#{length(txids)} total)")

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
            tx when is_map(tx) ->
              store_tx(tx, block)

            {:error, reason} ->
              Logger.warning("BackfillTxs: tx #{txid} error: #{inspect(reason)}")

            nil ->
              Logger.warning("BackfillTxs: tx #{txid} no result")
          end
        end)

        :ok

      {:error, reason} ->
        Logger.error("BackfillTxs: batch RPC failed: #{inspect(reason)}")
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

  defp reschedule do
    %{}
    |> __MODULE__.new(schedule_in: 1)
    |> Oban.insert()
  end
end
