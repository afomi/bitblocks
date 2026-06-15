defmodule Bitblocks.StatsCache do
  @moduledoc """
  Caches database statistics (counts) to avoid expensive COUNT(*) queries on every page load.

  Refreshes stats periodically (default: every 60 seconds).
  """
  use GenServer
  require Logger

  alias Bitblocks.Repo
  alias Bitblocks.Chain.Block

  @refresh_interval :timer.seconds(60)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the cached block count.
  Returns 0 if the cache is unavailable rather than falling through to a full-table scan.
  """
  def blocks_count do
    case :ets.lookup(__MODULE__, :blocks_count) do
      [{:blocks_count, count}] -> count
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc """
  Returns the cached transaction count.
  Returns 0 if the cache is unavailable rather than falling through to a full-table scan.
  """
  def transactions_count do
    case :ets.lookup(__MODULE__, :transactions_count) do
      [{:transactions_count, count}] -> count
      [] -> 0
    end
  rescue
    ArgumentError -> 0
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

    # Subscribe to block updates so counts refresh when blocks complete
    Phoenix.PubSub.subscribe(Bitblocks.PubSub, "blocks")

    # Async refresh will fill in real values
    schedule_refresh(0)

    {:ok, %{refresh_pending: false}}
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
    {:noreply, %{state | refresh_pending: false}}
  end

  @impl true
  def handle_info({:block_updated, _block}, %{refresh_pending: true} = state) do
    {:noreply, state}
  end

  def handle_info({:block_updated, _block}, state) do
    # Debounce: wait 2 seconds so a burst of block updates triggers one refresh
    schedule_refresh(2_000)
    {:noreply, %{state | refresh_pending: true}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp schedule_refresh(delay) do
    Process.send_after(self(), :refresh, delay)
  end

  defp do_refresh do
    Logger.debug("StatsCache: refreshing counts")

    blocks_count = fetch_blocks_count()
    transactions_count = fetch_transactions_count()

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
    # Use pg_class reltuples for a fast approximate count on the 29GB transactions table.
    # An exact COUNT(*) requires a full sequential scan (~1.7s) that causes pool exhaustion.
    result =
      Repo.query!(
        "SELECT reltuples::bigint FROM pg_class WHERE relname = 'transactions'",
        []
      )

    case result.rows do
      [[count]] when is_integer(count) and count >= 0 -> count
      _ -> 0
    end
  rescue
    _ -> 0
  end
end
