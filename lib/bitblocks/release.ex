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

  # Blockchain Sync Functions
  # These should be called via `rpc` to run in the running app context

  @doc """
  Syncs a range of blocks from the Bitcoin node.

  ## Usage

  Via fly.io:
      fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.sync_blocks(100001, 200000)'"

  Via remote console:
      fly ssh console -a bitblocks
      app/bin/bitblocks remote
      Bitblocks.Release.sync_blocks(100001, 200000)
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

  Via fly.io:
      fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.sync_block_transactions(100001)'"
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

  Via fly.io:
      fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.blockchain_info()'"
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

  Via fly.io:
      fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.pipeline_sync(250000, 260000)'"
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

  Via fly.io:
      fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.pipeline_status()'"
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

  Via fly.io:
      fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.pipeline_stop()'"
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

  Via fly.io:
      fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.db_stats()'"
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
  Backfill missing blocks and transactions from height 0 to the chain tip.

  Works in two passes:
  1. Syncs any missing block headers (fills gaps)
  2. Queues transaction fetches for blocks that don't have them yet

  Processes in chunks to avoid overwhelming the node or Oban queue.
  Idempotent — safe to run repeatedly. Progress is visible via db_stats().

  ## Options
    - chunk_size: blocks per batch (default 1000)
    - tx_batch: how many tx fetch jobs to enqueue at once (default 100)
    - skip_blocks: skip block header sync, only backfill transactions
    - skip_txs: skip transaction backfill, only fill block gaps

  ## Usage

      Bitblocks.Release.backfill()
      Bitblocks.Release.backfill(chunk_size: 500, tx_batch: 50)
      Bitblocks.Release.backfill(skip_blocks: true)
  """
  def backfill(opts \\ []) do
    alias Bitblocks.Chain

    chunk_size = Keyword.get(opts, :chunk_size, 1000)
    tx_batch = Keyword.get(opts, :tx_batch, 100)
    skip_blocks = Keyword.get(opts, :skip_blocks, false)
    skip_txs = Keyword.get(opts, :skip_txs, false)

    latest = Chain.get_latest_block()
    tip = if latest, do: latest.height, else: 0

    Logger.info("Backfill: chain tip at height #{tip}")

    # Pass 1: fill missing block headers
    unless skip_blocks do
      backfill_blocks(0, tip, chunk_size)
    end

    # Pass 2: queue transaction fetches for blocks missing txs
    unless skip_txs do
      backfill_transactions(0, tip, tx_batch)
    end

    Logger.info("Backfill: complete")
    :ok
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

  # Queue transaction fetch jobs in batches
  defp backfill_transactions(from, tip, batch_size) do
    alias Bitblocks.{Repo, Chain.Block}
    import Ecto.Query

    # Count blocks that need transactions
    # (header_only or header_synced — not yet completed)
    needs_txs_count =
      from(b in Block,
        where: b.height >= ^from and b.height <= ^tip,
        where: b.sync_state in ["header_only", "header_synced"],
        select: count()
      )
      |> Repo.one()

    Logger.info("Backfill txs: #{needs_txs_count} blocks need transactions")

    if needs_txs_count == 0 do
      :ok
    else
      # Process in batches, oldest first
      backfill_tx_batch(from, tip, batch_size, 0, needs_txs_count)
    end
  end

  defp backfill_tx_batch(from, tip, batch_size, queued_so_far, total) do
    alias Bitblocks.{Repo, Chain, Chain.Block}
    import Ecto.Query

    blocks =
      from(b in Block,
        where: b.height >= ^from and b.height <= ^tip,
        where: b.sync_state in ["header_only", "header_synced"],
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

      # Wait for the batch to drain before queuing more
      # so we don't flood Oban with 900k jobs at once
      wait_for_oban_drain(60_000)

      backfill_tx_batch(last_height + 1, tip, batch_size, new_total, total)
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
      # Check how many transaction jobs are still executing or available
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
        pending == 0 -> :drained
        elapsed > timeout -> :timeout
        true -> Process.sleep(1_000); :waiting
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
