defmodule Bitblocks.Repo.PoolMonitor do
  @moduledoc """
  How many checkouts are waiting for a `Bitblocks.Repo` connection, sampled.

  Web requests and background jobs share one pool. When a crawl fills it,
  each page's small queries wait seconds in the checkout queue, and a page
  with a dozen of them took a minute to fail. `BitblocksWeb.Plugs.PoolGuard`
  reads this gauge before routing a page request and answers 503 at once
  while the queue is long, so the queue drains for the requests and jobs
  already in it.

  The sample is `DBConnection.get_connection_metrics/2`'s
  `checkout_queue_length`, taken every `:interval_ms` (250 ms) by this
  process. A request reads it from an `:atomics` counter, with no call to
  this process or to the pool.

  `interval_ms: nil` (the test config) takes no samples. `record/1` sets
  the gauge by hand.
  """

  use GenServer

  require Logger

  @key {__MODULE__, :gauge}
  @default_interval_ms 250

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Checkouts waiting at the last sample. 0 before the first one."
  @spec queue_length() :: non_neg_integer()
  def queue_length do
    case :persistent_term.get(@key, nil) do
      nil -> 0
      ref -> :atomics.get(ref, 1)
    end
  end

  @doc "Sets the gauge. The sampler calls this; tests may too."
  @spec record(non_neg_integer()) :: :ok
  def record(n) when is_integer(n) and n >= 0, do: :atomics.put(gauge(), 1, n)

  @impl true
  def init(opts) do
    _ = gauge()
    interval = Keyword.get(opts, :interval_ms, config(:interval_ms, @default_interval_ms))
    state = %{interval: interval}
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:sample, state) do
    case sample() do
      {:ok, n} -> record(n)
      :error -> :ok
    end

    schedule(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(%{interval: ms}) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :sample, ms)

  defp schedule(_state), do: :ok

  # The pool process answers from its own ETS queue: a count, no query.
  defp sample do
    %{pid: pool} = Ecto.Repo.Registry.lookup(Bitblocks.Repo)
    pool_mod = Keyword.get(Bitblocks.Repo.config(), :pool, DBConnection.ConnectionPool)

    waiting =
      pool
      |> DBConnection.get_connection_metrics(pool: pool_mod)
      |> Enum.map(&Map.get(&1, :checkout_queue_length, 0))
      |> Enum.sum()

    {:ok, waiting}
  rescue
    error ->
      Logger.debug("PoolMonitor sample failed: #{Exception.message(error)}")
      :error
  catch
    :exit, _ -> :error
  end

  # One counter for the life of the VM; created once, never replaced, so
  # :persistent_term is written once.
  defp gauge do
    case :persistent_term.get(@key, nil) do
      nil ->
        ref = :atomics.new(1, signed: false)
        :persistent_term.put(@key, ref)
        ref

      ref ->
        ref
    end
  end

  defp config(key, default) do
    :bitblocks |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
