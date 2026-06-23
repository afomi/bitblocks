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

  # Default queue is the backfill lane; the tip flow overrides it to
  # :transactions_tip at enqueue time (see Chain.queue_transaction_fetch/2).
  # Tip and backfill are separate concurrency-1 queues so they never share slots
  # — one tip + one backfill fetch run in parallel, tip is never starved.
  # Uniqueness is keyed on block_hash, so the same block can't be queued twice.
  use Oban.Worker,
    queue: :transactions_backfill,
    max_attempts: 5,
    unique: [period: 300, fields: [:args], keys: [:block_hash]]

  require Logger
  alias Bitblocks.Repo
  alias Bitblocks.Chain
  alias Bitblocks.Chain.Block
  alias Bitblocks.Chain.MerkleVerifier
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
         {:ok, block} <- verify_merkleroot(block),
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

  # Walks the block's txids in batches. Returns :ok only when every transaction
  # is actually stored — otherwise {:error, {:incomplete, stored, total}} so the
  # block transitions to `failed` and Oban retries (the worker is resumable and
  # idempotent, so the retry picks up only the missing txs). Advancing `offset`
  # by the slice length is just iteration bookkeeping; completeness is decided by
  # the authoritative DB row count below, NOT by reaching the end of the list.
  # This is what prevents a block whose tail txs persistently fail from being
  # silently marked `completed` with stored < num_tx.
  defp fetch_in_batches(block, offset, total, started_at) when offset >= total do
    stored = count_existing_transactions(block)

    if stored >= total do
      :ok
    else
      Logger.error(
        "FetchTxs block=#{block.height} incomplete after full pass: " <>
          "stored=#{stored}/#{total} (#{total - stored} tx missing) — will retry"
      )

      _ = started_at
      {:error, {:incomplete, stored, total}}
    end
  end

  defp fetch_in_batches(block, offset, total, started_at) do
    batch_txids = Enum.slice(block.tx, offset, @batch_size)
    batch_end = offset + length(batch_txids)

    # Filter out txids already in the database to avoid re-fetching
    needed_txids = filter_already_fetched(batch_txids)

    # Fetch only what we need from the node
    {successful, failed} =
      if needed_txids == [] do
        {[], []}
      else
        fetch_batch(needed_txids, block)
      end

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

  @doc false
  # True iff `raw` decodes and its computed txid equals `expected`. Total: a
  # non-binary or undecodable body simply fails the check (fail closed). A nil
  # raw means the node returned no body — let it through so the existing
  # changeset/`analyze` path handles it (the txid is already merkleroot-authed).
  # Public for testing.
  def body_matches_txid?(nil, _expected), do: true

  def body_matches_txid?(raw, expected) when is_binary(raw) do
    case Bitblocks.Chain.SafeTx.from_hex(raw) do
      {:ok, tx} -> BSV.Tx.get_txid(tx) == expected
      {:error, _} -> false
    end
  end

  def body_matches_txid?(_raw, _expected), do: false

  defp fetch_batch(txids, block) do
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

                # T4 (tx-body): the txid list is merkleroot-authenticated, but the
                # body arrives separately. Confirm the raw bytes actually hash to
                # the txid we asked for, so the node can't slip a doctored body
                # under a valid txid. Skip closed if we can't recompute (the
                # merkleroot gate is the primary defense).
                if body_matches_txid?(raw, txid) do
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
                        txid: txid,
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

                  {[parsed | ok_acc], err_acc}
                else
                  Logger.error(
                    "FetchTxs block=#{block.height} REJECTED tx #{txid} — body does not hash to txid"
                  )

                  {ok_acc, [txid | err_acc]}
                end
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

  # Filter out txids that already exist in the database.
  # Returns only the txids that still need to be fetched.
  defp filter_already_fetched(txids) when txids == [], do: []

  defp filter_already_fetched(txids) do
    import Ecto.Query

    existing =
      from(t in Chain.Transaction,
        where: t.txid in ^txids,
        select: t.txid
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.reject(txids, &MapSet.member?(existing, &1))
  end

  # Count how many of THIS block's txids are present in the table, by
  # intersecting the block's txid array with stored txids — the same identity
  # `filter_already_fetched/1` uses to decide what to skip, so the "skip if
  # present" and "complete when count matches" halves agree.
  #
  # Deliberately NOT `block_hash == hash`: txid is globally unique, and a tx can
  # legitimately live under another block (reorg, BIP30 duplicate coinbase). A
  # block_hash count could then sit below num_tx forever and wedge the block in
  # `failed`. Counting the intersection reflects true completeness: every txid
  # this block claims is somewhere in our table.
  defp count_existing_transactions(%Block{tx: tx_ids}) when is_list(tx_ids) and tx_ids != [] do
    import Ecto.Query

    from(t in Chain.Transaction,
      where: t.txid in ^tx_ids,
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

  # T4: the txid list arrives from the (untrusted) node separately from the
  # header. The header's merkleroot is trustworthy because the header is
  # PoW-verified (see HeaderVerifier), so rebuilding the root from the txid
  # list and matching it authenticates the ordered set of txids before we
  # spend effort fetching bodies. Fails closed on mismatch.
  #
  # Large blocks don't store the full tx array (a memory optimization — the
  # array is dropped above ~10k txs), so the list is incomplete and the root
  # can't be rebuilt. We skip verification in that case rather than fail, but
  # log it so a skipped check is never mistaken for a passed one.
  defp verify_merkleroot(%Block{merkleroot: root, tx: txids, num_tx: num_tx} = block)
       when is_binary(root) and is_list(txids) do
    cond do
      txids == [] or (is_integer(num_tx) and length(txids) != num_tx) ->
        Logger.info(
          "FetchTxs block=#{block.height} merkleroot check SKIPPED " <>
            "(incomplete txid list: have=#{length(txids)} num_tx=#{inspect(num_tx)})"
        )

        {:ok, block}

      true ->
        case MerkleVerifier.verify(txids, root) do
          :ok ->
            {:ok, block}

          {:error, reason} ->
            Logger.error(
              "FetchTxs block=#{block.height} REJECTED — txid list does not match " <>
                "header merkleroot: #{inspect(reason)}"
            )

            {:error, {:merkleroot_verification_failed, reason}}
        end
    end
  end

  # No merkleroot or no list to check against — nothing to verify, proceed.
  defp verify_merkleroot(block), do: {:ok, block}

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
