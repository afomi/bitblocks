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

      # Close a recent gap first: only blocks at or above a height
      Bitblocks.Release.start_backfill_transactions(min_height: 957_302)

  Bodies come from the node, then WhatsOnChain for what the node can't serve
  (`Chain.TxSources`). A rate limit from either is a backoff: the block keeps
  its attempts and the worker tries again after `:backfill_rate_limit_seconds`.
  """

  # Runs on the backfill lane (concurrency 1) so it never competes with tip
  # tx fetching. See Chain.queue_transaction_fetch/2.
  #
  # Uniqueness is scoped to ACTIVE states only. Without `states:`, Oban's default
  # window also counts `completed`/`discarded` jobs — so when this worker finishes
  # a block and reschedules itself (schedule_in: 1, inside the 60s window), the
  # just-completed job is seen as a duplicate and the insert is silently dropped.
  # That breaks the self-rescheduling chain after a single block. Restricting to
  # active states keeps the "only one backfill running at a time" guarantee while
  # letting each completed run enqueue the next.
  #
  # `:executing` is left out too: the reschedule is inserted from inside
  # perform/1, while this very job is still executing, so counting executing
  # jobs made every self-reschedule a conflict with itself. The chain then
  # advanced one block per hourly cron instead of one every
  # @reschedule_seconds. At most one job waits; a cron insert while that one
  # waits is the duplicate that gets dropped.
  use Oban.Worker,
    queue: :transactions_backfill,
    max_attempts: 3,
    unique: [
      period: 60,
      fields: [:worker],
      states: [:available, :scheduled, :retryable]
    ]

  require Logger
  import Ecto.Query

  alias Bitblocks.{Repo, Chain}
  alias Bitblocks.Chain.{Block, Transaction, TxIngest, TxidSource, TxSources}
  alias Bitblocks.SyncProgress.Tracker

  @batch_size Application.compile_env(:bitblocks, :tx_fetch_batch_size, 100)

  # A block that has failed this many times stops being re-selected. Without
  # this brake `tx_sync_attempts` was written by mark_failed/2 but never read,
  # so a block that COULDN'T complete (node down, a tx the node won't return)
  # was marked "failed", immediately re-selected as the lowest incomplete
  # block, failed again — a hot loop that hammered `blocks` + `oban_jobs` once
  # per second per instance and never advanced. Exhausted blocks are skipped so
  # the backfill moves on; `Release.retry_failed_blocks/0` clears the counter
  # when the underlying cause (e.g. an unreachable node) is fixed.
  @max_attempts Application.compile_env(:bitblocks, :backfill_max_attempts, 3)

  # Gap between blocks. The old value was 1 second, which — combined with the
  # unbounded retry above — was the main source of DB load. Backfill is
  # throughput work, not latency work: seconds between blocks cost nothing.
  @reschedule_seconds Application.compile_env(:bitblocks, :backfill_reschedule_seconds, 15)

  # A rate limit (PublicNode -32005, WoC 429) says "slow down", not "this block
  # is broken": wait this long and try the same block again, attempts untouched.
  @rate_limit_seconds Application.compile_env(:bitblocks, :backfill_rate_limit_seconds, 60)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    min_height = min_height(args)

    case next_incomplete_block(min_height) do
      nil ->
        # Nothing eligible. Note this is also the resting state when every
        # remaining block has exhausted @max_attempts — the loop STOPS here
        # rather than re-selecting them. It restarts on the hourly cron, or
        # immediately via Release.retry_failed_blocks/0.
        Logger.info("BackfillTxs: no eligible blocks — backfill idle")
        :ok

      block ->
        Logger.info("BackfillTxs: block #{block.height} (#{block.sync_state})")

        case sync_block(block) do
          :ok ->
            Logger.info("BackfillTxs: block #{block.height} done, scheduling next")
            reschedule(args, @reschedule_seconds)
            :ok

          {:error, :rate_limited} ->
            Logger.warning(
              "BackfillTxs: block #{block.height} rate limited; retrying in #{@rate_limit_seconds}s"
            )

            reschedule(args, @rate_limit_seconds)
            :ok

          {:error, reason} ->
            # Do NOT reschedule and do NOT return an error: mark_failed/2 has
            # already bumped tx_sync_attempts, so this block either gets one
            # more try on a later pass or is skipped for good. Returning
            # {:error, _} here would make Oban retry the JOB (max_attempts: 3)
            # on top of our own accounting — two retry mechanisms stacked, the
            # spin loop the fix is removing. The failure is recorded on the
            # block; the hourly cron is what picks the work back up.
            Logger.error("BackfillTxs: block #{block.height} failed: #{inspect(reason)}")
            :ok
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
  #
  # `txs_queued` blocks are eligible too, but only when no live Oban job holds
  # them — a queued block whose FetchTransactionsWorker job was pruned or lost
  # would otherwise be picked up by nothing (recover_stuck_blocks/0 was the only
  # manual escape hatch). A queued block WITH an active job is left alone so the
  # two lanes never double-fetch the same block.
  # `failed` blocks stay eligible (a failure is often transient — a flaky RPC
  # call), but ONLY until they've burned @max_attempts. That bound is what
  # terminates the loop: previously a permanently-unfetchable block was
  # re-selected every single pass forever, so the backfill could never advance
  # past it and never went idle.
  defp min_height(%{"min_height" => h}) when is_integer(h), do: h
  defp min_height(_args), do: 0

  defp next_incomplete_block(min_height) do
    from(b in Block,
      where:
        b.height >= ^min_height and
          coalesce(b.tx_sync_attempts, 0) < @max_attempts and
          (b.sync_state in ["header_only", "header_synced", "txs_syncing", "failed"] or
             (b.sync_state == "txs_queued" and b.hash not in subquery(active_fetch_job_hashes()))),
      order_by: [asc: b.height],
      limit: 1
    )
    |> Repo.one()
  end

  defp active_fetch_job_hashes do
    from(j in Oban.Job,
      where: j.worker == "Bitblocks.Workers.FetchTransactionsWorker",
      where: j.state in ["available", "scheduled", "executing", "retryable"],
      select: fragment("?->>'block_hash'", j.args)
    )
  end

  defp sync_block(block) do
    # TxidSource is the authoritative txid list: the stored array when complete,
    # otherwise re-fetched from the node — always merkleroot-verified, so an
    # empty/truncated stored array (the >10k memory optimization) can no longer
    # zero out the completeness denominator. The list stays in process memory;
    # both lanes are concurrency-1, so at most one transient list per lane.
    with {:ok, txids, block} <- TxidSource.txids(block),
         {:ok, block} <- mark_syncing(block) do
      # Some blocks have millions of txids. Never load the whole missing set or
      # query `txid IN (<millions>)` — process the txid list in fixed-size
      # chunks: for each chunk, ask the DB which of its ≤@batch_size txids are
      # already stored (a bounded IN), fetch only the gaps, store, advance. Each
      # query and each in-memory list is bounded by @batch_size regardless of
      # block size. Idempotent: re-running re-skips what's present.
      with :ok <- fetch_missing_in_batches(block, txids),
           :ok <- verify_complete(block, txids) do
        mark_completed(block)
        :ok
      else
        {:error, :rate_limited} ->
          {:error, :rate_limited}

        {:error, reason} ->
          mark_failed(block, reason)
          {:error, reason}
      end
    else
      # The outer `with` previously had no else clause, so a failure to even
      # establish the txid list (TxidSource can't reach the node — exactly what
      # happens when the BSV node is down) fell straight through WITHOUT
      # touching tx_sync_attempts. The block therefore stayed permanently
      # eligible and was re-selected on every pass: the spin loop. Count these
      # against the block like any other failure so an unreachable node makes
      # the backfill go quiet instead of hammering the DB.
      # A rate limit is the exception: the block is fine, the source is busy.
      {:error, :rate_limited} ->
        {:error, :rate_limited}

      {:error, reason} ->
        mark_failed(block, reason)
        {:error, reason}

      other ->
        mark_failed(block, other)
        {:error, other}
    end
  end

  # Authoritative gate: only complete a block once every one of its txids is
  # actually present. Counts the intersection of the verified txid list with
  # stored txids in bounded chunks (never a millions-wide IN, never materialized),
  # so the check is correct at any block size. If short, the block stays
  # incomplete and is retried — completeness over speed. There is deliberately
  # no fallback clause: a block whose txid list can't be established errors in
  # TxidSource instead of passing an unknown through to "complete".
  defp verify_complete(%Block{} = block, txids) when is_list(txids) do
    total = length(txids)

    stored =
      txids
      |> Stream.chunk_every(@batch_size)
      |> Enum.reduce(0, fn chunk, acc -> acc + MapSet.size(existing_txids(chunk)) end)

    if stored >= total do
      :ok
    else
      Logger.error(
        "BackfillTxs: block #{block.height} incomplete: stored=#{stored}/#{total} " <>
          "(#{total - stored} missing) — will retry"
      )

      {:error, {:incomplete, stored, total}}
    end
  end

  defp fetch_missing_in_batches(%Block{} = block, txids) when is_list(txids) do
    tracker = Tracker.new(block, "transactions_backfill", length(txids))

    txids
    |> Stream.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, tracker}, fn chunk, {:ok, tracker} ->
      existing = TxIngest.existing_txids(chunk, block)
      missing = Enum.reject(chunk, &MapSet.member?(existing, &1))

      result = if missing == [], do: :ok, else: fetch_and_store_batch(missing, block)

      case result do
        # Counts for /syncing: stored and analyzed, reported at most once a second.
        :ok -> {:cont, {:ok, Tracker.chunk(tracker, chunk)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, tracker} ->
        Tracker.finish(tracker)
        :ok

      error ->
        error
    end
  end

  defp fetch_and_store_batch(txids, block) do
    # Node first, WhatsOnChain for what it can't serve (TxSources). A tx
    # neither source returned is NOT stored. Returning :ok here would let the
    # block be marked completed with holes — the silent incompleteness we must
    # avoid. Collect the unfetched txids and fail the batch so the block stays
    # incomplete and the worker retries it. The retry is idempotent: stored txs
    # are re-skipped, only the gaps are re-attempted.
    results = TxSources.fetch_raw(txids, block)

    unfetched =
      Enum.reduce(txids, [], fn txid, acc ->
        case Map.get(results, txid) do
          tx when is_map(tx) ->
            case TxIngest.store(tx, block) do
              :ok ->
                acc

              {:error, reason} ->
                Logger.warning("BackfillTxs: tx #{txid} rejected: #{inspect(reason)}")
                [txid | acc]
            end

          {:error, reason} ->
            Logger.warning("BackfillTxs: tx #{txid} error: #{inspect(reason)}")
            [txid | acc]

          nil ->
            Logger.warning("BackfillTxs: tx #{txid} no result")
            [txid | acc]
        end
      end)

    cond do
      unfetched == [] -> :ok
      TxSources.any_rate_limited?(Map.take(results, unfetched)) -> {:error, :rate_limited}
      true -> {:error, {:unfetched_txs, length(unfetched)}}
    end
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
    |> tap(fn
      {:ok, b} -> Chain.broadcast_block_update(b)
      _ -> :ok
    end)
  end

  defp mark_completed(block) do
    block
    |> Ecto.Changeset.change(%{
      sync_state: "completed",
      tx_sync_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
    |> tap(fn
      {:ok, b} -> Chain.broadcast_block_update(b)
      _ -> :ok
    end)
  end

  defp mark_failed(block, error) do
    block
    |> Ecto.Changeset.change(%{
      sync_state: "failed",
      tx_sync_error: inspect(error),
      tx_sync_attempts: (block.tx_sync_attempts || 0) + 1
    })
    |> Repo.update()
    |> tap(fn
      {:ok, b} -> Chain.broadcast_block_update(b)
      _ -> :ok
    end)
  end

  # Carries args (e.g. min_height) forward so a gap-first run stays on the gap.
  defp reschedule(args, seconds) do
    args
    |> __MODULE__.new(schedule_in: seconds)
    |> Oban.insert()
  end
end
