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
  One-time migration: move any jobs left on the retired `transactions` queue
  onto `transactions_backfill`.

  The tx-fetch work was split into `transactions_tip` + `transactions_backfill`
  lanes. Oban only runs queues named in config, so jobs still sitting in the old
  `transactions` queue after that change are orphaned (never picked up). This
  re-homes the pending ones. Idempotent and safe to run anytime — returns the
  number of jobs moved (0 if none). Run once after deploying the lane split.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.migrate_legacy_tx_queue()'
  """
  def migrate_legacy_tx_queue do
    %Postgrex.Result{num_rows: count} =
      Bitblocks.Repo.query!("""
        UPDATE oban_jobs
        SET queue = 'transactions_backfill'
        WHERE queue = 'transactions'
          AND state IN ('available', 'scheduled', 'retryable')
      """)

    IO.puts(
      "migrate_legacy_tx_queue: re-homed #{count} job(s) from transactions -> transactions_backfill"
    )

    count
  end

  @doc """
  Start sequential transaction backfill from the lowest incomplete block.

  Processes one block at a time using batch RPC, then moves to the next.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.start_backfill_transactions()'
  """
  def start_backfill_transactions do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Bitblocks.Repo.insert_all(
      "oban_jobs",
      [
        %{
          queue: "transactions_backfill",
          worker: "Bitblocks.Workers.BackfillTransactionsWorker",
          args: %{},
          state: "available",
          max_attempts: 3,
          inserted_at: now,
          scheduled_at: now
        }
      ],
      on_conflict: :nothing
    )

    IO.puts("Backfill job inserted")
    :ok
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

  @doc deprecated:
         "Use repair_incomplete_blocks/1 — it covers stuck states AND completed-with-deficit blocks"
  def recover_stuck_blocks do
    IO.puts("recover_stuck_blocks is deprecated — running repair_incomplete_blocks() instead.")
    repair_incomplete_blocks()
  end

  @doc """
  Clear `tx_sync_attempts` on blocks that exhausted the backfill retry budget,
  making them eligible again, and kick off a backfill pass.

  The backfill stops re-selecting a block after
  `:backfill_max_attempts` failures (default 3). That bound is what stops a
  permanently-failing block from spinning the worker — but it also means blocks
  that failed for a TRANSIENT reason (the BSV node was down) stay parked once
  the cause is fixed. Run this after the node is healthy again.

  Only resets blocks that are actually incomplete; `completed` blocks are left
  alone.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.retry_failed_blocks()'
  """
  def retry_failed_blocks do
    import Ecto.Query

    {count, _} =
      Bitblocks.Repo.update_all(
        from(b in Bitblocks.Chain.Block,
          where: b.sync_state != "completed" and coalesce(b.tx_sync_attempts, 0) > 0
        ),
        set: [tx_sync_attempts: 0, tx_sync_error: nil]
      )

    IO.puts("Reset retry counter on #{count} block(s).")

    if count > 0 do
      start_backfill_transactions()
    else
      IO.puts("Nothing to retry.")
      :ok
    end
  end

  @doc """
  Audit transaction completeness: per block, compare stored tx rows to the
  header's `num_tx` and report every deficit — regardless of sync_state.

  This is the check `sync_state = "completed"` alone cannot give you: a block
  whose tx array was truncated (>10k memory optimization) could previously be
  marked completed with zero transactions stored. One GROUP-BY join, single
  table scan — safe to run on demand, heavy enough not to run per-request.

  Caveat: the count is by `block_hash`, so a txid legitimately stored under
  another block's hash (reorg, BIP30 duplicate coinbase) makes this a LOWER
  bound — the audit may flag a block the worker's txid-intersection check will
  complete without fetching anything. That's fine: repair is idempotent and the
  re-check is cheap.

  ## Options
    - limit: max deficit rows to return (default 1_000)

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.audit_completeness()'
      bin/bitblocks rpc 'Bitblocks.Release.audit_completeness(limit: 50)'
  """
  def audit_completeness(opts \\ []) do
    limit = Keyword.get(opts, :limit, 1_000)

    %{rows: rows, num_rows: _} =
      Bitblocks.Repo.query!(
        """
        SELECT b.height, b.hash, b.sync_state, COALESCE(b.num_tx, 0) AS num_tx,
               COALESCE(t.cnt, 0) AS stored
        FROM blocks b
        LEFT JOIN (
          SELECT block_hash, COUNT(*) AS cnt
          FROM transactions
          GROUP BY block_hash
        ) t ON t.block_hash = b.hash
        WHERE COALESCE(t.cnt, 0) < GREATEST(COALESCE(b.num_tx, 0), 1)
        ORDER BY b.height
        LIMIT $1
        """,
        [limit]
      )

    deficits =
      Enum.map(rows, fn [height, hash, sync_state, num_tx, stored] ->
        %{
          height: height,
          hash: hash,
          sync_state: sync_state,
          num_tx: num_tx,
          stored: stored,
          missing: max(num_tx, 1) - stored
        }
      end)

    IO.puts(
      "audit_completeness: #{length(deficits)} block(s) with missing transactions" <>
        if(length(deficits) >= limit,
          do: " (limit #{limit} reached — there may be more)",
          else: ""
        )
    )

    deficits
    |> Enum.take(20)
    |> Enum.each(fn d ->
      IO.puts("  ##{d.height} #{d.sync_state} stored=#{d.stored}/#{d.num_tx} (#{d.hash})")
    end)

    %{count: length(deficits), deficits: deficits}
  end

  @doc """
  Repair every block the completeness audit flags, in ANY sync_state —
  including `completed`-with-deficit and `txs_queued`/`txs_syncing` orphans.

  Blocks with a live FetchTransactionsWorker Oban job are skipped (their job
  will fill them); everything else is reset to `header_synced` and the
  sequential backfill worker is started, which walks the deficits lowest-height
  first, fetching only the missing transactions (slow and steady — one block at
  a time on the concurrency-1 backfill lane, no per-block job flood).

  Idempotent: already-stored transactions are never re-fetched or re-upserted.

  ## Options
    - limit: max blocks to repair in this run (default 10_000)

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.repair_incomplete_blocks()'
  """
  def repair_incomplete_blocks(opts \\ []) do
    import Ecto.Query

    limit = Keyword.get(opts, :limit, 10_000)
    %{deficits: deficits} = audit_completeness(limit: limit)

    active_hashes =
      from(j in Oban.Job,
        where: j.worker == "Bitblocks.Workers.FetchTransactionsWorker",
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        select: fragment("args->>'block_hash'")
      )
      |> Bitblocks.Repo.all()
      |> MapSet.new()

    {active, repairable} = Enum.split_with(deficits, &MapSet.member?(active_hashes, &1.hash))

    reset =
      case repairable do
        [] ->
          0

        _ ->
          hashes = Enum.map(repairable, & &1.hash)

          {count, _} =
            from(b in Bitblocks.Chain.Block, where: b.hash in ^hashes)
            |> Bitblocks.Repo.update_all(set: [sync_state: "header_synced"])

          count
      end

    if reset > 0, do: start_backfill_transactions()

    IO.puts(
      "repair_incomplete_blocks: reset #{reset} block(s) to header_synced, " <>
        "skipped #{length(active)} with live fetch jobs" <>
        if(reset > 0, do: "; sequential backfill started", else: "")
    )

    {:ok, %{reset: reset, skipped_active: length(active)}}
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
        where:
          j.worker in [
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

        IO.puts(
          "  #{String.pad_trailing(short_worker, 28)} #{String.pad_trailing(state, 12)} #{count}"
        )
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

  Pass `audit: true` to also run the completeness audit (stored tx rows vs
  num_tx per block) — a full GROUP-BY over the transactions table, so it's
  opt-in rather than part of the default one-liner.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.status()'
      bin/bitblocks rpc 'Bitblocks.Release.status(audit: true)'
  """
  def status(opts \\ []) do
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

    audit =
      if Keyword.get(opts, :audit, false) do
        %{count: deficit_count} = result = audit_completeness()
        IO.puts("  Tx deficits:        #{deficit_count} block(s) (see audit_completeness/1)")
        result
      end

    IO.puts("========================\n")

    %{
      tip: tip,
      blocks: total_blocks,
      missing_blocks: missing_blocks,
      gaps: length(gaps),
      completed: completed,
      remaining: total_blocks - completed,
      lowest_incomplete: lowest_incomplete,
      transactions: total_txs,
      audit: audit
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

    Logger.info(
      "analyze_transactions: #{total_needing_analysis} transactions to analyze (version #{current_version})"
    )

    if total_needing_analysis == 0 do
      Logger.info("analyze_transactions: nothing to do")
      :ok
    else
      do_analyze_batch(0, 0, total_needing_analysis, batch_size, current_version)
    end
  end

  # Keyset-paginated by id: every batch starts after the last one, so a tx that
  # fails to analyze (and so keeps its old version) is never re-selected, and
  # batches don't re-scan the rows already done.
  defp do_analyze_batch(last_id, processed, total, batch_size, current_version) do
    alias Bitblocks.{Repo, Chain.Transaction, TransactionParser}
    import Ecto.Query

    txs =
      from(t in Transaction,
        where: t.id > ^last_id,
        where: not is_nil(t.raw),
        where: is_nil(t.script_analysis_version) or t.script_analysis_version < ^current_version,
        order_by: [asc: t.id],
        limit: ^batch_size,
        select: [:id, :txid, :raw, :block_height]
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
            |> Repo.update_all(
              set: [
                output_types: meta.output_types,
                protocols: meta.protocols,
                coinbase: meta.coinbase,
                script_analysis_version: meta.script_analysis_version,
                output_script_hashes: meta.output_script_hashes,
                output_template_hashes: meta.output_template_hashes,
                aip_signers: meta.aip_signers
              ]
            )

            # Bitcom commands are indexed from analyze output, so a re-analyze
            # must index them too (idempotent per txid + output).
            Bitblocks.Bitcom.index(%{tx | protocols: meta.protocols})

          {:error, reason} ->
            Logger.warning("analyze_transactions: failed for tx #{tx.id}: #{inspect(reason)}")
        end
      end)

      new_processed = processed + length(txs)
      Logger.info("analyze_transactions: #{new_processed}/#{total}")
      do_analyze_batch(List.last(txs).id, new_processed, total, batch_size, current_version)
    end
  end

  @doc """
  Checks the blob store (Bitblocks.TxStore): is it configured, how many txs
  are stored, and do `n` random stored objects still match the database's
  bytes? Prints and returns the result.

      bin/bitblocks rpc 'Bitblocks.Release.tx_store_check()'
  """
  def tx_store_check(n \\ 20) do
    case Bitblocks.TxStore.ready?() do
      :ok ->
        result = Bitblocks.TxStore.verify_sample(n)

        if result.bad == [],
          do:
            IO.puts(
              "tx store OK: #{result.stored} stored; #{result.ok}/#{result.checked} sampled match"
            ),
          else: IO.puts("tx store MISMATCH: #{inspect(result.bad)}")

        result

      {:error, reason} ->
        IO.puts("tx store not ready: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Backfill missing block HEADERS from height 0 to the chain tip.

  Delegates to sync_headers/2 (range mode) which fills header gaps only.
  This does NOT fetch transactions — run `backfill_transactions/1` afterward
  for that. (Range mode deliberately doesn't auto-queue tx fetches so a bulk
  backfill can't flood the job table; see docs/SYNCING.md.)

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

  @doc deprecated:
         "Use start_backfill_transactions/0 (sequential) or repair_incomplete_blocks/1 (audit-driven)"
  # The wave-based enqueuer flooded per-block FetchTransactionsWorker jobs and
  # skipped txs_queued/txs_syncing blocks entirely (stranding orphans). The
  # sequential BackfillTransactionsWorker replaces it: one block at a time on
  # the concurrency-1 backfill lane, diff-and-fill, self-rescheduling — slow
  # and steady, nothing competes and nothing floods.
  def backfill_transactions(opts \\ []) do
    _ = opts

    IO.puts(
      "backfill_transactions/1 (wave enqueuer) is deprecated — " <>
        "starting the sequential backfill worker instead."
    )

    start_backfill_transactions()
  end

  @doc deprecated: "Use backfill_transactions/1 (headers via backfill/1)"
  def backfill_txs(opts \\ []) do
    IO.puts("backfill_txs only syncs headers — for transactions use backfill_transactions/1.")
    backfill(opts)
  end

  @doc """
  Backfill block_height on transactions that have block_hash but no block_height.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_block_heights()'
  """
  def backfill_tx_block_heights do
    {count, _} =
      Bitblocks.Repo.query!("""
        UPDATE transactions t
        SET block_height = b.height
        FROM blocks b
        WHERE t.block_hash = b.hash
          AND t.block_height IS NULL
      """)

    IO.puts("Updated #{count} transaction(s) with block_height")
    {:ok, count}
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

  @doc """
  Registers a managed projection (#29, docs/MANAGED_SERVICES.md) and returns
  it, or the changeset errors. Hydrate it at `/api/v1/projections/:id/txs`.
  Set `from_height` to the first block it needs: status measures completeness
  from there.
  With `webhook_url`, new matches are POSTed there, signed with a generated
  secret that is printed once.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.create_projection(%{tenant: "visible-dao", name: "donations", filter: %{"output_addresses" => ["1..."]}, from_height: 900_000}) |> IO.inspect()'
  """
  def create_projection(attrs) do
    case Bitblocks.Projections.create(attrs) do
      {:ok, p} ->
        Logger.info("create_projection: ##{p.id} #{p.tenant}/#{p.name} #{p.definition_hash}")

        # Printed once to the operator's terminal, never logged: the tenant
        # needs it to verify signatures. (The schema redacts it from inspect.)
        if p.webhook_secret,
          do: IO.puts("webhook_secret (store it now; it is not shown again): #{p.webhook_secret}")

        {:ok, p}

      {:error, changeset} ->
        {:error, Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)}
    end
  end

  @doc """
  Sets (or replaces) a projection's webhook URL and rotates its secret,
  printing the new secret once. `nil` turns the webhook off.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.set_projection_webhook(1, "https://visibledao.com/hooks/bitblocks")'
  """
  def set_projection_webhook(id, url) do
    case Bitblocks.Projections.set_webhook(Bitblocks.Projections.get!(id), url) do
      {:ok, p} ->
        Logger.info(
          "set_projection_webhook: ##{p.id} webhook #{if url, do: "set", else: "removed"}"
        )

        if p.webhook_secret,
          do: IO.puts("webhook_secret (store it now; it is not shown again): #{p.webhook_secret}")

        {:ok, p}

      {:error, changeset} ->
        {:error, Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)}
    end
  end

  @doc """
  Moves a projection's `from_height`: status measures completeness and
  hydrate starts from there.

      bin/bitblocks rpc 'Bitblocks.Release.set_projection_from_height(1, 957_300) |> IO.inspect()'
  """
  def set_projection_from_height(id, height), do: update_projection(id, %{from_height: height})

  @doc "Pauses a projection: no webhooks are enqueued or delivered until resumed."
  def pause_projection(id), do: update_projection(id, %{status: "paused"})

  @doc "Resumes a paused projection. Matches from while it was paused are not replayed; hydrate them."
  def resume_projection(id), do: update_projection(id, %{status: "active"})

  defp update_projection(id, attrs) do
    case Bitblocks.Projections.update_settings(Bitblocks.Projections.get!(id), attrs) do
      {:ok, p} ->
        Logger.info("update_projection: ##{p.id} #{inspect(attrs)}")
        {:ok, p}

      {:error, changeset} ->
        {:error, Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)}
    end
  end

  @doc """
  Syncs a collection (#30) as Oban jobs, which survive deploys: import and
  walk the mint chain, then trace owners in checkpointed batches (a resumed
  run only does items not traced since it started). Returns at once; the last
  batch logs `sync_ordinal_collection <slug>: done …`. Progress:
  `collection_sync_status/1`. Accepts a slug or a collection origin outpoint.

      bin/bitblocks rpc 'Bitblocks.Release.sync_ordinal_collection("rexxies") |> IO.inspect()'

  `trace: false` imports and walks only.
  """
  def sync_ordinal_collection(slug, opts \\ []) do
    args = %{
      slug: slug,
      run_started_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      trace: Keyword.get(opts, :trace, true)
    }

    case Oban.insert(Bitblocks.Workers.CollectionSyncWorker.new(args)) do
      {:ok, %{conflict?: true, id: id}} ->
        IO.puts("sync_ordinal_collection #{slug}: already queued or running (job #{id})")
        {:ok, :already_running, id}

      {:ok, %{id: id}} ->
        IO.puts(
          "sync_ordinal_collection #{slug}: enqueued (job #{id}, run #{args.run_started_at})"
        )

        {:ok, :enqueued, id}

      {:error, reason} ->
        IO.puts("sync_ordinal_collection #{slug} FAILED to enqueue: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Progress of a collection sync: items by trace_state, and this collection's
  sync and trace jobs still pending.
  """
  def collection_sync_status(slug) do
    import Ecto.Query
    alias Bitblocks.OrdinalCollections

    cid = OrdinalCollections.resolve(slug)

    pending =
      from(j in Oban.Job,
        where:
          j.worker in [
            "Bitblocks.Workers.CollectionSyncWorker",
            "Bitblocks.Workers.CollectionTraceWorker"
          ] and
            j.state in ["available", "scheduled", "executing", "retryable"] and
            fragment("?->>'slug' = ?", j.args, ^slug),
        group_by: [j.worker, j.state],
        select: {j.worker, j.state, count()}
      )
      |> Bitblocks.Repo.all()
      |> Enum.map(fn {w, st, n} -> {"#{w |> String.split(".") |> List.last()} #{st}", n} end)
      |> Map.new()

    status = %{
      summary: if(cid, do: OrdinalCollections.summary(cid)),
      pending_jobs: pending
    }

    IO.puts("collection_sync_status #{slug}: #{inspect(status)}")
    status
  end

  @doc """
  Puts every tx of a collection in the blob store (Bitblocks.TxStore): the
  collection origin, each mint, each item's trail and current location.
  Items that moved before trails were recorded are re-walked from their origin
  first (`retrace: false` skips that). Writes run as Oban jobs; call again to
  see `stored` climb to `txids`.

      bin/bitblocks rpc 'Task.start(fn -> Bitblocks.Release.store_collection_blobs("rexxies") end)'
  """
  def store_collection_blobs(slug, opts \\ []) do
    import Ecto.Query
    alias Bitblocks.OrdinalCollections
    alias Bitblocks.OrdinalCollections.Item

    with cid when is_binary(cid) <-
           OrdinalCollections.resolve(slug) || {:error, :unknown_collection},
         :ok <- Bitblocks.TxStore.ready?() do
      items = Bitblocks.Repo.all(from i in Item, where: i.collection_id == ^cid)

      retraced =
        if Keyword.get(opts, :retrace, true) do
          for item <- items, item.trail == [], item.current_outpoint != item.origin do
            {:ok, _} = OrdinalCollections.trace(item, from: :origin)
          end
          |> length()
        else
          0
        end

      items = Bitblocks.Repo.all(from i in Item, where: i.collection_id == ^cid)
      outpoint_txid = fn op -> op |> String.split("_") |> hd() end

      txids =
        [outpoint_txid.(cid)]
        |> Enum.concat(Enum.map(items, & &1.mint_txid))
        |> Enum.concat(Enum.flat_map(items, & &1.trail))
        |> Enum.concat(for i <- items, i.current_outpoint, do: outpoint_txid.(i.current_outpoint))
        |> Enum.uniq()

      import = OrdinalCollections.import_txs(txids)
      enqueued = Bitblocks.TxStore.enqueue(txids)

      stored =
        Bitblocks.Repo.aggregate(
          from(t in Bitblocks.Chain.Transaction,
            where: t.txid in ^txids and not is_nil(t.blob_stored_at)
          ),
          :count
        )

      result = %{
        txids: length(txids),
        stored: stored,
        enqueued: enqueued,
        retraced: retraced,
        import_failed: length(import.failed)
      }

      IO.puts("store_collection_blobs #{slug}: #{inspect(result)}")
      {:ok, result}
    else
      {:error, reason} ->
        IO.puts("store_collection_blobs #{slug} FAILED: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Creates an API key with its own rate budget (requests per minute) and prints
  the key once. Give it to the caller (e.g. qart's server) to send as
  `Authorization: Bearer <key>`; only its hash is stored.

      bin/bitblocks rpc 'Bitblocks.Release.create_api_key("qart", 1200)'
  """
  def create_api_key(name, requests_per_minute) do
    case Bitblocks.ApiKeys.create(name, requests_per_minute) do
      {:ok, key, token} ->
        Logger.info(
          "create_api_key: ##{key.id} #{name} #{requests_per_minute}/min #{key.prefix}…"
        )

        IO.puts(
          "api key ##{key.id} (#{name}, #{requests_per_minute}/min). Store it now; it is not shown again:\n#{token}"
        )

        {:ok, key.id}

      {:error, changeset} ->
        {:error, Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)}
    end
  end

  @doc "Lists API keys as `{id, name, prefix, requests_per_minute, revoked_at}`."
  def list_api_keys do
    for k <- Bitblocks.ApiKeys.list(),
        do: {k.id, k.name, k.prefix, k.requests_per_minute, k.revoked_at}
  end

  @doc "Revokes an API key; requests with it get a 401 within a minute."
  def revoke_api_key(id) do
    with {:ok, key} <- Bitblocks.ApiKeys.revoke(id) do
      Logger.info("revoke_api_key: ##{key.id} #{key.name}")
      {:ok, key.id}
    end
  end

  @doc "Lists managed projections as `{id, tenant, name, status}`."
  def list_projections do
    for p <- Bitblocks.Projections.list(), do: {p.id, p.tenant, p.name, p.status}
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
