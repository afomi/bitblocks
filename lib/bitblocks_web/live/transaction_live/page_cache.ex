defmodule BitblocksWeb.TransactionLive.PageCache do
  @moduledoc """
  The computed facts of recently viewed transaction pages, in ETS, so a
  repeat view asks nothing of the database.

  A transaction buried at least `:min_depth` blocks (100) under our tip
  will not change block, bytes or parse, so `TransactionLive.Show` keeps
  what it computed for it here: the assigns, not the HTML. The HTML
  carries the viewer's CSRF token and LiveView session, so it is rendered
  per request; with the assigns in hand, a render and the LiveView's
  connect read nothing from the pool.

  What can still change on such a tx is read at the time the entry was
  made and kept for `:ttl_ms` (10 minutes): whether each output is spent,
  a collection item's owner, the HodLocker totals, our tip. A page served
  from here can be that much behind.

  Bounded by bytes, not entries: `:max_bytes` in all (64 MB), and an
  entry over `:max_entry_bytes` (1 MB, by `:erlang.external_size/1`) is
  not kept. Over the budget, the least recently read entries go first,
  down to 90% of it. Writes go through this process; reads are ETS
  lookups from the caller.

  `enabled: false` turns it off.
  """

  use GenServer

  @table __MODULE__
  @default_max_bytes 64 * 1024 * 1024
  @default_max_entry_bytes 1024 * 1024
  @default_ttl_ms 10 * 60_000
  @default_min_depth 100
  @sweep_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The kept assigns for `key`, or `:miss` (absent, expired or off)."
  @spec get(String.t()) :: {:ok, map()} | :miss
  def get(key) when is_binary(key) do
    now = now()

    with true <- enabled?(),
         [{^key, value, _size, expires_at, _read_at}] when expires_at > now <-
           :ets.lookup(@table, key) do
      :ets.update_element(@table, key, {5, now})
      {:ok, value}
    else
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Keeps `value` for `key`. Returns `:ok` when kept and `:skipped` when the
  cache is off or the entry is over `:max_entry_bytes`.
  """
  @spec put(String.t(), map()) :: :ok | :skipped
  def put(key, value) when is_binary(key) do
    size = :erlang.external_size(value)

    if enabled?() and size <= config(:max_entry_bytes, @default_max_entry_bytes) do
      GenServer.cast(__MODULE__, {:put, key, value, size})
    else
      :skipped
    end
  end

  @doc "Whether a tx mined at `height` is buried deep enough under `tip` to keep."
  @spec deep_enough?(integer() | nil, integer() | nil) :: boolean()
  def deep_enough?(height, tip) when is_integer(height) and is_integer(tip),
    do: tip - height >= config(:min_depth, @default_min_depth)

  def deep_enough?(_height, _tip), do: false

  @cacheable {__MODULE__, :cacheable}

  @doc """
  Notes, in the calling process, that the page it is rendering came from
  or went into this cache. On the static render that process is the HTTP
  request's, so `BitblocksWeb.Plugs.TxPageCacheControl` reads it as the
  response is sent.
  """
  @spec mark_cacheable() :: :ok
  def mark_cacheable do
    Process.put(@cacheable, true)
    :ok
  end

  @doc "Forgets `mark_cacheable/0` in this process."
  @spec clear_cacheable() :: :ok
  def clear_cacheable do
    Process.delete(@cacheable)
    :ok
  end

  @doc "Whether `mark_cacheable/0` ran in this process."
  @spec cacheable?() :: boolean()
  def cacheable?, do: Process.get(@cacheable, false) == true

  @doc "How long an entry stands, in seconds."
  @spec ttl_s() :: non_neg_integer()
  def ttl_s, do: div(config(:ttl_ms, @default_ttl_ms), 1_000)

  @doc "Entries and bytes held. Synchronous, so a `put/2` before it has landed."
  @spec stats() :: %{entries: non_neg_integer(), bytes: non_neg_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc "Drops every entry. Synchronous."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  # -- Server ------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{bytes: 0}}
  end

  @impl true
  def handle_cast({:put, key, value, size}, state) do
    now = now()
    state = forget(state, key)
    :ets.insert(@table, {key, value, size, now + config(:ttl_ms, @default_ttl_ms), now})
    {:noreply, evict(%{state | bytes: state.bytes + size})}
  end

  @impl true
  def handle_call(:stats, _from, state),
    do: {:reply, %{entries: :ets.info(@table, :size), bytes: state.bytes}, state}

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | bytes: 0}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now()

    expired =
      :ets.select(@table, [
        {{:"$1", :_, :"$2", :"$3", :_}, [{:"=<", :"$3", now}], [{{:"$1", :"$2"}}]}
      ])

    for {key, _size} <- expired, do: :ets.delete(@table, key)
    freed = expired |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, %{state | bytes: max(state.bytes - freed, 0)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp forget(state, key) do
    case :ets.lookup(@table, key) do
      [{^key, _value, size, _expires_at, _read_at}] ->
        :ets.delete(@table, key)
        %{state | bytes: state.bytes - size}

      [] ->
        state
    end
  end

  # Least recently read first, down to 90% of the budget.
  defp evict(state) do
    max_bytes = config(:max_bytes, @default_max_bytes)

    if state.bytes <= max_bytes do
      state
    else
      target = div(max_bytes * 9, 10)

      :ets.select(@table, [{{:"$1", :_, :"$2", :_, :"$3"}, [], [{{:"$3", :"$1", :"$2"}}]}])
      |> Enum.sort()
      |> Enum.reduce_while(state, fn {_read_at, key, size}, acc ->
        if acc.bytes <= target do
          {:halt, acc}
        else
          :ets.delete(@table, key)
          {:cont, %{acc | bytes: acc.bytes - size}}
        end
      end)
    end
  end

  defp enabled?, do: config(:enabled, true)

  defp now, do: System.monotonic_time(:millisecond)

  defp config(key, default) do
    :bitblocks |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
