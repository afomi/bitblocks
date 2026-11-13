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
  checked against the header's merkleroot. Larger blocks, including one REST
  reports over the cap, are read as a stream from REST (`Chain.BlockStream`,
  #66) and stored chunk by chunk as their txs arrive; see "A block over the
  raw cap, streamed" below. Blocks the node can't serve whole or stream (no
  REST, pruned) use the verified txid list (`Chain.TxidSource`) and fetch
  bodies per chunk (`Chain.TxSources`).

  ## The block in the tx store
  Once a raw-path block is completed, its exact bytes are written to the tx
  store as one object, verified, and its txs located in it
  (`Bitblocks.TxStore.BlockObject`; docs/TX_STORAGE.md). That write never
  decides or delays completion: a failure is logged and left for
  `Release.store_block_objects/3`.

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
  alias Bitblocks.Chain.{Block, BlockStream, RawBlock, TxIngest, TxidSource, TxSources}
  alias Bitblocks.SyncProgress.Tracker
  alias Bitblocks.TxStore.BlockObject

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
    case block_txs(block, job) do
      {:stream, block} ->
        with {:ok, block} <- mark_syncing(block) do
          case stream(block, job, deadline) do
            {:fallback, reason} ->
              Logger.info(
                "FetchTxs block=#{block.height} stream unavailable (#{inspect(reason)}); per-tx path"
              )

              walk_items(block, per_tx(block), job, offset, deadline)

            result ->
              result
          end
        else
          {:error, reason} -> fail(block, reason)
        end

      fetched ->
        walk_items(block, fetched, job, offset, deadline)
    end
  end

  defp walk_items(block, fetched, job, offset, deadline) do
    with {:ok, items, block, raw} <- fetched,
         {:ok, block} <- mark_syncing(block) do
      case walk(block, items, offset, deadline, locations(raw, items)) do
        :completed ->
          mark_completed(block)
          store_block_object(block, raw, items)
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
  # The fourth element is the raw block's bytes (for its object in the tx
  # store), or nil on the per-tx path.
  # `{:stream, block}`: the block is over the raw cap, or turned out to be,
  # and is read as a stream (Chain.BlockStream; see stream/3).
  defp block_txs(block, %Oban.Job{meta: %{"raw_dir" => raw_dir}}) when is_binary(raw_dir) do
    case RawBlock.fetch(block, dir: raw_dir) do
      {:ok, txs, stats} -> {:ok, txs, record_fetch(block, stats), stats.raw}
      {:error, reason} -> {:error, reason}
    end
  end

  defp block_txs(block, job) do
    cond do
      # An earlier run of this job streamed it: it is too large to fetch whole.
      stream_progress(job, block) != nil and streamable?() ->
        {:stream, block}

      RawBlock.eligible?(block) and TxSources.node_has_block?(block) ->
        raw_or_fallback(block)

      streamable?() and TxSources.node_has_block?(block) ->
        {:stream, block}

      true ->
        per_tx(block)
    end
  end

  defp raw_or_fallback(block) do
    case RawBlock.fetch(block) do
      {:ok, txs, stats} ->
        {:ok, txs, record_fetch(block, stats), stats.raw}

      # REST answered that the block is over the cap (its size unknown until now).
      {:error, :block_too_large} ->
        if streamable?(), do: {:stream, block}, else: per_tx(block)

      {:error, reason}
      when elem(reason, 0) in [:merkleroot_verification_failed, :tx_count_mismatch] ->
        {:error, reason}

      {:error, :block_hash_mismatch} ->
        {:error, :block_hash_mismatch}

      {:error, reason} ->
        Logger.info(
          "FetchTxs block=#{block.height} raw fetch failed (#{inspect(reason)}); per-tx path"
        )

        per_tx(block)
    end
  end

  # Streaming needs the node's REST interface: not with raw blocks off or
  # RPC-only, and `config :bitblocks, :sync_block_stream, false` turns it off
  # (blocks over the cap then take the per-tx path, as before #66).
  defp streamable? do
    Application.get_env(:bitblocks, :sync_block_stream, true) and
      Application.get_env(:bitblocks, :raw_block_source, :auto) in [:auto, :rest]
  end

  # txid => {offset, length} in the raw block, stored with each row so the
  # block object needs no second write per tx (BlockObject.store/3).
  defp locations(nil, _items), do: %{}

  defp locations(raw, items) do
    case RawBlock.locate(raw, items) do
      {:ok, located} ->
        Map.new(located, fn {txid, offset, length} -> {txid, {offset, length}} end)

      {:error, _} ->
        %{}
    end
  end

  defp per_tx(block) do
    with {:ok, txids, block} <- TxidSource.txids(block), do: {:ok, txids, block, nil}
  end

  # Bytes and time per raw block, for the node-load numbers on /syncing; the
  # size is kept on the row so the size cap can use it next time.
  defp record_fetch(block, stats) do
    Phoenix.PubSub.broadcast(
      Bitblocks.PubSub,
      Tracker.topic(),
      {:sync_fetch,
       stats
       |> Map.delete(:raw)
       |> Map.merge(%{height: block.height, at: System.system_time(:second)})}
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
  defp walk(block, items, offset, deadline, locations) do
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
        case store_chunk(chunk, block, locations) do
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

  # -- A block over the raw cap, streamed (#66) ---------------------------------
  #
  # Chain.BlockStream reads the block from the node's REST interface tx by
  # tx in bounded memory; the txs go through store_chunk/3 (diff, then the
  # tx pipeline via TxIngest) in chunks as they arrive.
  #
  # Resuming: a stream can't start mid-block, so every run reads the block
  # from its first byte. The job's meta keeps `stream: %{hash, offset}`, the
  # number of txs earlier runs stored. Txs before the offset are checked in
  # chunks of @verify_batch (one existing_txids query each, which also
  # refills any that went missing) instead of chunks of @batch_size; from the
  # offset on they are stored. A run stops after its first stored chunk past
  # the deadline, saves the offset and snoozes.
  #
  # Completion: only a run that reads the block to its end gets
  # `{:ok, ...}` from BlockStream, meaning the header hashed to the block's
  # hash, the tx count matched and the txids of the whole block, every one
  # derived from its bytes, rebuilt the header's merkleroot. That same run
  # has seen every tx confirmed stored, chunk by chunk, so it marks the block
  # completed. A halted, failed or mismatched run never does.
  #
  # Rows stored by a run are written before the merkleroot is known. The
  # header has been checked by then, and each row's txid is its own bytes'
  # hash; a block whose root then fails is marked failed, and no run
  # completes it.

  @verify_batch 1_000
  # A chunk is stored at this many bytes, whatever its count, so a chunk of
  # big txs stays bounded in memory.
  @stream_chunk_bytes 8 * 1024 * 1024

  defp stream(block, job, deadline) do
    offset = stream_progress(job, block) || 0
    # How far txs are known stored, kept outside the stream's accumulator so
    # a read that fails mid-block still saves what it stored.
    reached = :counters.new(1, [])
    :counters.put(reached, 1, offset)
    total = block.num_tx || 0

    acc = %{
      block: block,
      offset: offset,
      deadline: deadline,
      reached: reached,
      index: 0,
      buf: [],
      buf_start: 0,
      buf_n: 0,
      buf_bytes: 0,
      tracker: Tracker.new(block, total, min(offset, total)),
      status: :ok
    }

    case BlockStream.each_tx(block, acc, &stream_tx/2) do
      {:ok, acc, stats} ->
        block = record_stream(block, stats)

        case flush(acc) do
          {:ok, acc} ->
            Tracker.finish(acc.tracker)

            Logger.info(
              "FetchTxs block=#{block.height} streamed #{stats.bytes} bytes, " <>
                "#{stats.txs} txs, merkleroot verified"
            )

            mark_completed(block)
            :ok

          {:error, reason, acc} ->
            Tracker.finish(acc.tracker)
            save_stream_progress(job, block, :counters.get(reached, 1))
            fail(block, reason)
        end

      {:halted, %{status: {:paused, at}} = acc, _stats} ->
        Tracker.finish(acc.tracker)
        save_stream_progress(job, block, at)
        if (block.tx_sync_attempts || 0) > 0, do: reset_failures(block)
        {:snooze, 1}

      {:halted, %{status: {:error, reason}} = acc, _stats} ->
        Tracker.finish(acc.tracker)
        save_stream_progress(job, block, :counters.get(reached, 1))
        fail(block, reason)

      {:error, reason} ->
        if stream_unavailable?(reason) do
          {:fallback, reason}
        else
          save_stream_progress(job, block, :counters.get(reached, 1))
          fail(block, reason)
        end
    end
  end

  defp stream_tx({txid, bytes}, acc) do
    acc = %{
      acc
      | buf: [{txid, :binary.copy(bytes)} | acc.buf],
        buf_n: acc.buf_n + 1,
        buf_bytes: acc.buf_bytes + byte_size(bytes),
        index: acc.index + 1
    }

    if flush?(acc), do: flush_and_go_on(acc), else: acc
  end

  # A chunk ends at its count, at its bytes, or where the stored region ends.
  defp flush?(acc) do
    limit = if verifying?(acc), do: @verify_batch, else: @batch_size
    acc.buf_n >= limit or acc.buf_bytes >= @stream_chunk_bytes or acc.index == acc.offset
  end

  defp verifying?(acc), do: acc.buf_start < acc.offset

  defp flush_and_go_on(acc) do
    stored? = not verifying?(acc)

    case flush(acc) do
      {:ok, acc} ->
        if stored? and System.monotonic_time(:millisecond) >= acc.deadline,
          do: {:halt, %{acc | status: {:paused, acc.index}}},
          else: acc

      {:error, reason, acc} ->
        {:halt, %{acc | status: {:error, reason}}}
    end
  end

  defp flush(%{buf: []} = acc), do: {:ok, acc}

  defp flush(acc) do
    chunk = Enum.reverse(acc.buf)

    case store_chunk(chunk, acc.block, %{}) do
      :ok ->
        tracker =
          if verifying?(acc),
            do: acc.tracker,
            else: Tracker.chunk(acc.tracker, Enum.map(chunk, &txid_of/1))

        if acc.index > :counters.get(acc.reached, 1), do: :counters.put(acc.reached, 1, acc.index)

        {:ok, %{acc | buf: [], buf_n: 0, buf_bytes: 0, buf_start: acc.index, tracker: tracker}}

      {:error, reason} ->
        {:error, reason, acc}
    end
  end

  # The checks BlockStream makes, and a read cut off partway: the block
  # fails and is tried again, never handed to another path. Anything that
  # fails before a byte arrives (no REST, a 404, no connection) means the
  # node won't stream it, and the per-tx path takes it.
  defp stream_unavailable?({{:connection_error, _}, opts}) when is_list(opts),
    do: Keyword.get(opts, :after_bytes) == 0

  defp stream_unavailable?(:block_hash_mismatch), do: false
  defp stream_unavailable?(:trailing_bytes), do: false
  defp stream_unavailable?({:tx_count_mismatch, _, _}), do: false
  defp stream_unavailable?({:tx_too_large, _, _}), do: false
  defp stream_unavailable?({:block_too_large, _}), do: false
  defp stream_unavailable?({:merkleroot_verification_failed, _}), do: false
  defp stream_unavailable?({:truncated, _}), do: false
  defp stream_unavailable?(_reason), do: true

  # Bytes and time for /syncing, the size on the row so the next job goes
  # straight to the stream, and the tx count when the header didn't give one.
  defp record_stream(block, stats) do
    block = record_fetch(block, Map.put(stats, :source, :rest_stream))

    if block.num_tx in [nil, 0] and stats.txs > 0 do
      case change_block(block, %{num_tx: stats.txs}) do
        {:ok, block} -> block
        _ -> block
      end
    else
      block
    end
  end

  defp stream_progress(
         %Oban.Job{meta: %{"stream" => %{"hash" => hash, "offset" => offset}}},
         %Block{
           hash: hash
         }
       )
       when is_integer(offset),
       do: offset

  defp stream_progress(_job, _block), do: nil

  defp save_stream_progress(%Oban.Job{id: nil}, _block, _offset), do: :ok

  defp save_stream_progress(%Oban.Job{id: id}, block, offset) do
    progress = %{"hash" => block.hash, "offset" => offset}

    Repo.update_all(
      from(j in Oban.Job,
        where: j.id == ^id,
        update: [
          set: [meta: fragment("jsonb_set(?, '{stream}', ?)", j.meta, type(^progress, :map))]
        ]
      ),
      []
    )
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
  defp store_chunk(chunk, block, locations) do
    existing = TxIngest.existing_txids(Enum.map(chunk, &txid_of/1), block)

    case Enum.reject(chunk, &MapSet.member?(existing, txid_of(&1))) do
      [] -> :ok
      [{_txid, _bytes} | _] = missing -> store_parsed(missing, block, locations)
      missing -> fetch_batch(missing, block)
    end
  end

  defp txid_of({txid, _bytes}), do: txid
  defp txid_of(txid), do: txid

  # Bodies already in hand from the raw block: no node calls.
  defp store_parsed(txs, block, locations) do
    failed =
      txs
      |> Enum.map(fn {txid, bytes} ->
        txid |> RawBlock.tx_json(bytes) |> located(Map.get(locations, txid))
      end)
      |> TxIngest.store_chunk(block)
      |> rejected()

    if failed == [], do: :ok, else: {:error, {:unstored_txs, length(failed)}}
  end

  defp located(tx_json, nil), do: tx_json

  defp located(tx_json, {offset, length}),
    do: Map.merge(tx_json, %{"raw_offset" => offset, "raw_length" => length})

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
      Chain.TxPipeline.CatchUp.enqueue(completed)
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

  # The block's exact bytes as one object in the tx store, with each tx's
  # offset (docs/TX_STORAGE.md, step 1). After completion and outside it: a
  # failed or unverified write is logged by BlockObject.store/3, leaves
  # raw_object_stored_at nil for Release.store_block_objects/3 to find, and
  # never fails or slows the block's sync state. nil raw (the per-tx path,
  # blocks over 32 MB) writes nothing; reconcile counts those as missing.
  defp store_block_object(_block, nil, _txs), do: :ok

  defp store_block_object(block, raw, txs) do
    if BlockObject.enabled?(), do: BlockObject.store(block, raw, txs)
    :ok
  rescue
    e ->
      Logger.error("FetchTxs block=#{block.height} block object failed: #{Exception.message(e)}")
      :ok
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
