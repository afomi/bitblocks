defmodule Bitblocks.Workers.FetchTransactionsWorker do
  @moduledoc """
  The sync loop's block job: fetches one block's transactions, and owns that
  block while it does. `Bitblocks.Sync.dispatch/0` queues one for each of the
  lowest incomplete blocks; see docs/SYNCING.md.

  ## One owner, one process
  Unique on the block hash across queued, scheduled and running states, so
  two processes never work the same block. Within the block the walk is
  sequential: one chunk of `@batch_size` txids at a time, in list order, one
  batched RPC call in flight.

  ## One request per block
  A block up to 32 MB is fetched once as raw bytes (`Chain.RawBlock`: node
  REST, else `getblock(hash, 0)`), its txids derived from the bytes and
  checked against the header's merkleroot. Larger blocks, and blocks the
  node can't serve whole, use the verified txid list (`Chain.TxidSource`)
  and fetch bodies per chunk (`Chain.TxSources`).

  ## Diff-and-fill
  Either way the block is walked in chunks; each chunk is diffed against
  stored transactions and only the gaps are stored. Re-running is idempotent
  (`on_conflict: :nothing` via `Chain.TxIngest`).

  ## Bounded runs
  A run stops after `:tx_fetch_run_ms` (default 30 s, inside Oban's 60 s
  shutdown grace), records the chunk it reached in the job's meta, and
  snoozes. The same job resumes from there, so a 4M-tx block spans many
  short runs and never more than one owner.

  ## Verified completeness
  The txid list is merkleroot-verified and the expected count comes from the
  header's `num_tx`. A block becomes `completed` only after a final count
  shows every txid stored. The broadcast of that change tells
  `Sync.Coordinator` to give the slot to the next block.

  ## Retries replace give-ups
  A failure (node unreachable, rate limit, a tx no source returns, a merkle
  mismatch) marks the block `failed` and snoozes with exponential backoff:
  1, 2, 4 … minutes, capped at an hour. The job never gives up and the block
  keeps its place. `tx_sync_attempts` counts consecutive failures; the
  seventh, more than an hour after the first, sends one stall alert.
  """

  use Oban.Worker,
    queue: :sync_blocks,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:block_hash], states: :incomplete]

  require Logger
  import Ecto.Query

  alias Bitblocks.{Chain, Repo, Sync}
  alias Bitblocks.Chain.{Block, RawBlock, TxIngest, TxidSource, TxSources}
  alias Bitblocks.SyncProgress.Tracker

  # How many transactions to fetch and write per chunk.
  # Bounds memory: 100 raw transactions ≈ 10-50 MB depending on tx size.
  @batch_size Application.compile_env(:bitblocks, :tx_fetch_batch_size, 100)

  @backoff_base_seconds 60
  @backoff_cap_seconds 3_600

  # Failures 1..6 back off 1+2+4+8+16+32 = 63 minutes, so the seventh
  # consecutive failure is the first more than an hour into the stall.
  @stall_alert_failures 7

  @impl Oban.Worker
  # A run of small blocks (Sync.dispatch/1): walked in height order within
  # one bounded run. A completed member is skipped, so a resumed run picks
  # up at the block it reached, from the offset it saved.
  def perform(%Oban.Job{args: %{"run" => [_ | _] = run}} = job) do
    deadline = System.monotonic_time(:millisecond) + (job.meta["run_ms"] || run_ms())
    walk_run(run, job, job.meta["offset"] || 0, deadline)
  end

  def perform(%Oban.Job{args: %{"block_hash" => block_hash}} = job) do
    case Repo.get_by(Block, hash: block_hash) do
      # Deleted by a reorg while queued.
      nil ->
        {:cancel, :block_not_found}

      %Block{sync_state: "completed"} ->
        :ok

      block ->
        run(block, job)
    end
  end

  # The first block a pass works always runs (it bounds itself by the
  # deadline, as a lone block does); the deadline is checked before each
  # block after that, so every pass makes progress.
  defp walk_run(run, job, offset, deadline, worked? \\ false)

  defp walk_run([], _job, _offset, _deadline, _worked?), do: :ok

  defp walk_run([hash | rest], job, offset, deadline, worked?) do
    case Repo.get_by(Block, hash: hash) do
      # Set aside by a reorg while queued: the next dispatch finds what replaced it.
      nil ->
        walk_run(rest, job, 0, deadline, worked?)

      %Block{sync_state: "completed"} ->
        walk_run(rest, job, 0, deadline, worked?)

      block ->
        if worked? and System.monotonic_time(:millisecond) >= deadline do
          save_offset(job, 0)
          {:snooze, 1}
        else
          case run(block, job, offset, deadline) do
            :ok -> walk_run(rest, job, 0, deadline, true)
            other -> other
          end
        end
    end
  end

  defp run(block, job) do
    offset = job.meta["offset"] || 0
    deadline = System.monotonic_time(:millisecond) + (job.meta["run_ms"] || run_ms())
    run(block, job, offset, deadline)
  end

  defp run(block, job, offset, deadline) do
    with {:ok, items, block} <- block_txs(block, job.meta["raw_dir"]),
         {:ok, block} <- mark_syncing(block) do
      case walk(block, items, offset, deadline) do
        :completed ->
          mark_completed(block)
          :ok

        {:paused, next_offset} ->
          save_offset(job, next_offset)
          if (block.tx_sync_attempts || 0) > 0, do: reset_failures(block)
          {:snooze, 1}

        {:error, reason, reached} ->
          save_offset(job, reached)
          fail(block, reason)
      end
    else
      {:error, reason} -> fail(block, reason)
    end
  end

  # The block's transactions in order: `{txid, bytes}` from one raw-block
  # fetch when the block is small enough (Chain.RawBlock), else bare txids
  # from the verified txid list, fetched per chunk (TxidSource + TxSources).
  # A raw block that fails its own checks fails the run; one the node can't
  # serve whole falls back to the per-tx path.
  # An import (Chain.BlockImport) names a directory of exported block files:
  # the block comes from there or not at all, never from the node.
  defp block_txs(block, raw_dir) when is_binary(raw_dir) do
    case RawBlock.fetch(block, dir: raw_dir) do
      {:ok, txs, stats} -> {:ok, txs, record_fetch(block, stats)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp block_txs(block, nil) do
    if RawBlock.eligible?(block) and TxSources.node_has_block?(block) do
      case RawBlock.fetch(block) do
        {:ok, txs, stats} ->
          {:ok, txs, record_fetch(block, stats)}

        {:error, reason}
        when elem(reason, 0) in [:merkleroot_verification_failed, :tx_count_mismatch] ->
          {:error, reason}

        {:error, :block_hash_mismatch} ->
          {:error, :block_hash_mismatch}

        {:error, reason} ->
          Logger.info(
            "FetchTxs block=#{block.height} raw fetch failed (#{inspect(reason)}); per-tx path"
          )

          TxidSource.txids(block)
      end
    else
      TxidSource.txids(block)
    end
  end

  # Bytes and time per raw block, for the node-load numbers on /sync; the
  # size is kept on the row so the size cap can use it next time.
  defp record_fetch(block, stats) do
    Phoenix.PubSub.broadcast(
      Bitblocks.PubSub,
      Tracker.topic(),
      {:sync_fetch, Map.merge(stats, %{height: block.height, at: System.system_time(:second)})}
    )

    if block.size == stats.bytes do
      block
    else
      case change_block(block, %{size: stats.bytes}) do
        {:ok, block} -> block
        _ -> block
      end
    end
  end

  # Walks chunks from `offset` until the list ends or the deadline passes,
  # always doing at least one chunk. Stops at the first chunk that can't be
  # fully stored; the next run starts there.
  defp walk(block, items, offset, deadline) do
    total = length(items)
    tracker = Tracker.new(block, total, min(offset * @batch_size, total))

    items
    |> Enum.drop(offset * @batch_size)
    |> Stream.chunk_every(@batch_size)
    |> Stream.with_index(offset)
    |> Enum.reduce_while({:ok, tracker, offset}, fn {chunk, index}, {:ok, tracker, _} ->
      if index > offset and System.monotonic_time(:millisecond) >= deadline do
        {:halt, {:paused, tracker, index}}
      else
        case store_chunk(chunk, block) do
          :ok -> {:cont, {:ok, Tracker.chunk(tracker, Enum.map(chunk, &txid_of/1)), index + 1}}
          {:error, reason} -> {:halt, {:error, reason, tracker, index}}
        end
      end
    end)
    |> case do
      {:ok, tracker, _} ->
        Tracker.finish(tracker)

        case verify_complete(block, Enum.map(items, &txid_of/1)) do
          :ok -> :completed
          # Something walked as stored has gone: walk the whole list again.
          {:error, reason} -> {:error, reason, 0}
        end

      {:paused, tracker, index} ->
        Tracker.finish(tracker)
        {:paused, index}

      {:error, reason, tracker, index} ->
        Tracker.finish(tracker)
        {:error, reason, index}
    end
  end

  defp run_ms, do: Application.get_env(:bitblocks, :tx_fetch_run_ms, 30_000)

  # The offset survives the snooze: Oban's snooze only adds `snoozed` to meta.
  defp save_offset(%Oban.Job{id: nil}, _offset), do: :ok

  defp save_offset(%Oban.Job{id: id}, offset) do
    Repo.update_all(
      from(j in Oban.Job,
        where: j.id == ^id,
        update: [
          set: [meta: fragment("jsonb_set(?, '{offset}', to_jsonb(?::int))", j.meta, ^offset)]
        ]
      ),
      []
    )
  end

  defp fail(block, reason) do
    failures = (block.tx_sync_attempts || 0) + 1
    backoff = backoff_seconds(failures)

    Logger.error(
      "FetchTxs block=#{block.height} failed (#{failures} in a row), retrying in #{backoff}s: " <>
        inspect(reason)
    )

    mark_failed(block, reason, failures)

    if failures == @stall_alert_failures,
      do: Bitblocks.Notifications.sync_stall_alert(block.height, block.hash, reason)

    {:snooze, backoff}
  end

  @doc "Seconds to wait after the `failures`-th consecutive failure: 1 min doubling, capped at 1 h."
  @spec backoff_seconds(pos_integer()) :: pos_integer()
  def backoff_seconds(failures) when failures > 7, do: @backoff_cap_seconds

  def backoff_seconds(failures),
    do: min(@backoff_base_seconds * Integer.pow(2, failures - 1), @backoff_cap_seconds)

  # -- One chunk ---------------------------------------------------------------

  # Fetches and stores the chunk's missing txs (node first, WhatsOnChain for
  # what it can't serve; see Chain.TxSources). :ok only when every one is
  # stored. A tx stored under an orphaned block's hash is moved to this block
  # by TxIngest.existing_txids/2, since it is skipped as present (#34).
  defp store_chunk(chunk, block) do
    existing = TxIngest.existing_txids(Enum.map(chunk, &txid_of/1), block)

    case Enum.reject(chunk, &MapSet.member?(existing, txid_of(&1))) do
      [] -> :ok
      [{_txid, _bytes} | _] = missing -> store_parsed(missing, block)
      missing -> fetch_batch(missing, block)
    end
  end

  defp txid_of({txid, _bytes}), do: txid
  defp txid_of(txid), do: txid

  # Bodies already in hand from the raw block: no node calls.
  defp store_parsed(txs, block) do
    failed =
      txs
      |> Enum.map(fn {txid, bytes} -> RawBlock.tx_json(txid, bytes) end)
      |> TxIngest.store_chunk(block)
      |> rejected()

    if failed == [], do: :ok, else: {:error, {:unstored_txs, length(failed)}}
  end

  defp fetch_batch(txids, block) do
    results = TxSources.fetch_raw(txids, block)

    {fetched, unfetched} =
      Enum.split_with(txids, fn txid -> is_map(Map.get(results, txid)) end)

    for txid <- unfetched do
      Logger.warning("FetchTxs tx #{txid} not fetched: #{inspect(Map.get(results, txid))}")
    end

    rejected =
      fetched
      |> Enum.map(&Map.fetch!(results, &1))
      |> TxIngest.store_chunk(block)
      |> rejected()

    failed = unfetched ++ rejected

    cond do
      failed == [] -> :ok
      TxSources.any_rate_limited?(Map.take(results, failed)) -> {:error, :rate_limited}
      true -> {:error, {:unfetched_txs, length(failed)}}
    end
  end

  # The txids TxIngest didn't store, each logged.
  defp rejected(results) do
    for {txid, {:error, reason}} <- results do
      Logger.warning("FetchTxs tx #{txid} rejected: #{inspect(reason)}")
      txid
    end
  end

  @doc false
  # Kept as a public delegate — the body-hash check (threat T4) lives in the
  # shared ingest path now. See Chain.TxIngest.
  defdelegate body_matches_txid?(raw, expected), to: TxIngest

  # -- Completeness gate ---------------------------------------------------------

  # Every txid of the verified list must be in the table. Counted by txid, not
  # block_hash: a tx can legitimately live under another block (reorg, BIP30
  # duplicate coinbase), and a block_hash count would wedge such a block.
  # Chunked so the IN list is bounded at any block size.
  defp verify_complete(block, txids) do
    total = length(txids)

    stored =
      txids
      |> Stream.chunk_every(1_000)
      |> Enum.reduce(0, fn chunk, acc ->
        acc + Repo.one(from(t in Chain.Transaction, where: t.txid in ^chunk, select: count()))
      end)

    if stored >= total do
      :ok
    else
      Logger.error("FetchTxs block=#{block.height} incomplete: stored=#{stored}/#{total}")
      {:error, {:incomplete, stored, total}}
    end
  end

  # -- State -------------------------------------------------------------------

  defp mark_syncing(%Block{sync_state: "txs_syncing"} = block), do: {:ok, block}

  defp mark_syncing(block) do
    change_block(block, %{
      sync_state: "txs_syncing",
      tx_sync_started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp mark_completed(block) do
    with {:ok, completed} <-
           change_block(block, %{
             sync_state: "completed",
             tx_sync_completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
             tx_sync_error: nil,
             tx_sync_attempts: 0
           }) do
      Logger.info("FetchTxs block=#{block.height} completed")
      totals(completed)
      notify_projections(completed)
    end
  end

  defp mark_failed(block, reason, failures) do
    change_block(block, %{
      sync_state: "failed",
      tx_sync_error: inspect(reason),
      tx_sync_attempts: failures
    })
  end

  defp reset_failures(block), do: change_block(block, %{tx_sync_attempts: 0, tx_sync_error: nil})

  defp change_block(block, changes) do
    with {:ok, updated} <- block |> Ecto.Changeset.change(changes) |> Repo.update() do
      Chain.broadcast_block_update(updated)
      {:ok, updated}
    end
  end

  # The tx pipeline's :block steps (block totals; docs/TX_PIPELINE.md), after
  # the block is completed, so they never decide whether it completes. The
  # row they wrote is broadcast so open pages show it.
  defp totals(completed) do
    Chain.TxPipeline.run_block(completed)
    Chain.broadcast_block_update(Repo.reload!(completed))
  end

  # Follow (#29 step 4): webhook projections hear about matches in blocks that
  # complete near our tip. History is served by hydrate instead, so filling
  # it in doesn't flood tenants. Never fails the fetch.
  @follow_window 100

  defp notify_projections(block) do
    tip = Sync.tip()
    if tip && block.height > tip - @follow_window, do: Bitblocks.Projections.notify_block(block)
  rescue
    e ->
      Logger.error(
        "FetchTxs block=#{block.height} projection notify failed: #{Exception.message(e)}"
      )
  end
end
