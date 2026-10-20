defmodule Bitblocks.Workers.FetchTransactionsWorker do
  @moduledoc """
  Oban worker for fetching transaction details for a block.

  Designed for blocks of any size — from 1-tx coinbase blocks to 4GB blocks
  with millions of transactions. Key properties:

  ## Diff-and-fill
  Walks the block's verified txid list (`Chain.TxidSource`) in batches; each
  batch is diffed against stored transactions and only the gaps are fetched.
  Re-running is idempotent — already-stored txs are never re-fetched or
  re-upserted (`on_conflict: :nothing` via `Chain.TxIngest`).

  ## Verified completeness
  The txid list is merkleroot-verified and the expected count comes from the
  header's `num_tx` — never from a possibly-truncated stored array — so a
  block can only transition to `completed` when every one of its transactions
  is actually stored.

  ## Batching
  Fetches in configurable batches (default 100) to bound memory. A 2.8M-tx
  block processes as ~28,000 batches; the txid list itself is held in process
  memory only (both tx lanes are concurrency-1).

  ## Observability
  Logs progress at regular intervals with fetched/total, percentage, elapsed
  and estimated remaining time.

  ## Confirmation gating
  When `min_confirmations` is set (via application config), the worker checks
  that the block has sufficient confirmations before fetching, to avoid wasted
  work on blocks that might be reorganized.
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
  alias Bitblocks.Chain.{Block, TxIngest, TxidSource}

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
         {:ok, txids, block} <- TxidSource.txids(block),
         {:ok, block} <- transition_to_syncing(block) do
      total = length(txids)
      already_fetched = count_existing_transactions(txids)

      Logger.info(
        "FetchTxs block=#{block.height} total=#{total} " <>
          "already_fetched=#{already_fetched} batch_size=#{@batch_size}"
      )

      case fetch_in_batches(block, txids, total, started_at) do
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

  # Walks the verified txid list in batches, diffing each batch against stored
  # transactions and fetching only the gaps. Batch failures don't halt the walk
  # — the pass completes as much as it can and the authoritative row-count gate
  # below decides. Returns :ok only when every transaction is actually stored;
  # otherwise {:error, {:incomplete, stored, total}} so the block transitions to
  # `failed` and Oban retries (idempotent — the retry fetches only what's still
  # missing). This is what prevents a block whose tail txs persistently fail
  # from being silently marked `completed` with stored < num_tx.
  defp fetch_in_batches(block, txids, total, started_at) do
    txids
    |> Stream.chunk_every(@batch_size)
    |> Stream.with_index()
    |> Enum.each(fn {chunk, index} ->
      # Diff: fetch only the txids of this chunk not already in the database.
      needed_txids = filter_already_fetched(chunk)

      failed =
        if needed_txids == [] do
          []
        else
          fetch_batch(needed_txids, block)
        end

      batch_end = min((index + 1) * @batch_size, total)

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
    end)

    verify_complete(block, txids, total)
  end

  defp verify_complete(block, txids, total) do
    stored = count_existing_transactions(txids)

    if stored >= total do
      :ok
    else
      Logger.error(
        "FetchTxs block=#{block.height} incomplete after full pass: " <>
          "stored=#{stored}/#{total} (#{total - stored} tx missing) — will retry"
      )

      {:error, {:incomplete, stored, total}}
    end
  end

  @doc false
  # Kept as a public delegate — the body-hash check (threat T4) lives in the
  # shared ingest path now. See Chain.TxIngest.
  defdelegate body_matches_txid?(raw, expected), to: TxIngest

  # Fetches and stores one batch, returning the txids that failed (fetch error,
  # missing result, body-hash rejection, or insert failure).
  defp fetch_batch(txids, block) do
    case rpc().batch_getrawtransaction(txids, 1) do
      {:ok, results} ->
        Enum.reduce(txids, [], fn txid, failed ->
          case Map.get(results, txid) do
            tx when is_map(tx) ->
              case TxIngest.store(tx, block) do
                :ok ->
                  failed

                {:error, reason} ->
                  Logger.warning("FetchTxs tx #{txid} rejected: #{inspect(reason)}")
                  [txid | failed]
              end

            {:error, reason} ->
              Logger.warning("Failed to fetch tx #{txid}: #{inspect(reason)}")
              [txid | failed]

            nil ->
              Logger.warning("No result for tx #{txid}")
              [txid | failed]
          end
        end)

      {:error, reason} ->
        Logger.error("Batch getrawtransaction failed: #{inspect(reason)}")
        txids
    end
  end

  # -- Diff against stored transactions -----------------------------------------

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
  # intersecting the txid list with stored txids — the same identity
  # `filter_already_fetched/1` uses to decide what to skip, so the "skip if
  # present" and "complete when count matches" halves agree. Chunked so the IN
  # list is bounded regardless of block size (the list can be millions now that
  # TxidSource re-fetches truncated arrays).
  #
  # Deliberately NOT `block_hash == hash`: txid is globally unique, and a tx can
  # legitimately live under another block (reorg, BIP30 duplicate coinbase). A
  # block_hash count could then sit below num_tx forever and wedge the block in
  # `failed`. Counting the intersection reflects true completeness: every txid
  # this block claims is somewhere in our table.
  defp count_existing_transactions(txids) when is_list(txids) and txids != [] do
    import Ecto.Query

    txids
    |> Stream.chunk_every(@batch_size)
    |> Enum.reduce(0, fn chunk, acc ->
      acc +
        Repo.one(
          from(t in Chain.Transaction,
            where: t.txid in ^chunk,
            select: count()
          )
        )
    end)
  end

  defp count_existing_transactions(_), do: 0

  # -- Confirmation gating -----------------------------------------------------

  defp check_confirmations(block) do
    if @min_confirmations == 0 do
      {:ok, block}
    else
      case rpc().getblockheader(block.hash, true) do
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

  # Swappable RPC client — tests point this at BitcoinsvCliMock (config/test.exs).
  defp rpc, do: Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)

  # -- Formatting --------------------------------------------------------------

  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"

  defp format_duration(ms) when ms < 3_600_000,
    do: "#{div(ms, 60_000)}m #{div(rem(ms, 60_000), 1_000)}s"

  defp format_duration(ms), do: "#{div(ms, 3_600_000)}h #{div(rem(ms, 3_600_000), 60_000)}m"
end
