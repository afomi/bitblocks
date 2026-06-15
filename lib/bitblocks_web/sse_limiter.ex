defmodule BitblocksWeb.SseLimiter do
  @moduledoc """
  Bounds the number of concurrent Server-Sent Events connections.

  ## Why this exists

  SSE handlers (`BitblocksWeb.Api.StreamController`) hold a process open
  indefinitely, blocking on `receive` with only a heartbeat. The per-request
  rate limiter does not protect them: it counts *requests*, not *long-lived
  connections*, so a single client can open thousands of streams and exhaust
  acceptors, sockets, and memory (THREAT-MODEL.md threat T2, asset A1 —
  availability). This module caps concurrent streams both globally and per IP.

  ## Model

  An ETS counter table tracks this node's live connections. `acquire/1`
  reserves a slot if capacity remains; `release/1` frees it. Counts live in ETS
  (not process state) so they survive across the controller's `receive` loop
  and are shared by all acceptor processes. A slot leaked by an abnormal exit is
  reclaimed by `release/1` in the controller's `after` block.

  ## Cluster awareness (T1/T12)

  The cap is enforced **cluster-wide**: `acquire/1` checks this node's local
  count *plus* the summed peer counts gossiped by `SseLimiter.ClusterState`
  against the limit, so a client spreading streams across instances can't get
  N× the cap. Peer counts are eventually consistent; the local atomic bump still
  prevents one node from blowing past the cap on its own. If `ClusterState`
  isn't running (single-node, tests) peer counts are zero and enforcement is
  local — identical to the original behavior.

  ## Configuration

      config :bitblocks, BitblocksWeb.SseLimiter,
        max_global: 500,   # total concurrent SSE connections (cluster-wide)
        max_per_ip: 5      # concurrent SSE connections from one IP (cluster-wide)
  """

  require Logger

  alias BitblocksWeb.SseLimiter.ClusterState

  @table :sse_limiter
  @global_key :__global__
  @default_max_global 500
  @default_max_per_ip 5

  @doc """
  Try to reserve an SSE slot for `ip`. Returns `:ok` if capacity remains
  cluster-wide, or `{:error, :too_many_connections}` if the global or per-IP cap
  is hit.
  """
  @spec acquire(String.t()) :: :ok | {:error, :too_many_connections}
  def acquire(ip) when is_binary(ip) do
    ensure_table()
    max_global = config(:max_global, @default_max_global)
    max_per_ip = config(:max_per_ip, @default_max_per_ip)

    {peer_global, peer_ips} = ClusterState.peer_counts()
    peer_for_ip = Map.get(peer_ips, ip, 0)

    # Reserve the global slot first; roll it back if the per-IP cap is hit.
    # The cap counts local + peer contributions.
    if bump(@global_key, max_global - peer_global) do
      if bump({:ip, ip}, max_per_ip - peer_for_ip) do
        ClusterState.publish()
        :ok
      else
        :ets.update_counter(@table, @global_key, {2, -1, 0, 0})
        {:error, :too_many_connections}
      end
    else
      {:error, :too_many_connections}
    end
  end

  @doc """
  Release the slot held for `ip`. Safe to call once per successful `acquire/1`.
  Counters are floored at zero so a double-release cannot drive them negative.
  """
  @spec release(String.t()) :: :ok
  def release(ip) when is_binary(ip) do
    ensure_table()
    dec({:ip, ip})
    dec(@global_key)
    ClusterState.publish()
    :ok
  end

  @doc """
  This node's local counts as `{global, %{ip => count}}` — consumed by
  `ClusterState` to gossip its tally to peers.
  """
  @spec local_counts() :: {non_neg_integer(), %{optional(String.t()) => non_neg_integer()}}
  def local_counts do
    ensure_table()

    :ets.foldl(
      fn
        {@global_key, _n}, acc -> acc
        {{:ip, ip}, n}, {g, ips} when n > 0 -> {g, Map.put(ips, ip, n)}
        _other, acc -> acc
      end,
      {current(@global_key), %{}},
      @table
    )
  end

  @doc "Current global concurrent SSE connection count (for tests/telemetry)."
  @spec global_count() :: non_neg_integer()
  def global_count do
    ensure_table()
    current(@global_key)
  end

  @doc "Current concurrent SSE connection count for `ip`."
  @spec ip_count(String.t()) :: non_neg_integer()
  def ip_count(ip) when is_binary(ip) do
    ensure_table()
    current({:ip, ip})
  end

  # Atomically claim a slot under `max`. We increment unconditionally (one
  # atomic op, no check-then-act race) and roll back if we overshot. The
  # rollback can momentarily push the count one over for a concurrent reader,
  # which is harmless — the ceiling is still enforced for every accepted slot.
  defp bump(key, max) do
    :ets.insert_new(@table, {key, 0})

    if :ets.update_counter(@table, key, {2, 1}) <= max do
      true
    else
      :ets.update_counter(@table, key, {2, -1, 0, 0})
      false
    end
  end

  defp dec(key) do
    :ets.insert_new(@table, {key, 0})
    :ets.update_counter(@table, key, {2, -1, 0, 0})
  end

  defp current(key) do
    case :ets.lookup(@table, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        # Two callers can race between whereis/new; the loser's :ets.new raises
        # "table already exists". Treat that as success — the table is there.
        try do
          :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp config(key, default) do
    Application.get_env(:bitblocks, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
