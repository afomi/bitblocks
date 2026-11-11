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

  # Runs `fun` with the repo up. Under `bin/bitblocks rpc` the app is already
  # running; under `bin/bitblocks eval` nothing is, so start the repo (and the
  # HTTP client, for node and WhatsOnChain lookups) just for this call.
  @doc false
  def with_running_repo(fun) do
    if Process.whereis(Bitblocks.Repo) do
      fun.()
    else
      load_app()
      {:ok, _} = Application.ensure_all_started(:httpoison)

      {:ok, result, _} =
        Ecto.Migrator.with_repo(Bitblocks.Repo, fn _ -> fun.() end, pool_size: 2)

      result
    end
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end

  # ---------------------------------------------------------------------------
  # Sync (the loop runs itself: Workers.SyncWorker, docs/SYNCING.md)
  # ---------------------------------------------------------------------------

  @doc """
  Store block headers for a height range, filling gaps. Safe to re-run.
  The sync loop fills headers by itself; this is for a manual range.

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
  Reopens `completed` blocks in `from..to` that hold fewer rows than `num_tx`
  (`Bitblocks.Sync.reopen_short_blocks/3`). Dry run by default.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.reopen_short_blocks(944_000, 958_000)'
      bin/bitblocks rpc 'Bitblocks.Release.reopen_short_blocks(944_000, 958_000, apply: true)'
  """
  def reopen_short_blocks(from, to, opts \\ []) do
    report = Bitblocks.Sync.reopen_short_blocks(from, to, opts)

    IO.puts(
      "reopen_short_blocks #{from}..#{to}: #{report.short} short of #{report.examined} completed, " <>
        "#{report.rows_missing} rows missing, #{report.reopened} reopened" <>
        if(report.applied, do: "", else: " (dry run)")
    )

    report
  end

  @doc """
  Show the sync loop's position (`complete_through`, our last known block,
  the target block holding it back), block states and Oban job counts.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.sync_status()'
  """
  def sync_status do
    import Ecto.Query
    alias Bitblocks.{Repo, Chain.Block}

    %{tip: tip, complete_through: through, target: target} = sync = Bitblocks.Sync.status()

    IO.puts("\n=== Sync loop ===")
    IO.puts("  Complete through block #{through} (of #{tip || "none"} known)")

    if target do
      block = Repo.get_by(Block, height: target)

      IO.puts(
        "  Target: block #{target}" <>
          if(block,
            do:
              " (#{block.sync_state}, #{block.tx_sync_attempts || 0} failure(s) in a row" <>
                if(block.tx_sync_error, do: ", last error: #{block.tx_sync_error}", else: "") <>
                ")",
            else: " (header missing; the loop fills it)"
          )
      )
    else
      IO.puts("  Target: none, complete to the last known block")
    end

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
            "Bitblocks.Workers.SyncWorker",
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
    sync
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
    # An exact count over ~10M rows outruns the pool's query timeout on prod
    # (2026-11-04). The planner's estimate is instant and close enough here.
    total_txs = estimated_row_count("transactions")
    latest = Chain.get_latest_block()
    tip = if latest, do: latest.height, else: 0

    completed =
      from(b in Block, where: b.sync_state == "completed", select: count())
      |> Repo.one()

    gaps = Chain.missing_block_ranges(0, tip)
    missing_blocks = Enum.reduce(gaps, 0, fn {s, e}, acc -> acc + (e - s + 1) end)

    complete_through = Bitblocks.Sync.complete_through(latest && tip)

    IO.puts("\n=== Bitblocks Status ===")
    IO.puts("  Chain tip:          #{tip}")
    IO.puts("  Blocks in DB:       #{total_blocks}")
    IO.puts("  Missing blocks:     #{missing_blocks} (#{length(gaps)} gaps)")
    IO.puts("  Blocks completed:   #{completed}/#{total_blocks} (txs fully synced)")
    IO.puts("  Blocks remaining:   #{total_blocks - completed}")
    IO.puts("  Complete through:   block #{complete_through} (of #{tip} known)")
    IO.puts("  Transactions in DB: ~#{total_txs} (estimate)")

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
      complete_through: complete_through,
      transactions: total_txs,
      audit: audit
    }
  end

  # ---------------------------------------------------------------------------
  # Derived data: backfills that bring rows up to the pipeline's current
  # versions, each recorded in derivation_runs (docs/DERIVED_DATA.md).

  @doc """
  Brings the tallies (sats in, sats out, fee, burned) of completed blocks
  from `from_height` to `to_height` up to `TxPipeline.version(:tallies)`,
  then rewrites those blocks' totals (`block_totals`). Picks only rows whose
  stamp is nil or older, in bounded batches in height order, so a rerun
  after a full apply finds nothing. Records the run in `derivation_runs`.
  See `Bitblocks.Chain.TxPipeline.Backfill` and `docs/DERIVED_DATA.md`.

  **Dry run by default**: prints what it would stamp and writes only its
  run record. Pass `apply: true` to write.

  It ends by printing the rows changed and the rows still below the version
  in the range: 0 for a complete run.

  ## Options
    - apply: true to write (default false)
    - force: true to recompute every row in the range, whatever its stamp
    - block_batch: blocks per batch (default 100)
    - tx_batch: txs per page within a block (default 1,000)
    - pause_ms: sleep after each page written (default 50)
    - statement_timeout_ms: per page (default 60,000)

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_tallies(0, 10_000)'
      bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_tallies(0, 10_000, apply: true)'
  """
  def backfill_tx_tallies(from_height, to_height, opts \\ [])
      when is_integer(from_height) and is_integer(to_height) do
    command = command("backfill_tx_tallies", [from_height, to_height], opts)

    with_running_repo(fn ->
      report =
        Bitblocks.Chain.TxPipeline.Backfill.run(
          from_height,
          to_height,
          opts
          |> Keyword.put_new(:on_batch, &print_progress/1)
          |> Keyword.put(:command, command)
        )

      print_tally_backfill(report)
      report
    end)
  end

  defp print_tally_backfill(r) do
    print_run_header(r, "tx tallies for completed blocks")
    d = r.details

    IO.puts("  #{r.blocks_examined} block(s), #{r.rows_examined} transaction(s) scanned")

    IO.puts(
      "  #{r.rows_changed} transaction(s) #{if r.applied, do: "stamped", else: "to stamp"}" <>
        " v#{r.version}, #{d.values_changed} with values that change"
    )

    IO.puts(
      "  #{d.sats_in_unknown} transaction(s) with sats in unknown (a previous tx not stored)"
    )

    IO.puts(
      "  #{d.blocks_changed} block total(s) #{if r.applied, do: "written", else: "to write"}" <>
        " v#{d.block_totals_version}, #{d.block_values_changed} with values that change"
    )

    case d.unverified do
      [] ->
        IO.puts("  every block with a known reward and fees verifies: reward <= subsidy + fees")

      heights ->
        IO.puts(
          "  #{length(heights)} block(s) FAIL miner reward <= subsidy + fees: " <>
            Enum.map_join(Enum.take(heights, 20), ", ", &to_string/1)
        )
    end

    if d.reward_unknown > 0 do
      IO.puts(
        "  #{d.reward_unknown} block(s) NOT CHECKED: no coinbase known, so no miner reward; " <>
          "run backfill_script_analysis over the range, then this again"
      )
    end

    IO.puts(
      "  #{r.rows_below_version} transaction(s) and #{d.blocks_below_version} block(s)" <>
        " below the version in the range"
    )

    print_run_footer(r)
  end

  @doc """
  Brings script analysis (output types, protocols, coinbase, script and
  template hashes, AIP signers) of the txs of stored blocks from
  `from_height` to `to_height` up to the `script_analysis` step's version
  (`TransactionParser.script_analysis_version/0`), and re-indexes their
  Bitcom commands. Picks only rows whose stamp is nil or older, in bounded
  height windows; a rerun after a full apply finds nothing. Records the run
  in `derivation_runs`. See `Bitblocks.Chain.TxPipeline.ScriptAnalysisBackfill`.

  **Dry run by default**; `apply: true` writes.

  ## Options
    - apply: true to write (default false)
    - force: true to re-analyze every row in the range
    - batch_size: txs per page (default 500)
    - block_batch: blocks per batch (default 100)
    - pause_ms, statement_timeout_ms: as `backfill_tx_tallies/3`

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.backfill_script_analysis(0, 10_000)'
      bin/bitblocks rpc 'Bitblocks.Release.backfill_script_analysis(0, 10_000, apply: true)'
  """
  def backfill_script_analysis(from_height, to_height, opts \\ [])
      when is_integer(from_height) and is_integer(to_height) do
    command = command("backfill_script_analysis", [from_height, to_height], opts)

    with_running_repo(fn ->
      report =
        Bitblocks.Chain.TxPipeline.ScriptAnalysisBackfill.run(
          from_height,
          to_height,
          opts
          |> Keyword.put_new(:on_batch, &print_progress/1)
          |> Keyword.put(:command, command)
        )

      print_script_analysis_backfill(report)
      report
    end)
  end

  @doc """
  Brings transaction types (afomi/bitblocks#49) of completed blocks from
  `from_height` to `to_height` up to `TxPipeline.version(:tx_types)`, then
  rewrites those blocks' `type_counts`, which `/types` sums. Picks only
  blocks and rows whose stamp is nil or older, in bounded batches in height
  order, so a rerun after a full apply finds nothing. Writes only the rows
  whose types change, and stamps the block (`blocks.tx_types_version`) for
  the rest. Records the run in `derivation_runs`. See
  `Bitblocks.Chain.TxPipeline.TxTypesBackfill`.

  **Dry run by default**; `apply: true` writes.

  ## Options
    - apply: true to write (default false)
    - force: true to re-type every row in the range
    - block_batch: blocks per batch (default 100)
    - tx_batch: txs per page within a block (default 1,000)
    - pause_ms, statement_timeout_ms: as `backfill_tx_tallies/3`

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_types(0, 10_000)'
      bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_types(0, 10_000, apply: true)'
  """
  def backfill_tx_types(from_height, to_height, opts \\ [])
      when is_integer(from_height) and is_integer(to_height) do
    command = command("backfill_tx_types", [from_height, to_height], opts)

    with_running_repo(fn ->
      report =
        Bitblocks.Chain.TxPipeline.TxTypesBackfill.run(
          from_height,
          to_height,
          opts
          |> Keyword.put_new(:on_batch, &print_progress/1)
          |> Keyword.put(:command, command)
        )

      print_tx_types_backfill(report)
      report
    end)
  end

  @doc """
  Runs the `:tx` steps (`record_spends`, `index_tokens`, `index_bitcom`) for
  the txs of stored blocks from `from_height` to `to_height` that never met
  them: rows an earlier sync stored, which the sync skips. Run
  `backfill_script_analysis/3` over the range first. Records the run in
  `derivation_runs`. See `Bitblocks.Chain.TxPipeline.TxStepsBackfill`.

  **Dry run by default**; `apply: true` writes.

      bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_steps(0, 10_000)'
      bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_steps(0, 10_000, apply: true)'
  """
  def backfill_tx_steps(from_height, to_height, opts \\ [])
      when is_integer(from_height) and is_integer(to_height) do
    command = command("backfill_tx_steps", [from_height, to_height], opts)

    with_running_repo(fn ->
      report =
        Bitblocks.Chain.TxPipeline.TxStepsBackfill.run(
          from_height,
          to_height,
          opts
          |> Keyword.put_new(:on_batch, &print_progress/1)
          |> Keyword.put(:command, command)
        )

      print_tx_steps_backfill(report)
      report
    end)
  end

  @doc """
  Re-reads who holds each token output of heights `from_height` to `to_height`
  below the current version, from the output's lock, and fills `recipient`,
  `lock` and `cosigner`. Records the run in `derivation_runs`. See
  `Bitblocks.Chain.TxPipeline.TokenRecipientsBackfill` (#69).

  **Dry run by default**; `apply: true` writes.

      bin/bitblocks rpc 'Bitblocks.Release.backfill_token_recipients(0, 980_000)'
      bin/bitblocks rpc 'Bitblocks.Release.backfill_token_recipients(0, 980_000, apply: true)'
  """
  def backfill_token_recipients(from_height, to_height, opts \\ [])
      when is_integer(from_height) and is_integer(to_height) do
    command = command("backfill_token_recipients", [from_height, to_height], opts)

    with_running_repo(fn ->
      report =
        Bitblocks.Chain.TxPipeline.TokenRecipientsBackfill.run(
          from_height,
          to_height,
          opts
          |> Keyword.put_new(:on_batch, &print_progress/1)
          |> Keyword.put(:command, command)
        )

      print_token_recipients_backfill(report)
      report
    end)
  end

  @doc """
  Fills `timelocks` with the script time locks of stored txs at heights
  `from_height` to `to_height` (#76): 1Sat Locks, CLTV and CSV, each with
  whether it binds and on which path. Reads raw bytes only for txs with an
  output script analysis left `unknown`, and writes only to `timelocks`.
  Records the run in `derivation_runs`. See
  `Bitblocks.Chain.TxPipeline.TimelocksBackfill`.

  **Dry run by default**; `apply: true` writes.

      bin/bitblocks rpc 'Bitblocks.Release.backfill_timelocks(800_000, 850_000)'
      bin/bitblocks rpc 'Bitblocks.Release.backfill_timelocks(800_000, 850_000, apply: true)'
  """
  def backfill_timelocks(from_height, to_height, opts \\ [])
      when is_integer(from_height) and is_integer(to_height) do
    command = command("backfill_timelocks", [from_height, to_height], opts)

    with_running_repo(fn ->
      report =
        Bitblocks.Chain.TxPipeline.TimelocksBackfill.run(
          from_height,
          to_height,
          opts
          |> Keyword.put_new(:on_batch, &print_progress/1)
          |> Keyword.put(:command, command)
        )

      print_timelocks_backfill(report)
      report
    end)
  end

  defp print_timelocks_backfill(r) do
    print_run_header(r, "script time locks")
    d = r.details
    IO.puts("  #{r.blocks_examined} block(s) walked, #{r.rows_examined} candidate tx(s) read")

    IO.puts(
      "  #{d.locks_found} lock(s) found: #{d.one_sat_lock} 1Sat Lock, #{d.cltv} CLTV, #{d.csv} CSV; " <>
        "#{d.enforced} enforced, #{d.conditional} on one path only"
    )

    IO.puts("  #{r.rows_changed} lock row(s) #{if r.applied, do: "written", else: "to write"}")

    if d.no_raw > 0 do
      IO.puts("  #{d.no_raw} candidate tx(s) NOT READ: no bytes in the database")
    end

    IO.puts("  #{r.rows_below_version} lock row(s) missing or below the version in the range")
    print_run_footer(r)
  end

  defp print_token_recipients_backfill(r) do
    print_run_header(r, "token recipients")
    d = r.details

    IO.puts(
      "  #{r.rows_changed} token output(s) #{if r.applied, do: "stamped", else: "to stamp"}"
    )

    IO.puts(
      "  #{d.recipients_filled} recipient(s) #{if r.applied, do: "filled", else: "to fill"}"
    )

    IO.puts("  #{d.cosign} under a cosign lock, held by the owner")
    IO.puts("  #{d.unknown_lock} under another lock, recipient unknown")

    if d.no_raw > 0 do
      IO.puts(
        "  #{d.no_raw} token output(s) NOT READ: no bytes for the tx, left below the version"
      )
    end

    IO.puts("  #{r.rows_below_version} token output(s) below the version in the range")
    print_run_footer(r)
  end

  defp print_tx_steps_backfill(r) do
    print_run_header(r, "tx steps for stored blocks")
    IO.puts("  #{r.blocks_examined} block(s) walked")

    IO.puts(
      "  #{r.rows_changed} transaction(s) with no spends #{if r.applied, do: "run", else: "to run"}"
    )

    if r.details.not_analysed > 0 do
      IO.puts(
        "  #{r.details.not_analysed} transaction(s) NOT ANALYSED, left out: " <>
          "run backfill_script_analysis over the range, then this again"
      )
    end

    IO.puts("  #{r.rows_below_version} transaction(s) without spends in the range")
    print_run_footer(r)
  end

  @doc """
  Fills `transactions.size_bytes` and `raw_in_db` on older rows
  (`Bitblocks.Chain.TxSizeBackfill`). Records the run in `derivation_runs`.

  **Dry run by default**; `apply: true` writes.

      bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_sizes()'
      bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_sizes(apply: true)'
  """
  def backfill_tx_sizes(opts \\ []) do
    command = command("backfill_tx_sizes", [], opts)

    with_running_repo(fn ->
      report =
        Bitblocks.Chain.TxSizeBackfill.run(
          opts
          |> Keyword.put_new(:on_batch, &print_progress/1)
          |> Keyword.put(:command, command)
        )

      print_run_header(report, "tx sizes for every stored tx")

      IO.puts(
        "  #{report.rows_changed} transaction(s) #{if report.applied, do: "filled", else: "to fill"}"
      )

      IO.puts(
        "  #{report.details.over_threshold} over " <>
          "#{Bitblocks.Chain.Transaction.raw_in_db_max_bytes()} bytes, " <>
          "#{report.details.no_raw} with no raw bytes"
      )

      IO.puts("  #{report.rows_below_version} transaction(s) still unfilled")
      print_run_footer(report)
      report
    end)
  end

  @doc """
  Starts a backfill as a chain of Oban jobs, one range at a time
  (`Bitblocks.BackfillChains`): it needs no open connection and carries on
  across a deploy. `derivation` is `"script_analysis"`, `"tx_steps"`,
  `"tallies"`, `"tx_types"`, `"bap"`, `"token_recipients"` or `"timelocks"` over heights
  `from..to`.

  **Dry run by default**; `apply: true` writes. `step:` sets the range one job
  takes (10,000); the other options are the backfill's own.

      bin/bitblocks rpc 'Bitblocks.Release.start_backfill("tx_steps", 0, 180_830)'
      bin/bitblocks rpc 'Bitblocks.Release.start_backfill("tx_steps", 0, 180_830, apply: true)'
      bin/bitblocks rpc 'Bitblocks.Release.backfill_status()'
      bin/bitblocks rpc 'Bitblocks.Release.backfill_status(1)'
      bin/bitblocks rpc 'Bitblocks.Release.pause_backfill(1)'
      bin/bitblocks rpc 'Bitblocks.Release.resume_backfill(1)'
      bin/bitblocks rpc 'Bitblocks.Release.cancel_backfill(1)'
  """
  def start_backfill(derivation, from, to, opts \\ []) do
    with_running_repo(fn ->
      derivation
      |> Bitblocks.BackfillChains.start(from, to, opts)
      |> print_chain_result("started")
    end)
  end

  @doc """
  `start_backfill/4` for `backfill_tx_sizes/1`: every stored tx, by id.

      bin/bitblocks rpc 'Bitblocks.Release.start_tx_sizes_backfill()'
      bin/bitblocks rpc 'Bitblocks.Release.start_tx_sizes_backfill(apply: true)'
  """
  def start_tx_sizes_backfill(opts \\ []) do
    with_running_repo(fn ->
      {from, to} = Bitblocks.BackfillChains.tx_id_range()

      "tx_size"
      |> Bitblocks.BackfillChains.start(from, to, opts)
      |> print_chain_result("started")
    end)
  end

  @doc "Stops a backfill chain once the range in flight finishes."
  def pause_backfill(id) do
    with_running_repo(fn ->
      id |> Bitblocks.BackfillChains.pause() |> print_chain_result("paused")
    end)
  end

  @doc "Carries a paused or failed backfill chain on from where it stopped."
  def resume_backfill(id) do
    with_running_repo(fn ->
      id |> Bitblocks.BackfillChains.resume() |> print_chain_result("resumed")
    end)
  end

  @doc "Ends a backfill chain once the range in flight finishes."
  def cancel_backfill(id) do
    with_running_repo(fn ->
      id |> Bitblocks.BackfillChains.cancel() |> print_chain_result("cancelled")
    end)
  end

  @doc """
  One backfill chain's report: where it has got to and the counts summed over
  its finished ranges. With no id, one line for each of the latest chains.
  """
  def backfill_status do
    with_running_repo(fn ->
      chains = Bitblocks.BackfillChains.list()
      if chains == [], do: IO.puts("No backfill chains yet.")
      Enum.each(chains, &IO.puts(chain_line(&1)))
      chains
    end)
  end

  def backfill_status(id) do
    with_running_repo(fn ->
      case Bitblocks.BackfillChains.status(id) do
        nil ->
          IO.puts("No backfill chain ##{id}.")
          nil

        status ->
          print_chain_status(status)
          status
      end
    end)
  end

  defp print_chain_result({:ok, chain}, verb) do
    IO.puts("#{String.upcase(verb)}: #{chain_line(chain)}")
    {:ok, chain}
  end

  defp print_chain_result({:error, reason} = error, verb) do
    IO.puts("NOT #{String.upcase(verb)}: #{inspect(reason)}")
    error
  end

  defp chain_line(c) do
    "##{c.id} #{c.derivation} #{c.range_from}..#{c.range_to} " <>
      "#{if c.applied, do: "APPLY", else: "DRY RUN"}: #{c.status}, next #{c.next_from}"
  end

  defp print_chain_status(s) do
    IO.puts(chain_line(s.chain))

    IO.puts("  #{s.ranges_done} of #{s.ranges_total} range(s) finished" <> chain_progress(s))

    IO.puts("  #{s.blocks_examined} block(s), #{s.rows_examined} row(s) examined")
    IO.puts("  #{s.rows_changed} row(s) #{if s.chain.applied, do: "changed", else: "to change"}")
    IO.puts("  #{s.rows_below_version} row(s) below the version in those ranges")

    for {key, value} <- Enum.sort(s.details), do: IO.puts("  #{key}: #{value}")

    if s.not_ok > 0,
      do: IO.puts("  #{s.not_ok} run(s) cut or failed; their ranges were retried")

    if s.chain.error, do: IO.puts("  error: #{s.chain.error}")
  end

  # What the chain is doing now. A paused or cancelled chain never reads as
  # working: it says so, and names the range it takes next.
  defp chain_progress(%{chain: %{status: status}, current: %{command: command}})
       when status in ["paused", "cancelled"],
       do: ", #{status}, finishing #{command}"

  defp chain_progress(%{current: %{command: command}}), do: ", working #{command}"

  defp chain_progress(%{chain: %{status: "running"}, alive: false} = s),
    do: ", queued" <> range_note(" for", s.next_range)

  defp chain_progress(%{chain: %{status: "running"}}), do: ""

  defp chain_progress(%{chain: %{status: status}} = s),
    do: ", #{status}" <> range_note("; next", s.next_range)

  defp range_note(_lead, nil), do: ""
  defp range_note(lead, {from, to}), do: "#{lead} #{from}..#{to}"

  defp print_tx_types_backfill(r) do
    print_run_header(r, "tx types for completed blocks")
    d = r.details

    IO.puts("  #{r.blocks_examined} block(s), #{r.rows_examined} transaction(s) scanned")

    IO.puts(
      "  #{r.rows_changed} transaction row(s) #{if r.applied, do: "written", else: "to write"}" <>
        " v#{r.version}, #{d.types_changed} with types that change"
    )

    IO.puts(
      "  #{d.blocks_typed} block(s) #{if r.applied, do: "stamped", else: "to stamp"}" <>
        " v#{r.version} for their unchanged transactions"
    )

    IO.puts("  #{d.undecodable} transaction(s) don't decode and stay untyped")

    IO.puts(
      "  #{d.blocks_changed} block type count(s) #{if r.applied, do: "written", else: "to write"}" <>
        " v#{d.type_counts_version}"
    )

    IO.puts(
      "  #{r.rows_below_version} transaction(s) and #{d.blocks_below_version} block(s)" <>
        " below the version in the range"
    )

    print_run_footer(r)
  end

  @doc """
  Brings script analysis of every stored transaction up to the current
  version, applying as it goes: `backfill_script_analysis/3` over all rows,
  heights or not (paged by id), recorded in `derivation_runs`.
  Idempotent; returns `:ok` when the run finished, `{:error, report}` when
  it stopped. Kept for the existing runbooks; prefer
  `backfill_script_analysis/3`, which dry-runs first and walks a height range.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.analyze_transactions()'
      bin/bitblocks rpc 'Bitblocks.Release.analyze_transactions(batch_size: 1000)'
  """
  def analyze_transactions(opts \\ []) do
    command = command("analyze_transactions", [], opts)

    with_running_repo(fn ->
      report =
        Bitblocks.Chain.TxPipeline.ScriptAnalysisBackfill.run(
          nil,
          nil,
          opts
          |> Keyword.put_new(:apply, true)
          |> Keyword.put_new(:on_batch, &print_progress/1)
          |> Keyword.put(:command, command)
        )

      print_script_analysis_backfill(report)
      if report.outcome == "ok", do: :ok, else: {:error, report}
    end)
  end

  defp print_script_analysis_backfill(r) do
    print_run_header(r, "script analysis")
    IO.puts("  #{r.rows_examined} transaction(s) below v#{r.version} found")

    IO.puts(
      "  #{r.rows_changed} transaction(s) #{if r.applied, do: "stamped", else: "to stamp"} v#{r.version}"
    )

    IO.puts("  #{r.details.undecodable} transaction(s) don't decode and keep their old stamp")
    IO.puts("  #{r.rows_below_version} transaction(s) below the version in the range")
    print_run_footer(r)
  end

  defp print_progress(r) do
    IO.puts(
      "  ...#{r.rows_examined} row(s) read, #{r.rows_changed} #{if r.applied, do: "stamped", else: "to stamp"}"
    )
  end

  defp print_run_header(r, what) do
    range =
      if r.from_height, do: " #{r.from_height}..#{r.to_height}", else: " (every stored tx)"

    IO.puts(
      if(r.applied, do: "APPLIED", else: "DRY RUN (nothing written)") <>
        ": #{what}#{range}, v#{r.version}, derivation run ##{r.run_id}"
    )
  end

  defp print_run_footer(r) do
    case r.outcome do
      "ok" -> IO.puts("  outcome: ok")
      outcome -> IO.puts("  outcome: #{String.upcase(outcome)}: #{r.error}")
    end

    if r.outcome == "ok" and not r.applied and r.rows_changed > 0,
      do: IO.puts("  Run again with apply: true to write these.")
  end

  @doc """
  Closes derivation runs left `running` by a restart as `abandoned`
  (`Bitblocks.Derivations.close_abandoned/2`). Name them by id or start
  time; a dry run unless `apply: true`.

      bin/bitblocks rpc 'Bitblocks.Release.close_abandoned_derivation_runs(ids: [1, 2])'
      bin/bitblocks rpc 'Bitblocks.Release.close_abandoned_derivation_runs([ids: [1, 2]], apply: true)'
  """
  def close_abandoned_derivation_runs(which, opts \\ []) do
    with_running_repo(fn ->
      result = Bitblocks.Derivations.close_abandoned(which, opts)
      verb = if result.applied, do: "closed as abandoned", else: "would close as abandoned"

      for id <- result.closed, do: IO.puts("##{id} #{verb}")
      for id <- result.skipped, do: IO.puts("##{id} already finished; left alone")
      if result.closed == [], do: IO.puts("No running runs matched.")

      if not result.applied and result.closed != [],
        do: IO.puts("Run again with apply: true to close these.")

      result
    end)
  end

  # The command as typed, for the derivation_runs record.
  defp command(name, args, opts) do
    opts = Keyword.drop(opts, [:on_batch, :command])

    args =
      Enum.map(args, &inspect/1) ++
        if(opts == [], do: [], else: [inspect(opts) |> String.slice(1..-2//1)])

    "Release.#{name}(#{Enum.join(args, ", ")})"
  end

  @doc """
  Prints and returns the latest derivation runs, newest first: what each
  derived, at which version and range, dry run or applied, the counts, and
  the outcome. Options: `limit:` (20), `derivation:` ("tallies",
  "script_analysis").

      bin/bitblocks rpc 'Bitblocks.Release.derivation_runs()'
      bin/bitblocks rpc 'Bitblocks.Release.derivation_runs(derivation: "tallies", limit: 5)'
  """
  def derivation_runs(opts \\ []) do
    with_running_repo(fn ->
      runs = Bitblocks.Derivations.list_runs(opts)

      for r <- runs do
        range = if r.from_height, do: "#{r.from_height}..#{r.to_height}", else: "all"

        IO.puts(
          "##{r.id} #{r.derivation} v#{r.version} #{range} " <>
            "#{if r.applied, do: "applied", else: "dry run"} #{r.outcome}: " <>
            "examined #{r.rows_examined}, changed #{r.rows_changed}, " <>
            "below version #{inspect(r.rows_below_version)}; " <>
            "#{r.started_at} -> #{inspect(r.finished_at)}" <>
            if(r.error, do: "; error: #{r.error}", else: "")
        )
      end

      if runs == [], do: IO.puts("no derivation runs yet")
      runs
    end)
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
  Counts the tx store against the chain for blocks `from..to` and prints each
  number, then OK or every gap (`Bitblocks.TxStore.reconcile/3`). Read-only.
  Give large spans in pieces on a busy database.

      bin/bitblocks rpc 'Bitblocks.Release.tx_store_reconcile(0, 9_999)'
      bin/bitblocks rpc 'Bitblocks.Release.tx_store_reconcile(150_000, 159_999, sample: 50)'
  """
  def tx_store_reconcile(from, to, opts \\ []) do
    r = Bitblocks.TxStore.reconcile(from, to, opts)
    n = &(&1 |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ","))

    IO.puts("""
    tx store reconcile, blocks #{n.(from)}..#{n.(to)}
      blocks            #{n.(r.blocks)} of #{n.(to - from + 1)} (#{n.(r.completed)} completed)
      block objects     #{n.(r.block_objects)} stored, #{n.(r.block_objects_missing)} missing (#{n.(r.block_objects_too_large)} over the raw-block cap)
      txs declared      #{n.(r.declared)} (sum of num_tx)
      txs stored        #{n.(r.stored)}
      txs in the store  #{n.(r.in_store)} (#{n.(r.in_block_objects)} located in block objects)
      sample            #{n.(r.sampled - length(r.sample_bad))} of #{n.(r.sampled)} match (#{n.(r.range_sampled)} by ranged read)\
    """)

    case r.gaps do
      [] -> IO.puts("  OK: every declared tx is stored and in the store")
      gaps -> for {kind, count} <- gaps, do: IO.puts("  GAP #{kind}: #{n.(count)}")
    end

    for txid <- r.sample_bad, do: IO.puts("  mismatch: #{txid}")
    r
  end

  @doc """
  Writes the tx store's block objects (`Bitblocks.TxStore.BlockObject`) for
  completed blocks `from..to` that have none: refetches each raw block from
  the node (REST, else `getblock(hash, 0)`), writes it, reads it back and
  verifies it, then locates its txs and stamps the block. The sync loop does
  this as each block completes; this finds the ones it missed (a failed
  write, the store not ready yet, blocks synced before it existed).

  **Dry run by default**: counts only, touching neither the node nor the
  store. `apply: true` writes. Bounded and resumable: at most `limit:` blocks
  (500) per call, lowest first; stamped blocks are never picked again, so run
  it again to carry on. Stops after `max_failures:` (3) failures in a row,
  e.g. a node refusing RPC, and prints why.

      bin/bitblocks rpc 'Bitblocks.Release.store_block_objects(0, 9_999)'
      bin/bitblocks rpc 'Bitblocks.Release.store_block_objects(0, 9_999, apply: true)'
  """
  def store_block_objects(from, to, opts \\ []) when is_integer(from) and is_integer(to) do
    r = Bitblocks.TxStore.BlockObject.backfill(from, to, opts)

    IO.puts(
      if(r.applied, do: "APPLIED", else: "DRY RUN (nothing fetched or written)") <>
        ": block objects for completed blocks #{from}..#{to}"
    )

    IO.puts("  #{r.missing} completed block(s) without an object in the range")

    IO.puts(
      "  this call: #{r.considered} considered, #{r.eligible} small enough to fetch whole," <>
        " #{r.too_large} over the raw-block cap (per-tx path; stay missing)"
    )

    if r.applied do
      IO.puts("  #{r.attempted} attempted, #{r.stored} stored and verified, #{r.failed} failed")
      for {height, reason} <- r.failures, do: IO.puts("  FAILED #{height}: #{inspect(reason)}")
    end

    case r.stopped do
      nil -> :ok
      reason -> IO.puts("  STOPPED: #{inspect(reason)}")
    end

    cond do
      not r.applied and r.eligible > 0 ->
        IO.puts("  Run again with apply: true to write these.")

      r.applied and r.stopped == nil and r.missing > r.considered ->
        IO.puts("  More remain: run again.")

      true ->
        :ok
    end

    r
  end

  @doc """
  Makes the GitHub user `login` an admin (`true`) or not (`false`), then reads
  the row back and prints what it holds. The person must have signed in once.
  Takes effect on their next page load.

      bin/bitblocks rpc 'Bitblocks.Release.set_admin("afomi", true)'
  """
  def set_admin(login, admin?) when is_binary(login) and is_boolean(admin?) do
    with_running_repo(fn ->
      case Bitblocks.Accounts.set_admin(login, admin?) do
        {:ok, user} ->
          stored = Bitblocks.Accounts.get_user(user.id)

          IO.puts(
            "#{stored.login} (github_id #{stored.github_id}): admin #{stored.admin}" <>
              if(stored.admin == admin?, do: "", else: " (NOT SET: expected #{admin?})")
          )

          {:ok, stored}

        {:error, :not_found} ->
          IO.puts(
            "No user has signed in as #{login}; sign in with GitHub once, then run this again."
          )

          {:error, :not_found}
      end
    end)
  end

  @doc """
  Backfill missing block HEADERS from height 0 to the chain tip.

  Delegates to sync_headers/2 (range mode) which fills header gaps only.
  Headers only: the sync loop fetches transactions for every stored header,
  in ascending order (docs/SYNCING.md).

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
  The shapes behind `custom` in blocks `from..to`, ranked (#51): template
  hash, outputs, txs, first seen, per-10,000-block counts, growth, a decoded
  sample, protocols and example txids. Reads every `custom` tx's raw bytes in
  the range and stores nothing, so keep ranges to what you need. `limit:` caps
  the list (default 50). See `Bitblocks.TxTypes.Candidates`.

      bin/bitblocks rpc 'Bitblocks.Release.type_candidates(0, 100_000) |> IO.inspect(limit: :infinity)'
  """
  def type_candidates(from, to, opts \\ []),
    do: Bitblocks.TxTypes.Candidates.scan(from, to, opts)

  @doc """
  Finds historical Bitcom commands (#24) in an address's WhatsOnChain history:
  the txs we hold no copy of are fetched, and any `$` commands logged.

  A dry run reads the first page and says what it found, writing nothing. With
  `apply: true` it queues the walk as Oban jobs, `pages:` pages at most
  (default 50, 1,000 txs a page); give no address for every directory address.
  See docs/BITCOM.md.

      bin/bitblocks rpc 'Bitblocks.Release.discover_bitcom("19Hxig...") |> IO.inspect()'
      bin/bitblocks rpc 'Bitblocks.Release.discover_bitcom("19Hxig...", apply: true)'
      bin/bitblocks rpc 'Bitblocks.Release.discover_bitcom(:all, apply: true, pages: 5)'
  """
  def discover_bitcom(address \\ :all, opts \\ []) do
    addresses =
      if address == :all,
        do: Enum.map(Bitblocks.Bitcom.directory(), & &1.address),
        else: [address]

    if Keyword.get(opts, :apply, false) == true do
      pages = Keyword.get(opts, :pages, 50)

      for address <- addresses do
        {:ok, _job} =
          Oban.insert(Bitblocks.Workers.BitcomDiscoveryWorker.job(address, nil, pages))

        address
      end
      |> then(&{:ok, :enqueued, &1})
    else
      {:ok, :dry_run, Enum.map(addresses, &Bitblocks.Bitcom.Discovery.scan_page/1)}
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
  Progress of a collection sync: items by trace_state, this collection's sync
  and trace jobs still pending, and the last finished walk with its high-water
  marks (`peak_bytes` for the walk, `trace_peak_bytes` for the largest trace
  batch since).
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

    walk = cid && Bitblocks.Repo.get_by(Bitblocks.OrdinalCollections.Walk, collection_id: cid)

    status = %{
      summary: if(cid, do: OrdinalCollections.summary(cid)),
      pending_jobs: pending,
      walk: walk && Map.take(walk, [:finished_at, :mints, :items, :peak_bytes, :trace_peak_bytes])
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
  def create_api_key(name, requests_per_minute, opts \\ []) do
    case Bitblocks.ApiKeys.create(name, requests_per_minute, opts) do
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

  @doc """
  Registers an API key from its sha256, for a key that must never appear in
  command output: generate the `bbk_` token elsewhere, store it directly in
  the secret, and pass only the hash (64 lowercase hex of the whole token).

      bin/bitblocks rpc 'Bitblocks.Release.create_api_key_from_hash("cloudfront-cdn", 3000, "<sha256 hex>")'
  """
  def create_api_key_from_hash(name, requests_per_minute, token_hash, opts \\ []) do
    with_running_repo(fn ->
      case Bitblocks.ApiKeys.create_from_hash(name, requests_per_minute, token_hash, opts) do
        {:ok, key} ->
          IO.puts("api key ##{key.id} (#{name}, #{requests_per_minute}/min) registered")
          {:ok, key.id}

        {:error, %Ecto.Changeset{} = changeset} ->
          errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
          IO.puts("NOT REGISTERED: #{inspect(errors)}")
          {:error, errors}

        {:error, reason} ->
          IO.puts("NOT REGISTERED: #{inspect(reason)}")
          {:error, reason}
      end
    end)
  end

  @doc "Lists API keys as `{id, name, prefix, requests_per_minute, revoked_at}`."
  def list_api_keys do
    for k <- Bitblocks.ApiKeys.list(),
        do: {k.id, k.name, k.prefix, k.requests_per_minute, k.scopes, k.revoked_at}
  end

  @doc """
  Grants a scope to an existing key. Keys hold none until granted.

      bin/bitblocks rpc 'Bitblocks.Release.grant_api_key_scope(3, "ops_read")'
  """
  def grant_api_key_scope(id, scope) do
    case Bitblocks.ApiKeys.grant_scope(id, scope) do
      {:ok, key} ->
        Logger.info("grant_api_key_scope: ##{key.id} #{key.name} #{scope}")
        {:ok, key.scopes}

      {:error, changeset} ->
        {:error, Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)}
    end
  end

  @doc "Revokes an API key; requests with it get a 401 within a minute."
  def revoke_api_key(id) do
    with {:ok, key} <- Bitblocks.ApiKeys.revoke(id) do
      Logger.info("revoke_api_key: ##{key.id} #{key.name}")
      {:ok, key.id}
    end
  end

  @doc """
  Indexes BAP records on stored rows (docs/BAP.md). Dry run by default; run
  script analysis over the range first.

      bin/bitblocks rpc 'Bitblocks.Release.backfill_bap(600_000, 650_000)'
      bin/bitblocks rpc 'Bitblocks.Release.backfill_bap(600_000, 650_000, apply: true)'
  """
  def backfill_bap(from_height, to_height, opts \\ [])
      when is_integer(from_height) and is_integer(to_height) do
    command = command("backfill_bap", [from_height, to_height], opts)

    with_running_repo(fn ->
      Bitblocks.Chain.TxPipeline.BapBackfill.run(
        from_height,
        to_height,
        opts
        |> Keyword.put_new(:on_batch, &print_progress/1)
        |> Keyword.put(:command, command)
      )
    end)
  end

  @doc """
  Imports txs by id and indexes their BAP records, for a record in a block the
  sync hasn't reached (docs/BAP.md). A txid is only a candidate: its bytes
  must hash to it. Returns `%{txid => records held}`.

      bin/bitblocks rpc 'Bitblocks.Release.import_bap(["<txid>"]) |> IO.inspect()'
  """
  def import_bap(txids) when is_list(txids) do
    with_running_repo(fn -> Bitblocks.Bap.import_txs(txids) end)
  end

  @doc "Lists managed projections as `{id, tenant, name, status}`."
  def list_projections do
    for p <- Bitblocks.Projections.list(), do: {p.id, p.tenant, p.name, p.status}
  end

  @doc """
  Builds every chain-scrubber tile from genesis to the tip (#48).

  Enqueued on the `:chain_tiles` queue (concurrency 1) so it never contends
  with tip sync; reads `blocks` only, about a thousand 1,024-row range reads
  on the height index. Run it once; the five-minute cron keeps tiles current
  after that with incremental builds. `inline: true` runs it in this shell
  instead of the queue.

      bin/bitblocks rpc 'Bitblocks.Release.build_chain_tiles()'
  """
  def build_chain_tiles(opts \\ []) do
    if Keyword.get(opts, :inline, false) do
      {elapsed_us, result} = :timer.tc(fn -> Bitblocks.ChainTiles.build(mode: :full) end)

      IO.puts(
        "chain tiles full build: #{inspect(result, limit: 20)} in #{div(elapsed_us, 1000)} ms"
      )

      result
    else
      case %{"mode" => "full"} |> Bitblocks.Workers.ChainTilesWorker.new() |> Oban.insert() do
        {:ok, %Oban.Job{id: id, conflict?: false} = job} ->
          IO.puts("chain tiles full build queued (Oban ##{id}); check chain_tiles_status()")
          {:ok, job}

        {:ok, %Oban.Job{conflict?: true} = job} ->
          IO.puts("a chain tiles build is already queued or running (Oban ##{job.id})")
          {:ok, job}

        {:error, reason} ->
          IO.puts("failed to queue: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Writes a Bitcom registry snapshot if the registry changed, and prints the
  version and hash (#21). The daily cron does the same.

      bin/bitblocks rpc 'Bitblocks.Release.bitcom_snapshot()'
  """
  def bitcom_snapshot do
    with_running_repo(fn ->
      case Bitblocks.Bitcom.Snapshots.take() do
        {:ok, result, snapshot} ->
          IO.puts(
            "Bitcom snapshot v#{snapshot.id} #{result}: #{snapshot.sha256}, " <>
              "#{snapshot.namespaces} namespaces"
          )

        {:error, changeset} ->
          IO.puts("Bitcom snapshot failed: #{inspect(changeset.errors)}")
      end
    end)
  end

  @doc """
  Prints tile counts per level and the last builds.

      bin/bitblocks rpc 'Bitblocks.Release.chain_tiles_status()'
  """
  def chain_tiles_status do
    counts = Bitblocks.ChainTiles.tile_counts()
    builds = Bitblocks.ChainTiles.list_builds(5)

    IO.puts(
      "chain tiles: " <>
        Enum.map_join(Enum.sort(counts), ", ", fn {l, n} -> "level #{l}: #{n}" end)
    )

    IO.puts(
      "tip: #{inspect(Bitblocks.ChainTiles.chain_tip())}; cached: #{length(Bitblocks.ChainTiles.Cache.all())}"
    )

    Enum.each(builds, fn b ->
      IO.puts(
        "  #{b.started_at} #{b.mode} #{b.status}: #{b.leaves_scanned} leaves scanned, " <>
          "#{b.tiles_written} written, #{b.tiles_unchanged} unchanged" <>
          if(b.error, do: " — #{b.error}", else: "")
      )
    end)

    %{tiles: counts, builds: builds}
  end

  @doc """
  Imports raw blocks exported from our node (`<height>-<hash>.bin` files in
  `dir`), with no node calls. Each goes through the sync loop's checks; see
  `Bitblocks.Chain.BlockImport`. Safe to repeat.

      bin/bitblocks rpc 'Bitblocks.Release.import_raw_blocks("/data/blocks/900000-900099")'
  """
  def import_raw_blocks(dir) do
    {:ok, report} = Bitblocks.Chain.BlockImport.import_dir(dir)

    IO.puts(
      "completed #{length(report.completed)}, already complete " <>
        "#{length(report.already_complete)}, failed #{length(report.failed)}"
    )

    for {height, reason} <- report.failed, do: IO.puts("  #{height}: #{inspect(reason)}")
    report
  end

  @doc """
  Reconciles the transaction rows of an orphaned block after a reorg (#34),
  and corrects the reorg row that set it aside.

  Rows still carrying `orphan_hash` are moved to the block that holds their
  transaction now, or removed (with their spend edges) when no block does.
  A row whose lookup fails is left alone; run it again later. The token,
  listing and collection rows of those transactions follow them. See
  `Bitblocks.Reorgs.Reconcile`.

  **Dry run by default**: prints what it would change and writes nothing to
  `transactions`, `spend_index`, `reorgs` or any protocol row (reading the replacement block's
  verified txid list may cache it on that block row, as a tx fetch would).
  Pass `apply: true` to make the changes.

  ## Options
    - apply: true to write (default false)
    - orphan_count: the number of blocks the reorg actually set aside, to
      correct the stored count
    - height: the orphan's height, if no row carries it and the node doesn't know the block

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.reconcile_orphaned_block("<hash>", orphan_count: 1)'
      bin/bitblocks rpc 'Bitblocks.Release.reconcile_orphaned_block("<hash>", orphan_count: 1, apply: true)'
  """
  def reconcile_orphaned_block(orphan_hash, opts \\ []) do
    with_running_repo(fn -> do_reconcile_orphaned_block(orphan_hash, opts) end)
  end

  defp do_reconcile_orphaned_block(orphan_hash, opts) do
    case Bitblocks.Reorgs.Reconcile.run(orphan_hash, opts) do
      {:ok, report} ->
        print_reconcile(report)
        {:ok, report}

      {:error, :block_still_stored} ->
        IO.puts(
          "reconcile_orphaned_block: #{orphan_hash} is still a stored block, not an orphan. Nothing done."
        )

        {:error, :block_still_stored}

      {:error, reason} ->
        IO.puts("reconcile_orphaned_block: failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Revalidates every indexed BSV-21 transfer against the token outputs its tx
  spends (#41), oldest block first, so holder balances count only transfers
  that really move the token. See `Bitblocks.Tokens.revalidate_transfers/1`
  and docs/BSV20_TOKENS.md.

  Transfers indexed before validation existed have no status and count for
  no one until this runs. **Dry run by default**: prints how many would be
  valid, invalid and pending and how many change, and writes nothing.
  Pass `apply: true` to write.

  ## Usage

      bin/bitblocks rpc 'Bitblocks.Release.revalidate_token_transfers()'
      bin/bitblocks rpc 'Bitblocks.Release.revalidate_token_transfers(apply: true)'
  """
  def revalidate_token_transfers(opts \\ []) do
    with_running_repo(fn ->
      report = Bitblocks.Tokens.revalidate_transfers(opts)

      IO.puts(
        if(report.applied, do: "APPLIED", else: "DRY RUN (nothing written)") <>
          ": #{report.rows} transfer output(s) in #{report.txs} tx(s)"
      )

      IO.puts(
        "  valid #{report.valid}, invalid #{report.invalid}, pending #{report.pending}; " <>
          "#{report.changed} change(d)"
      )

      IO.puts("  by status and reason:")

      for {reason, n} <- Enum.sort_by(report.by_reason, &elem(&1, 1), :desc),
          do: IO.puts("    #{n}  #{reason}")

      # Each invalid row with what it spends, so a verdict that rests on an
      # input stored before BSV20 tagging (old analysis version, no tag) shows.
      analysis_now = Bitblocks.TransactionParser.protocol_tags_version()

      for r <- report.invalid_rows do
        IO.puts("  INVALID #{r.txid}:#{r.vout} at #{inspect(r.block_height)}: #{r.reason}")

        for i <- Bitblocks.Tokens.input_report(r.txid) do
          note =
            cond do
              not i.stored ->
                "not stored"

              i.token ->
                "token #{i.token.op} #{i.token.token_id}"

              (i.script_analysis_version || 0) < analysis_now ->
                "STALE ANALYSIS, may hide a token"

              i.bsv20_tagged ->
                "tagged BSV20, no token row"

              true ->
                "not a token"
            end

          IO.puts(
            "      in #{i.outpoint} height #{inspect(i.block_height)} " <>
              "analysis v#{inspect(i.script_analysis_version)}: #{note}"
          )
        end
      end

      unless report.applied, do: IO.puts("  Run again with apply: true to write these.")
      report
    end)
  end

  defp print_reconcile(%{applied: applied, plan: plan} = report) do
    IO.puts(
      if(applied, do: "APPLIED", else: "DRY RUN (nothing written)") <>
        ": orphan #{plan.orphan_hash} at height #{inspect(plan.height)}"
    )

    IO.puts("  #{plan.rows} transaction row(s) point at the orphan")

    for {hash, height, txids} <- plan.repoint do
      IO.puts("  move #{length(txids)} to #{hash} (height #{height})")
    end

    IO.puts("  remove #{length(plan.remove)} (no block holds them)")
    Enum.each(Enum.take(plan.remove, 20), &IO.puts("    #{&1}"))
    if length(plan.remove) > 20, do: IO.puts("    ... #{length(plan.remove) - 20} more")
    IO.puts("  remove #{plan.spends_to_remove} spend edge(s) recorded by those")

    IO.puts(
      "  leave #{length(plan.pending)} whose block isn't stored yet, " <>
        "#{length(plan.unknown)} whose lookup failed"
    )

    IO.puts("  protocol rows of those moved and removed:")
    print_protocol_rewind(plan.protocols)

    case report.reorg do
      nil when is_nil(plan.height) ->
        IO.puts(
          "  the orphan's height is unknown (no row carries it, the node doesn't know it), " <>
            "so no reorg row is corrected: pass height: to correct it"
        )

      nil ->
        IO.puts("  no resolved reorg row covers this height")

      reorg ->
        IO.puts("  reorg row #{reorg.id} (fork height #{reorg.fork_height}):")

        if report.reorg_changes == %{} do
          IO.puts("    unchanged")
        end

        for {field, {old, new}} <- report.reorg_changes, field != :summary do
          IO.puts("    #{field} #{inspect(old)} -> #{inspect(new)}")
        end

        case report.reorg_changes do
          %{summary: {_old, new}} -> IO.puts("    summary -> #{new}")
          _ -> :ok
        end
    end

    if applied do
      r = report.result

      IO.puts(
        "  moved #{r.repointed}, removed #{r.removed}, removed #{r.spends_removed} spend edge(s); " <>
          "#{r.remaining} row(s) still point at the orphan"
      )

      IO.puts("  protocol rows, done:")
      print_protocol_rewind(r.protocols)
    else
      IO.puts("  Run again with apply: true to make these changes.")
    end
  end

  defp print_protocol_rewind(%{tokens: t, listings: l, collection_items: c}) do
    IO.puts(
      "    tokens: #{t.moved} moved, #{t.removed} removed, #{t.rechecked} spender(s) checked"
    )

    IO.puts("    listings: #{l.moved} moved, #{l.removed} removed, #{l.reopened} reopened")

    IO.puts(
      "    collection items: #{c.moved} mint(s) moved, #{c.removed} removed, " <>
        "#{c.retrace} marked for a re-trace"
    )
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

  # Postgres's row estimate for a table (pg_class.reltuples, refreshed by
  # ANALYZE). -1 means never analyzed; report 0 then.
  defp estimated_row_count(table) do
    %{rows: [[n]]} =
      Bitblocks.Repo.query!("SELECT reltuples::bigint FROM pg_class WHERE relname = $1", [table])

    max(n, 0)
  end
end
