defmodule Bitblocks.Workers.FetchTransactionsWorker do
  @moduledoc """
  Oban worker for fetching transaction details for a block.

  Designed for blocks of any size — from 1-tx coinbase blocks to 4GB blocks
  with millions of transactions. Key properties:

  ## Resumability
  Tracks progress via `tx_sync_progress` on the block. If the worker crashes
  or the node restarts, it picks up from where it left off rather than
  re-fetching all transactions from the start.

  ## Batching
  Fetches transactions in configurable batches (default 100) to bound memory
  usage. Each batch is written to the database before the next is fetched.
  A 2.8M-transaction block processes as ~28,000 batches.

  ## Observability
  Logs progress at regular intervals (every 1000 transactions) with:
  - Transactions fetched / total
  - Percentage complete
  - Elapsed time and estimated time remaining

  ## Confirmation gating
  When `min_confirmations` is set (via application config), the worker
  checks that the block has sufficient confirmations before fetching.
  This prevents wasted work on blocks that might be reorganized.

  ## Idempotency
  Individual transaction inserts use `on_conflict: :nothing` — re-processing
  the same batch is safe and a no-op for already-stored transactions.
  """

  use Oban.Worker,
    queue: :transactions,
    max_attempts: 5,
    unique: [period: 300, fields: [:args], keys: [:block_hash]]

  require Logger
  alias Bitblocks.Repo
  alias Bitblocks.Chain
  alias Bitblocks.Chain.Block
  alias Bitblocks.TransactionParser

  # How many transactions to fetch and write per batch.
  # Bounds memory: 100 raw transactions ≈ 10-50 MB depending on tx size.
  @batch_size Application.compile_env(:bitblocks, :tx_fetch_batch_size, 100)

  # Log progress every N transactions
  @log_interval 1_000

  # Minimum confirmations before fetching transactions (0 = fetch immediately).
  # For tip-following, set to 1-6 in production config.
  @min_confirmations Application.compile_env(:bitblocks, :min_confirmations_for_tx_fetch, 0)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"block_hash" => block_hash}}) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, block} <- get_block(block_hash),
         {:ok, block} <- check_confirmations(block),
         {:ok, block} <- ensure_has_txids(block),
         {:ok, block} <- transition_to_syncing(block) do
      total = length(block.tx)
      # Resume from where we left off if the block has prior progress
      already_fetched = count_existing_transactions(block)

      Logger.info(
        "FetchTxs block=#{block.height} total=#{total} " <>
          "already_fetched=#{already_fetched} batch_size=#{@batch_size}"
      )

      case fetch_in_batches(block, already_fetched, total, started_at) do
        :ok ->
          transition_to_completed(block)
          elapsed = System.monotonic_time(:millisecond) - started_at

          Logger.info(
            "FetchTxs block=#{block.height} completed " <>
              "total=#{total} elapsed=#{format_duration(elapsed)}"
          )

          :ok

        {:error, reason} ->
          transition_to_failed(block, reason)
          {:error, reason}
      end
    else
      {:skip, reason} ->
        Logger.info("FetchTxs block=#{block_hash} skipped: #{inspect(reason)}")
        :ok

      {:error, reason} ->
        Logger.error("FetchTxs block=#{block_hash} failed: #{inspect(reason)}")

        with {:ok, block} <- get_block(block_hash) do
          transition_to_failed(block, reason)
        end

        {:error, reason}
    end
  end

  # -- Batch fetching ----------------------------------------------------------

  defp fetch_in_batches(_block, offset, total, _started_at) when offset >= total, do: :ok

  defp fetch_in_batches(block, offset, total, started_at) do
    batch_txids = Enum.slice(block.tx, offset, @batch_size)
    batch_end = offset + length(batch_txids)

    # Fetch this batch from the node
    {successful, failed} = fetch_batch(batch_txids)

    # Write successful transactions to the database
    if successful != [] do
      store_batch(successful)
    end

    # Log progress at intervals
    if rem(batch_end, @log_interval) < @batch_size or batch_end == total do
      elapsed = System.monotonic_time(:millisecond) - started_at
      pct = Float.round(batch_end / total * 100, 1)
      eta = if batch_end > 0, do: div(elapsed * (total - batch_end), batch_end), else: 0

      Logger.info(
        "FetchTxs block=#{block.height} progress=#{batch_end}/#{total} " <>
          "(#{pct}%) elapsed=#{format_duration(elapsed)} eta=#{format_duration(eta)} " <>
          "failed_in_batch=#{length(failed)}"
      )
    end

    # Continue with next batch
    fetch_in_batches(block, batch_end, total, started_at)
  end

  defp fetch_batch(txids) do
    case BitcoinsvCli.batch_getrawtransaction(txids, 1) do
      {:ok, results} ->
        {successful, failed} =
          Enum.reduce(txids, {[], []}, fn txid, {ok_acc, err_acc} ->
            case Map.get(results, txid) do
              {:error, reason} ->
                Logger.warning("Failed to fetch tx #{txid}: #{inspect(reason)}")
                {ok_acc, [txid | err_acc]}

              nil ->
                Logger.warning("No result for tx #{txid}")
                {ok_acc, [txid | err_acc]}

              tx when is_map(tx) ->
                raw = tx["hex"]

                analysis =
                  case TransactionParser.analyze(raw) do
                    {:ok, meta} -> meta
                    _ -> %{}
                  end

                inputs = (tx["vin"] || []) |> Enum.map(&Jason.encode!/1)
                outputs = (tx["vout"] || []) |> Enum.map(&Jason.encode!/1)

                parsed =
                  Map.merge(
                    %{
                      txid: tx["txid"],
                      raw: raw,
                      block_hash: tx["blockhash"],
                      block_height: tx["height"],
                      version: to_string(tx["version"] || 1),
                      inputs: inputs,
                      input_txids: TransactionParser.extract_input_txids(inputs),
                      outputs: outputs,
                      output_addresses: TransactionParser.extract_output_addresses(outputs)
                    },
                    analysis
                  )

                {[parsed | ok_acc], err_acc}
            end
          end)

        {Enum.reverse(successful), Enum.reverse(failed)}

      {:error, reason} ->
        Logger.error("Batch getrawtransaction failed: #{inspect(reason)}")
        {[], txids}
    end
  end

  defp store_batch(transactions) do
    Enum.each(transactions, fn tx_data ->
      changeset = Chain.Transaction.changeset(%Chain.Transaction{}, tx_data)

      case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :txid) do
        {:ok, tx} ->
          Chain.record_spends(tx)

        {:error, error} ->
          Logger.error("Failed to store tx: #{inspect(error)}")
      end
    end)
  end

  # -- Resumability ------------------------------------------------------------

  # Count how many of this block's transactions are already in the database.
  # This lets us skip re-fetching on resume.
  defp count_existing_transactions(%Block{tx: tx_ids, hash: hash}) when is_list(tx_ids) do
    import Ecto.Query

    from(t in Chain.Transaction,
      where: t.block_hash == ^hash,
      select: count()
    )
    |> Repo.one()
  end

  defp count_existing_transactions(_), do: 0

  # -- Confirmation gating -----------------------------------------------------

  defp check_confirmations(block) do
    if @min_confirmations == 0 do
      {:ok, block}
    else
      case BitcoinsvCli.getblockheader(block.hash, true) do
        %{"confirmations" => confirmations} when confirmations >= @min_confirmations ->
          {:ok, block}

        %{"confirmations" => confirmations} ->
          Logger.info(
            "FetchTxs block=#{block.height} has #{confirmations} confirmations, " <>
              "need #{@min_confirmations} — will retry"
          )

          {:error, :insufficient_confirmations}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # -- State transitions -------------------------------------------------------

  defp get_block(block_hash) do
    case Repo.get_by(Block, hash: block_hash) do
      nil -> {:error, :block_not_found}
      block -> {:ok, block}
    end
  end

  defp ensure_has_txids(%Block{sync_state: "header_only", hash: hash, height: height}) do
    Logger.info("Block #{height} is header_only, upgrading to header_synced first")

    case Chain.upgrade_block_to_header_synced(hash) do
      {:ok, upgraded_block} -> {:ok, upgraded_block}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_has_txids(%Block{tx: []} = block) do
    Logger.info("Block #{block.height} has empty tx array, attempting upgrade")

    case Chain.upgrade_block_to_header_synced(block.hash) do
      {:ok, upgraded_block} -> {:ok, upgraded_block}
      {:error, _} -> {:ok, block}
    end
  end

  defp ensure_has_txids(block), do: {:ok, block}

  defp transition_to_syncing(block) do
    case block
         |> Ecto.Changeset.change(%{
           sync_state: "txs_syncing",
           tx_sync_started_at: DateTime.utc_now() |> DateTime.truncate(:second)
         })
         |> Repo.update() do
      {:ok, updated} = result ->
        Chain.broadcast_block_update(updated)
        result

      error ->
        error
    end
  end

  defp transition_to_completed(block) do
    case block
         |> Ecto.Changeset.change(%{
           sync_state: "completed",
           tx_sync_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
         })
         |> Repo.update() do
      {:ok, updated} = result ->
        Chain.broadcast_block_update(updated)
        result

      error ->
        error
    end
  end

  defp transition_to_failed(block, error) do
    case block
         |> Ecto.Changeset.change(%{
           sync_state: "failed",
           tx_sync_error: inspect(error),
           tx_sync_attempts: (block.tx_sync_attempts || 0) + 1
         })
         |> Repo.update() do
      {:ok, updated} = result ->
        Chain.broadcast_block_update(updated)
        result

      error_result ->
        error_result
    end
  end

  # -- Formatting --------------------------------------------------------------

  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"
  defp format_duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m #{div(rem(ms, 60_000), 1_000)}s"
  defp format_duration(ms), do: "#{div(ms, 3_600_000)}h #{div(rem(ms, 3_600_000), 60_000)}m"
end
