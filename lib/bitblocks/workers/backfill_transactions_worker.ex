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
  #
  # `txs_syncing` is included deliberately: if a worker died mid-fetch (crash,
  # deploy) the block is left in that state, and excluding it would strand the
  # block forever — no pass would ever pick it back up. `sync_block` recomputes
  # what's missing from what's actually stored, so resuming a `txs_syncing` block
  # is safe and idempotent. This is what makes a restart self-healing.
  defp next_incomplete_block do
    from(b in Block,
      where: b.sync_state in ["header_only", "header_synced", "txs_syncing", "failed"],
      order_by: [asc: b.height],
      limit: 1
    )
    |> Repo.one()
  end

  defp sync_block(block) do
    with {:ok, block} <- ensure_txids(block),
         {:ok, block} <- mark_syncing(block) do
      # Some blocks have millions of txids. Never load the whole missing set or
      # query `txid IN (<millions>)` — process the txid array in fixed-size
      # chunks: for each chunk, ask the DB which of its ≤@batch_size txids are
      # already stored (a bounded IN), fetch only the gaps, store, advance. Each
      # query and each in-memory list is bounded by @batch_size regardless of
      # block size. Idempotent: re-running re-skips what's present.
      case fetch_missing_in_batches(block) do
        :ok ->
          mark_completed(block)
          :ok

        {:error, reason} ->
          mark_failed(block, reason)
          {:error, reason}
      end
    end
  end

  defp fetch_missing_in_batches(%Block{tx: txids} = block) when is_list(txids) do
    txids
    |> Stream.chunk_every(@batch_size)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      existing = existing_txids(chunk)
      missing = Enum.reject(chunk, &MapSet.member?(existing, &1))

      case missing do
        [] ->
          {:cont, :ok}

        _ ->
          case fetch_and_store_batch(missing, block) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
      end
    end)
  end

  defp fetch_missing_in_batches(_block), do: :ok

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

  # Which of THIS block's txids are already stored, keyed by txid (the globally
  # unique key) rather than block_hash. A tx can be stored under another block's
  # hash (reorg, BIP30 dup coinbase); with the unique-txid index, on_conflict
  # :nothing makes its insert a no-op, so a block_hash-scoped query would never
  # see it — the block would compute the same `missing` set forever and never
  # complete (infinite reschedule). Intersecting block.tx with stored txids makes
  # "missing" and "complete" agree and lets the block finish.
  defp existing_txids(txids) when is_list(txids) and txids != [] do
    from(t in Transaction,
      where: t.txid in ^txids,
      select: t.txid
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp existing_txids(_), do: MapSet.new()

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
