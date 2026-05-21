defmodule Bitblocks.StatsCache do
  @moduledoc """
  Caches database statistics (counts) to avoid expensive COUNT(*) queries on every page load.

  Refreshes stats periodically (default: every 60 seconds).
  """
  use GenServer
  require Logger

  alias Bitblocks.Repo
  alias Bitblocks.Chain.{Block, Transaction}

  @refresh_interval :timer.seconds(60)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the cached block count.
  Falls back to database query if cache is not available.
  """
  def blocks_count do
    case :ets.lookup(__MODULE__, :blocks_count) do
      [{:blocks_count, count}] -> count
      [] -> fetch_blocks_count()
    end
  rescue
    ArgumentError -> fetch_blocks_count()
  end

  @doc """
  Returns the cached transaction count.
  Falls back to database query if cache is not available.
  """
  def transactions_count do
    case :ets.lookup(__MODULE__, :transactions_count) do
      [{:transactions_count, count}] -> count
      [] -> fetch_transactions_count()
    end
  rescue
    ArgumentError -> fetch_transactions_count()
  end

  @doc """
  Forces an immediate refresh of all cached stats.
  """
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for fast reads
    :ets.new(__MODULE__, [:set, :public, :named_table, read_concurrency: true])

    # Seed with zeros so the first read never falls through to a raw COUNT
    :ets.insert(__MODULE__, {:blocks_count, 0})
    :ets.insert(__MODULE__, {:transactions_count, 0})

    # Async refresh will fill in real values
    schedule_refresh(0)

    {:ok, %{}}
  end

  @impl true
  def handle_cast(:refresh, state) do
    do_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    do_refresh()
    schedule_refresh(@refresh_interval)
    {:noreply, state}
  end

  # Private functions

  defp schedule_refresh(delay) do
    Process.send_after(self(), :refresh, delay)
  end

  defp do_refresh do
    Logger.debug("StatsCache: refreshing counts")

    # Run counts in parallel using Task
    blocks_task = Task.async(fn -> fetch_blocks_count() end)
    transactions_task = Task.async(fn -> fetch_transactions_count() end)

    blocks_count = Task.await(blocks_task, 120_000)
    transactions_count = Task.await(transactions_task, 120_000)

    :ets.insert(__MODULE__, {:blocks_count, blocks_count})
    :ets.insert(__MODULE__, {:transactions_count, transactions_count})

    Logger.info(
      "StatsCache: updated - blocks=#{blocks_count}, transactions=#{transactions_count}"
    )
  rescue
    error ->
      Logger.error("StatsCache: refresh failed - #{inspect(error)}")
  end

  defp fetch_blocks_count do
    Repo.aggregate(Block, :count, :id)
  rescue
    _ -> 0
  end

  defp fetch_transactions_count do
    Repo.aggregate(Transaction, :count, :id)
  rescue
    _ -> 0
  end
end
