defmodule Bitblocks.Release do
  @moduledoc """
  Used for executing DB release tasks and blockchain sync operations
  when run in production without Mix installed.

  These functions are designed to be called via `rpc` which runs them
  in the context of the already-running application, ensuring all
  dependencies (like Hackney) are properly initialized.
  """
  require Logger

  @app :bitblocks

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          fn _ ->
            file = Path.join(:code.priv_dir(@app), "repo/seeds.exs")

            if File.exists?(file) do
              IO.puts("==> Running seeds: #{file}")
              Code.eval_file(file)
            else
              IO.puts("==> No seeds file found (#{file})")
            end
          end,
          migrator_opts()
        )
    end
  end

  defp migrator_opts do
    [
      timeout: :infinity,
      pool_size: 2,
      queue_target: 60_000,
      queue_interval: 5_000,
      log: :info,
      connect_timeout: 60_000,
      ownership_timeout: 300_000
    ]
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end

  # ---------------------------------------------------------------------------
  # Two-Job Sync Model
  # ---------------------------------------------------------------------------

  @doc """
  Sync block headers (and queue tx downloads) for a height range.

  Fills gaps automatically — safe to re-run.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.sync_headers(0, 100_000)'
  """
  def sync_headers(from, to)
      when is_integer(from) and is_integer(to) and from >= 0 and to >= from do
    case %{"mode" => "range", "from" => from, "to" => to}
         |> Bitblocks.Workers.SyncHeadersWorker.new()
         |> Oban.insert() do
      {:ok, job} ->
        IO.puts("Header sync queued (Oban ##{job.id}): #{from}..#{to}")
        {:ok, job}

      {:error, reason} ->
        IO.puts("Failed to queue: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Start continuous tip sync.

  Watches for new blocks every 30 seconds.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.start_tip_sync()'
  """
  def start_tip_sync do
    case %{"mode" => "tip"}
         |> Bitblocks.Workers.SyncHeadersWorker.new()
         |> Oban.insert() do
      {:ok, job} ->
        IO.puts("Tip sync started (Oban ##{job.id})")
        {:ok, job}

      {:error, reason} ->
        IO.puts("Tip sync already running or failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stop continuous tip sync.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.stop_tip_sync()'
  """
  def stop_tip_sync do
    import Ecto.Query

    {cancelled, _} =
      from(j in Oban.Job,
        where: j.worker == "Bitblocks.Workers.SyncHeadersWorker",
        where: j.state in ["available", "scheduled"],
        where: fragment("args->>'mode' = 'tip'")
      )
      |> Bitblocks.Repo.update_all(set: [state: "cancelled", cancelled_at: DateTime.utc_now()])

    IO.puts("Cancelled #{cancelled} tip sync job(s)")
    {:ok, cancelled}
  end

  # ---------------------------------------------------------------------------
  # Legacy Sync Functions (deprecated — use sync_headers/2 instead)
  # ---------------------------------------------------------------------------

  @doc """
  Syncs a range of blocks from the Bitcoin node.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.sync_blocks(100001, 200000)'
  """
  def sync_blocks(start_height, end_height)
      when is_integer(start_height) and is_integer(end_height) do
    Logger.info("Starting block sync: #{start_height}..#{end_height}")

    try do
      Bitblocks.Sync.get_blocks(start_height..end_height)
      Logger.info("Completed block sync: #{start_height}..#{end_height}")
      :ok
    rescue
      error ->
        Logger.error("Error syncing blocks: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Syncs transaction data for a specific block.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.sync_block_transactions(100001)'
  """
  def sync_block_transactions(block_height) when is_integer(block_height) do
    Logger.info("Starting transaction sync for block: #{block_height}")

    try do
      Bitblocks.Sync.get(block_height)
      Logger.info("Completed transaction sync for block: #{block_height}")
      :ok
    rescue
      error ->
        Logger.error("Error syncing transactions for block #{block_height}: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Gets the current blockchain info from the Bitcoin node.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.blockchain_info()'
  """
  def blockchain_info do
    try do
      info = BitcoinsvCli.getblockchaininfo()
      Logger.info("Blockchain info retrieved successfully")
      IO.inspect(info, label: "Blockchain Info")
      info
    rescue
      error ->
        Logger.error("Error getting blockchain info: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Start parallel pipeline sync (faster than sync_blocks).

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.pipeline_sync(250000, 260000)'
  """
  def pipeline_sync(start_height, end_height)
      when is_integer(start_height) and is_integer(end_height) do
    Logger.info("Starting parallel pipeline sync: #{start_height}..#{end_height}")

    case Bitblocks.Sync.Pipeline.start_sync(start_height, end_height) do
      :ok ->
        Logger.info("Pipeline started successfully")
        :ok

      {:error, reason} ->
        Logger.error("Failed to start pipeline: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get the current status of the sync pipeline.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.pipeline_status()'
  """
  def pipeline_status do
    status = Bitblocks.Sync.Pipeline.status()

    IO.puts("\n=== Pipeline Status ===")
    IO.puts("Status: #{status.status}")
    IO.puts("Range: #{status.start_height || "N/A"} to #{status.end_height || "N/A"}")
    IO.puts("Blocks processed: #{status.blocks_processed || 0}")
    IO.puts("Current height: #{status.current_height || "N/A"}")
    IO.puts("Progress: #{status.progress_percent || 0}%")
    IO.puts("Errors: #{status.errors_count || 0}")
    IO.puts("=====================\n")

    status
  end

  @doc """
  Stop the sync pipeline.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.pipeline_stop()'
  """
  def pipeline_stop do
    Logger.info("Stopping pipeline...")

    Bitblocks.Sync.Pipeline.stop_sync()
    Logger.info("Pipeline stop requested")
    :ok
  end

  @doc """
  Gets database statistics.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.db_stats()'
  """
  def db_stats do
    alias Bitblocks.{Repo, Chain}

    stats = %{
      total_blocks: Repo.aggregate(Chain.Block, :count, :id),
      total_transactions: Repo.aggregate(Chain.Transaction, :count, :id),
      latest_block:
        case Chain.get_latest_block() do
          nil -> nil
          block -> %{height: block.height, hash: block.hash}
        end,
      db_size: get_db_size()
    }

    IO.inspect(stats, label: "Database Stats")
    stats
  end

  @doc """
  Reports transaction sync progress as a breakdown of blocks by sync_state.

  Use this to monitor how many blocks still need transaction data fetched,
  and how many are fully synced.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.tx_sync_status()'
  """
  def tx_sync_status do
    alias Bitblocks.{Repo, Chain.Block}
    import Ecto.Query

    counts =
      from(b in Block, group_by: b.sync_state, select: {b.sync_state, count()})
      |> Repo.all()
      |> Map.new()

    total = Enum.reduce(counts, 0, fn {_, n}, acc -> acc + n end)

    completed = Map.get(counts, "completed", 0)
    incomplete = total - completed

    IO.puts("\n=== TX Sync Status ===")

    counts
    |> Enum.sort_by(fn {state, _} -> state end)
    |> Enum.each(fn {state, count} ->
      pct = if total > 0, do: Float.round(count / total * 100, 1), else: 0.0
      IO.puts("  #{String.pad_trailing(state, 16)} #{count} (#{pct}%)")
    end)

    IO.puts("  #{String.pad_trailing("TOTAL", 16)} #{total}")
    IO.puts("  #{String.pad_trailing("incomplete", 16)} #{incomplete}")
    IO.puts("======================\n")

    %{counts: counts, total: total, completed: completed, incomplete: incomplete}
  end

  @doc """
  One-line sync status: blocks synced, gaps, tx progress.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.status()'
  """
  def status do
    alias Bitblocks.{Repo, Chain, Chain.Block}
    import Ecto.Query

    total_blocks = Repo.aggregate(Block, :count, :id)
    total_txs = Repo.aggregate(Chain.Transaction, :count, :id)
    latest = Chain.get_latest_block()
    tip = if latest, do: latest.height, else: 0

    completed =
      from(b in Block, where: b.sync_state == "completed", select: count())
      |> Repo.one()

    gaps = Chain.missing_block_ranges(0, tip)
    missing_blocks = Enum.reduce(gaps, 0, fn {s, e}, acc -> acc + (e - s + 1) end)

    # Find the lowest incomplete block (the "ratchet position")
    lowest_incomplete =
      from(b in Block,
        where: b.sync_state != "completed",
        order_by: [asc: b.height],
        limit: 1,
        select: b.height
      )
      |> Repo.one()

    IO.puts("\n=== Bitblocks Status ===")
    IO.puts("  Chain tip:          #{tip}")
    IO.puts("  Blocks in DB:       #{total_blocks}")
    IO.puts("  Missing blocks:     #{missing_blocks} (#{length(gaps)} gaps)")
    IO.puts("  Blocks completed:   #{completed}/#{total_blocks} (txs fully synced)")
    IO.puts("  Blocks remaining:   #{total_blocks - completed}")
    IO.puts("  Lowest incomplete:  #{lowest_incomplete || "none — all done!"}")
    IO.puts("  Transactions in DB: #{total_txs}")
    IO.puts("========================\n")

    %{
      tip: tip,
      blocks: total_blocks,
      missing_blocks: missing_blocks,
      gaps: length(gaps),
      completed: completed,
      remaining: total_blocks - completed,
      lowest_incomplete: lowest_incomplete,
      transactions: total_txs
    }
  end

  @doc """
  Backfill script analysis for transactions missing it or analyzed by an older version.

  Processes in batches of `batch_size` (default 500), updating output_types,
  protocols, coinbase, and script_analysis_version directly in the DB.
  Idempotent — safe to re-run. Skips transactions without raw hex.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.analyze_transactions()'
      bin/bitblocks rpc 'Bitblocks.Release.analyze_transactions(batch_size: 1000)'
  """
  def analyze_transactions(opts \\ []) do
    alias Bitblocks.{Repo, Chain.Transaction, TransactionParser}
    import Ecto.Query

    batch_size = Keyword.get(opts, :batch_size, 500)
    current_version = TransactionParser.script_analysis_version()

    total_needing_analysis =
      from(t in Transaction,
        where: not is_nil(t.raw),
        where: is_nil(t.script_analysis_version) or t.script_analysis_version < ^current_version,
        select: count()
      )
      |> Repo.one()

    Logger.info("analyze_transactions: #{total_needing_analysis} transactions to analyze (version #{current_version})")

    if total_needing_analysis == 0 do
      Logger.info("analyze_transactions: nothing to do")
      :ok
    else
      do_analyze_batch(0, total_needing_analysis, batch_size, current_version)
    end
  end

  defp do_analyze_batch(processed, total, batch_size, current_version) do
    alias Bitblocks.{Repo, Chain.Transaction, TransactionParser}
    import Ecto.Query

    txs =
      from(t in Transaction,
        where: not is_nil(t.raw),
        where: is_nil(t.script_analysis_version) or t.script_analysis_version < ^current_version,
        order_by: [asc: t.id],
        limit: ^batch_size,
        select: [:id, :raw]
      )
      |> Repo.all()

    if txs == [] do
      Logger.info("analyze_transactions: complete (#{processed}/#{total})")
      :ok
    else
      Enum.each(txs, fn tx ->
        case TransactionParser.analyze(tx.raw) do
          {:ok, meta} ->
            from(t in Transaction, where: t.id == ^tx.id)
            |> Repo.update_all(set: [
              output_types: meta.output_types,
              protocols: meta.protocols,
              coinbase: meta.coinbase,
              script_analysis_version: meta.script_analysis_version
            ])

          {:error, reason} ->
            Logger.warning("analyze_transactions: failed for tx #{tx.id}: #{inspect(reason)}")
        end
      end)

      new_processed = processed + length(txs)
      Logger.info("analyze_transactions: #{new_processed}/#{total}")
      do_analyze_batch(new_processed, total, batch_size, current_version)
    end
  end

  @doc """
  Check referential integrity between Postgres and S3 CDN.

  ## Usage

      bin/bitblocks eval 'Bitblocks.Release.cdn_check()'
  """
  def cdn_check do
    case Bitblocks.TxCdn.integrity_check() do
      {:ok, result} ->
        IO.inspect(result, label: "CDN Integrity")

        if result.match do
          IO.puts("✓ DB and S3 counts match (#{result.db})")
        else
          IO.puts("✗ Mismatch: DB=#{result.db} S3=#{result.s3} diff=#{result.diff}")
        end

        result

      {:error, :not_configured} ->
        IO.puts("CDN not configured (AWS_S3_BUCKET_TXS not set)")
        {:error, :not_configured}

      {:error, reason} ->
        IO.puts("CDN check failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Backfill missing blocks and transactions from height 0 to the chain tip (or a bounded range).

  Works in two passes:
  1. Syncs any missing block headers (fills gaps)
  2. Queues transaction fetches for blocks that don't have them yet

  Processes in chunks to avoid overwhelming the node or Oban queue.
  Idempotent — safe to run repeatedly. Progress is visible via tx_sync_status().

  ## Options
    - from: start height (default 0)
    - to: end height (default: chain tip)
    - chunk_size: blocks per batch for header sync (default 1000)
    - tx_batch: how many tx fetch jobs to enqueue at once (default 100)
    - skip_blocks: skip block header sync, only backfill transactions
    - skip_txs: skip transaction backfill, only fill block gaps

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.backfill()'
      bin/bitblocks rpc 'Bitblocks.Release.backfill(to: 599999, skip_blocks: true)'
      bin/bitblocks rpc 'Bitblocks.Release.backfill(chunk_size: 500, tx_batch: 50)'
  """
  def backfill(opts \\ []) do
    # If only backfilling txs, prefer the background worker
    if Keyword.get(opts, :skip_blocks, false) do
      IO.puts("Hint: use backfill_txs() instead — it runs in the background and survives restarts.")
    end
    alias Bitblocks.Chain

    from = Keyword.get(opts, :from, 0)
    chunk_size = Keyword.get(opts, :chunk_size, 1000)
    tx_batch = Keyword.get(opts, :tx_batch, 100)
    skip_blocks = Keyword.get(opts, :skip_blocks, false)
    skip_txs = Keyword.get(opts, :skip_txs, false)

    latest = Chain.get_latest_block()
    chain_tip = if latest, do: latest.height, else: 0
    to = Keyword.get(opts, :to, chain_tip)

    Logger.info("Backfill: #{from}..#{to} (chain tip: #{chain_tip})")

    # Pass 1: fill missing block headers
    unless skip_blocks do
      backfill_blocks(from, to, chunk_size)
    end

    # Pass 2: queue transaction fetches for blocks missing txs
    unless skip_txs do
      backfill_transactions(from, to, tx_batch)
    end

    Logger.info("Backfill: complete")
    :ok
  end

  @doc """
  Start a background transaction backfill job.

  Runs as an Oban job — fire and forget. Survives restarts.
  Processes blocks in batches, re-enqueuing itself for each batch.
  Progress is ratcheted: completed blocks are never revisited.

  ## Options
    - batch_size: blocks per batch (default 100)

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.backfill_txs()'
      bin/bitblocks rpc 'Bitblocks.Release.backfill_txs(batch_size: 50)'

  ## Monitoring

      bin/bitblocks rpc 'Bitblocks.Release.status()'
  """
  def backfill_txs(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 100)

    case %{"batch_size" => batch_size}
         |> Bitblocks.Workers.BackfillTransactionsWorker.new()
         |> Oban.insert() do
      {:ok, job} ->
        IO.puts("Backfill job queued (Oban job ##{job.id})")
        IO.puts("Monitor with: Bitblocks.Release.status()")
        :ok

      {:error, reason} ->
        IO.puts("Failed to queue: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Reports gaps in the block chain — missing height ranges.

  ## Usage

      Bitblocks.Release.gaps()
  """
  def gaps do
    alias Bitblocks.Chain

    latest = Chain.get_latest_block()
    tip = if latest, do: latest.height, else: 0

    ranges = Chain.missing_block_ranges(0, tip)

    total_missing =
      Enum.reduce(ranges, 0, fn {s, e}, acc -> acc + (e - s + 1) end)

    IO.puts("Chain tip: #{tip}")
    IO.puts("Missing blocks: #{total_missing}")
    IO.puts("Gap count: #{length(ranges)}")

    if length(ranges) > 0 do
      IO.puts("\nFirst 20 gaps:")

      ranges
      |> Enum.take(20)
      |> Enum.each(fn {s, e} ->
        count = e - s + 1
        IO.puts("  #{s}..#{e} (#{count} blocks)")
      end)
    end

    %{tip: tip, missing: total_missing, gaps: length(ranges), ranges: ranges}
  end

  # Sync missing blocks in chunks via SyncWorker
  defp backfill_blocks(from, tip, chunk_size) do
    alias Bitblocks.Chain

    ranges = Chain.missing_block_ranges(from, tip)

    total_missing =
      Enum.reduce(ranges, 0, fn {s, e}, acc -> acc + (e - s + 1) end)

    Logger.info("Backfill blocks: #{total_missing} missing in #{length(ranges)} gaps")

    if total_missing == 0 do
      Logger.info("Backfill blocks: no gaps found")
      :ok
    else
      # Process each gap range through SyncWorker in chunks
      Enum.each(ranges, fn {range_start, range_end} ->
        range_start
        |> Stream.iterate(&(&1 + chunk_size))
        |> Stream.take_while(&(&1 <= range_end))
        |> Enum.each(fn chunk_start ->
          chunk_end = min(chunk_start + chunk_size - 1, range_end)
          count = chunk_end - chunk_start + 1
          Logger.info("Backfill blocks: syncing #{chunk_start}..#{chunk_end} (#{count} blocks)")

          Bitblocks.SyncWorker.start_sync({chunk_start, chunk_end})
          wait_for_sync(30_000)
        end)
      end)
    end
  end

  # Queue transaction fetch jobs in batches.
  # Includes blocks stuck in failed/txs_queued/txs_syncing from prior runs.
  defp backfill_transactions(from, tip, batch_size) do
    alias Bitblocks.{Repo, Chain.Block}
    import Ecto.Query

    needs_tx_states = ["header_only", "header_synced", "pending", "failed", "txs_queued", "txs_syncing"]

    needs_txs_count =
      from(b in Block,
        where: b.height >= ^from and b.height <= ^tip,
        where: b.sync_state in ^needs_tx_states,
        select: count()
      )
      |> Repo.one()

    Logger.info("Backfill txs: #{needs_txs_count} blocks need transactions")

    if needs_txs_count == 0 do
      :ok
    else
      backfill_tx_batch(from, tip, batch_size, 0, needs_txs_count, needs_tx_states)
    end
  end

  defp backfill_tx_batch(from, tip, batch_size, queued_so_far, total, needs_tx_states) do
    alias Bitblocks.{Repo, Chain, Chain.Block}
    import Ecto.Query

    # Reset stuck blocks back to header_only so queue_transaction_fetch
    # will accept them and Oban uniqueness won't skip them.
    {reset_count, _} =
      from(b in Block,
        where: b.height >= ^from and b.height <= ^tip,
        where: b.sync_state in ["failed", "txs_queued", "txs_syncing"]
      )
      |> Repo.update_all(set: [sync_state: "header_only"])

    if reset_count > 0 do
      Logger.info("Backfill txs: reset #{reset_count} stuck blocks to header_only")
    end

    blocks =
      from(b in Block,
        where: b.height >= ^from and b.height <= ^tip,
        where: b.sync_state in ^needs_tx_states,
        order_by: [asc: b.height],
        limit: ^batch_size
      )
      |> Repo.all()

    if blocks == [] do
      Logger.info("Backfill txs: all batches queued (#{queued_so_far}/#{total})")
      :ok
    else
      Enum.each(blocks, &Chain.queue_transaction_fetch/1)
      new_total = queued_so_far + length(blocks)
      last_height = List.last(blocks).height

      Logger.info(
        "Backfill txs: queued #{new_total}/#{total} " <>
          "(through height #{last_height})"
      )

      # Wait for the batch to actually drain — no timeout.
      # backfill is a long-running rpc task; let it take as long as needed.
      wait_for_oban_drain(:infinity)

      backfill_tx_batch(last_height + 1, tip, batch_size, new_total, total, needs_tx_states)
    end
  end

  defp wait_for_sync(timeout) do
    start = System.monotonic_time(:millisecond)

    Stream.repeatedly(fn ->
      status = Bitblocks.SyncWorker.get_status()
      elapsed = System.monotonic_time(:millisecond) - start

      cond do
        status.status in [:completed, :stopped, :idle] -> :done
        elapsed > timeout -> :timeout
        true -> Process.sleep(500); :waiting
      end
    end)
    |> Enum.find(&(&1 != :waiting))
  end

  defp wait_for_oban_drain(timeout) do
    start = System.monotonic_time(:millisecond)

    Stream.repeatedly(fn ->
      import Ecto.Query
      pending =
        from(j in Oban.Job,
          where: j.queue == "transactions",
          where: j.state in ["available", "executing", "scheduled"],
          select: count()
        )
        |> Bitblocks.Repo.one()

      elapsed = System.monotonic_time(:millisecond) - start

      cond do
        pending == 0 ->
          :drained

        timeout != :infinity and elapsed > timeout ->
          :timeout

        true ->
          Process.sleep(2_000)
          :waiting
      end
    end)
    |> Enum.find(&(&1 != :waiting))
  end

  # Private helpers

  defp get_db_size do
    try do
      query = "SELECT pg_size_pretty(pg_database_size(current_database())) as size"
      result = Ecto.Adapters.SQL.query!(Bitblocks.Repo, query)

      case result.rows do
        [[size]] -> size
        _ -> "unknown"
      end
    rescue
      _ -> "unknown"
    end
  end
end
