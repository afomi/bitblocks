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
  def sync_blocks(start_height, end_height) when is_integer(start_height) and is_integer(end_height) do
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
      latest_block: case Chain.get_latest_block() do
        nil -> nil
        block -> %{height: block.height, hash: block.hash}
      end,
      db_size: get_db_size()
    }

    IO.inspect(stats, label: "Database Stats")
    stats
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
