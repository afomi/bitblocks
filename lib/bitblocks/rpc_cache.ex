defmodule Bitblocks.RpcCache do
  @moduledoc """
  Caches expensive RPC calls to the Bitcoin node.

  Particularly useful for getblockchaininfo which is called frequently
  but doesn't change often (only when new blocks arrive).
  """
  use GenServer
  require Logger

  @table_name :rpc_cache
  # 10 minutes in milliseconds
  @default_ttl 600_000

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Get cached blockchain info or fetch if not cached/expired.

  Returns the cached result if valid, otherwise fetches fresh data.
  """
  def get_blockchain_info do
    case get(:blockchain_info) do
      {:ok, cached_value} ->
        cached_value

      :miss ->
        fetch_and_cache_blockchain_info()
    end
  end

  @doc """
  Invalidate the blockchain info cache.
  Call this when a new block is received.
  """
  def invalidate_blockchain_info do
    GenServer.cast(__MODULE__, {:invalidate, :blockchain_info})
  end

  @doc """
  Get all getblockchaininfo call events for admin querying.
  """
  def get_blockchain_info_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    GenServer.call(__MODULE__, {:get_events, :blockchain_info, limit})
  end

  # Private Client Functions

  defp get(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          # Expired
          :miss
        end

      [] ->
        :miss
    end
  end

  defp bitcoin_cli do
    Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)
  end

  defp fetch_and_cache_blockchain_info do
    started_at = System.system_time(:millisecond)

    result = bitcoin_cli().getblockchaininfo()

    duration = System.system_time(:millisecond) - started_at

    # Log the event
    GenServer.cast(__MODULE__, {:log_event, :blockchain_info, result, duration})

    # Cache the result
    if is_map(result) and not match?({:error, _}, result) do
      ttl = @default_ttl
      expires_at = System.monotonic_time(:millisecond) + ttl

      :ets.insert(@table_name, {:blockchain_info, result, expires_at})

      Logger.debug("Cached blockchain info (TTL: #{ttl}ms)")
    end

    result
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for cache
    :ets.new(@table_name, [:set, :public, :named_table])

    # Create ETS table for event log
    :ets.new(:rpc_events, [:ordered_set, :public, :named_table])

    {:ok, %{event_counter: 0}}
  end

  @impl true
  def handle_cast({:invalidate, key}, state) do
    :ets.delete(@table_name, key)
    Logger.info("Invalidated cache for: #{key}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:log_event, :blockchain_info, result, duration}, state) do
    # Store event with timestamp for admin querying
    event_id = state.event_counter + 1
    timestamp = System.system_time(:millisecond)

    # Extract data safely - only access map fields if result is a successful map
    {success, blocks, headers, chain, bestblockhash} =
      if is_map(result) and not match?({:error, _}, result) do
        {true, get_in(result, ["blocks"]), get_in(result, ["headers"]), get_in(result, ["chain"]),
         get_in(result, ["bestblockhash"])}
      else
        {false, nil, nil, nil, nil}
      end

    event = %{
      id: event_id,
      timestamp: timestamp,
      datetime: DateTime.utc_now() |> DateTime.to_iso8601(),
      duration_ms: duration,
      success: success,
      blocks: blocks,
      headers: headers,
      chain: chain,
      bestblockhash: bestblockhash
    }

    :ets.insert(:rpc_events, {event_id, event})

    # Keep only last 1000 events to prevent unbounded growth
    if event_id > 1000 do
      :ets.delete(:rpc_events, event_id - 1000)
    end

    {:noreply, %{state | event_counter: event_id}}
  end

  @impl true
  def handle_call({:get_events, :blockchain_info, limit}, _from, state) do
    # Get last N events
    events =
      :ets.tab2list(:rpc_events)
      |> Enum.sort_by(fn {id, _event} -> id end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {_id, event} -> event end)

    {:reply, events, state}
  end
end
