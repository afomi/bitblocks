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

  @doc """
  Start sequential transaction backfill from the lowest incomplete block.

  Processes one block at a time using batch RPC, then moves to the next.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.start_backfill_transactions()'
  """
  def start_backfill_transactions do
    case %{}
         |> Bitblocks.Workers.BackfillTransactionsWorker.new()
         |> Oban.insert() do
      {:ok, job} ->
        IO.puts("Backfill started (Oban ##{job.id})")
        {:ok, job}

      {:error, reason} ->
        IO.puts("Backfill already running or failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stop transaction backfill.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.stop_backfill_transactions()'
  """
  def stop_backfill_transactions do
    import Ecto.Query

    {cancelled, _} =
      from(j in Oban.Job,
        where: j.worker == "Bitblocks.Workers.BackfillTransactionsWorker",
        where: j.state in ["available", "scheduled", "executing"]
      )
      |> Bitblocks.Repo.update_all(set: [state: "cancelled", cancelled_at: DateTime.utc_now()])

    IO.puts("Cancelled #{cancelled} backfill job(s)")
    {:ok, cancelled}
  end

  @doc """
  Clear all pending/scheduled/retryable Oban jobs.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.clear_jobs()'
  """
  def clear_jobs do
    import Ecto.Query

    {count, _} =
      from(j in Oban.Job,
        where: j.state in ["available", "scheduled", "retryable"]
      )
      |> Bitblocks.Repo.delete_all()

    IO.puts("Deleted #{count} pending job(s)")
    {:ok, count}
  end

  @doc """
  Recover blocks stuck in txs_queued or txs_syncing with no Oban job to process them.

  Resets them to header_synced and re-enqueues FetchTransactionsWorker jobs.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.recover_stuck_blocks()'
  """
  def recover_stuck_blocks do
    import Ecto.Query

    # Find blocks in txs_queued/txs_syncing that have no active Oban job
    active_hashes =
      from(j in Oban.Job,
        where: j.worker == "Bitblocks.Workers.FetchTransactionsWorker",
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        select: fragment("args->>'block_hash'")
      )
      |> Bitblocks.Repo.all()
      |> MapSet.new()

    stuck_blocks =
      from(b in Bitblocks.Chain.Block,
        where: b.sync_state in ["txs_queued", "txs_syncing"],
        select: %{id: b.id, hash: b.hash, height: b.height, sync_state: b.sync_state}
      )
      |> Bitblocks.Repo.all()
      |> Enum.reject(fn b -> MapSet.member?(active_hashes, b.hash) end)

    if stuck_blocks == [] do
      IO.puts("No stuck blocks found")
      {:ok, 0}
    else
      IO.puts("Found #{length(stuck_blocks)} stuck block(s), re-queuing...")

      # Reset to header_synced and re-queue
      stuck_ids = Enum.map(stuck_blocks, & &1.id)

      {updated, _} =
        from(b in Bitblocks.Chain.Block, where: b.id in ^stuck_ids)
        |> Bitblocks.Repo.update_all(set: [sync_state: "header_synced"])

      queued =
        Enum.count(stuck_blocks, fn b ->
          case Bitblocks.Chain.queue_transaction_fetch(b.hash) do
            {:ok, _} -> true
            _ -> false
          end
        end)

      IO.puts("Reset #{updated} block(s) to header_synced, queued #{queued} job(s)")
      {:ok, queued}
    end
  end

  @doc """
  Show a detailed sync status: block states + Oban job counts.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.sync_status()'
  """
  def sync_status do
    import Ecto.Query
    alias Bitblocks.{Repo, Chain.Block}

    # Block state breakdown
    state_counts =
      from(b in Block, group_by: b.sync_state, select: {b.sync_state, count(b.id)})
      |> Repo.all()
      |> Enum.sort_by(fn {_, c} -> -c end)

    total = Enum.reduce(state_counts, 0, fn {_, c}, acc -> acc + c end)

    IO.puts("\n=== Block Sync States ===")
    for {state, count} <- state_counts do
      pct = if total > 0, do: Float.round(count / total * 100, 1), else: 0
      IO.puts("  #{String.pad_trailing(state, 16)} #{count} (#{pct}%)")
    end
    IO.puts("  #{String.pad_trailing("TOTAL", 16)} #{total}")

    # Oban job counts by worker + state
    job_counts =
      from(j in Oban.Job,
        where: j.worker in [
          "Bitblocks.Workers.SyncHeadersWorker",
          "Bitblocks.Workers.FetchTransactionsWorker"
        ],
        group_by: [j.worker, j.state],
        select: {j.worker, j.state, count(j.id)}
      )
      |> Repo.all()

    IO.puts("\n=== Oban Jobs ===")
    if job_counts == [] do
      IO.puts("  No active sync jobs")
    else
      for {worker, state, count} <- Enum.sort(job_counts) do
        short_worker = worker |> String.split(".") |> List.last()
        IO.puts("  #{String.pad_trailing(short_worker, 28)} #{String.pad_trailing(state, 12)} #{count}")
      end
    end

    # Oldest executing tx job (is anything stuck?)
    oldest_executing =
      from(j in Oban.Job,
        where: j.worker == "Bitblocks.Workers.FetchTransactionsWorker",
        where: j.state == "executing",
        order_by: [asc: j.attempted_at],
        limit: 1,
        select: {j.id, j.attempted_at, j.args}
      )
      |> Repo.one()

    if oldest_executing do
      {id, started, args} = oldest_executing
      elapsed = DateTime.diff(DateTime.utc_now(), started, :second)
      IO.puts("\n=== Oldest Executing Tx Job ===")
      IO.puts("  Oban ##{id}, block_hash: #{args["block_hash"]}")
      IO.puts("  Running for #{elapsed}s")
    end

    IO.puts("")
    :ok
  end

  # ---------------------------------------------------------------------------
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
  Backfill missing blocks and transactions from height 0 to the chain tip.

  Delegates to sync_headers/2 which fills header gaps and auto-queues
  transaction fetches for each new block.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.backfill()'
      bin/bitblocks rpc 'Bitblocks.Release.backfill(from: 100_000, to: 200_000)'
  """
  def backfill(opts \\ []) do
    from = Keyword.get(opts, :from, 0)
    latest = Bitblocks.Chain.get_latest_block()
    chain_tip = if latest, do: latest.height, else: 0
    to = Keyword.get(opts, :to, chain_tip)

    sync_headers(from, to)
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
    IO.puts("backfill_txs is now handled by sync_headers — delegating.")
    backfill(opts)
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
