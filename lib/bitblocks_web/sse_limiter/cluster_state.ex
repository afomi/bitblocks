defmodule BitblocksWeb.SseLimiter.ClusterState do
  @moduledoc """
  Cluster-wide view of concurrent SSE connection counts (THREAT-MODEL.md T2).

  ## Why this exists

  `BitblocksWeb.SseLimiter` counts live SSE connections in node-local ETS.
  Behind a load balancer the per-IP and global caps are then enforced per
  instance, so a client spreading connections across N nodes gets N× the cap.
  This process makes the cap cluster-wide *without new infrastructure*.

  ## Model — gossip of per-node tallies, not deltas

  A connection count is long-lived state, so broadcasting increment/decrement
  *deltas* is fragile: if a node crashes with open connections, its decrements
  never fire and the global count leaks upward forever, eventually wedging the
  cap. Instead each node periodically (and on change) **publishes its own
  current tally**; every node keeps a map `node => tally` and derives the
  cluster total by summing. When a node goes down, `:nodedown` (and a staleness
  TTL as backstop) drops its contribution, so a crashed node's connections
  self-heal out of the total. This is eventually consistent and self-correcting.

  `peer_counts/0` returns the summed peer contribution (excluding this node);
  the SseLimiter adds its own local count to get the cluster total.

  Decoupled from the request path: if this process isn't running (single-node,
  tests), peer counts are simply zero and the limiter enforces locally.
  """

  use GenServer
  require Logger

  alias Phoenix.PubSub

  @pubsub Bitblocks.PubSub
  @topic "sse_limiter:gossip"

  # How often each node republishes its tally (also bounds staleness).
  @gossip_interval_ms 5_000
  # Drop a peer's tally if we haven't heard from it in this long (crash backstop
  # in case :nodedown is missed). Must be a few gossip intervals.
  @peer_ttl_ms 20_000

  # -- public API --------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Summed peer contribution to the cluster counts, excluding this node:
  `{global, %{ip => count}}`. Returns `{0, %{}}` if the process isn't running.
  """
  @spec peer_counts() :: {non_neg_integer(), %{optional(String.t()) => non_neg_integer()}}
  def peer_counts do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :peer_counts)
    else
      {0, %{}}
    end
  catch
    # If the GenServer is mid-restart or overloaded, fail open to local-only
    # enforcement rather than blocking or crashing the request.
    :exit, _ -> {0, %{}}
  end

  @doc "Publish this node's current tally to peers now (called on change)."
  @spec publish() :: :ok
  def publish do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :publish)
    :ok
  end

  # -- GenServer ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    PubSub.subscribe(@pubsub, @topic)
    :net_kernel.monitor_nodes(true)
    schedule_gossip()
    # peers: node => %{global: n, ips: %{ip => n}, at: monotonic_ms}
    {:ok, %{peers: %{}}}
  end

  @impl true
  def handle_call(:peer_counts, _from, state) do
    fresh = prune_stale(state.peers)
    {:reply, sum_peers(fresh), %{state | peers: fresh}}
  end

  @impl true
  def handle_cast(:publish, state) do
    broadcast_local_tally()
    {:noreply, state}
  end

  @impl true
  def handle_info(:gossip, state) do
    broadcast_local_tally()
    schedule_gossip()
    {:noreply, %{state | peers: prune_stale(state.peers)}}
  end

  # A peer published its tally.
  def handle_info({:sse_tally, node, global, ips}, state)
      when is_atom(node) and is_integer(global) and is_map(ips) do
    if node == Node.self() do
      {:noreply, state}
    else
      peer = %{global: global, ips: ips, at: now_ms()}
      {:noreply, %{state | peers: Map.put(state.peers, node, peer)}}
    end
  end

  def handle_info({:nodedown, node}, state) do
    {:noreply, %{state | peers: Map.delete(state.peers, node)}}
  end

  def handle_info({:nodeup, _node}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # -- internal ----------------------------------------------------------------

  defp broadcast_local_tally do
    {global, ips} = BitblocksWeb.SseLimiter.local_counts()
    PubSub.broadcast(@pubsub, @topic, {:sse_tally, Node.self(), global, ips})
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp sum_peers(peers) do
    Enum.reduce(peers, {0, %{}}, fn {_node, %{global: g, ips: ips}}, {acc_g, acc_ips} ->
      merged_ips =
        Enum.reduce(ips, acc_ips, fn {ip, n}, acc ->
          Map.update(acc, ip, n, &(&1 + n))
        end)

      {acc_g + g, merged_ips}
    end)
  end

  defp prune_stale(peers) do
    cutoff = now_ms() - @peer_ttl_ms
    :maps.filter(fn _node, %{at: at} -> at > cutoff end, peers)
  end

  defp schedule_gossip, do: Process.send_after(self(), :gossip, @gossip_interval_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
