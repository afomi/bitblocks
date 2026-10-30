defmodule BitblocksWeb.Plugs.RateLimiter.Replicator do
  @moduledoc """
  Cluster replication for the per-IP rate limiter (THREAT-MODEL.md T1/T12).

  ## Why this exists

  `BitblocksWeb.Plugs.RateLimiter` counts requests per IP in node-local ETS.
  Behind a load balancer that fans requests across N instances, each node only
  sees ~1/N of an attacker's traffic, so the effective cap is N× the configured
  one. This GenServer closes that gap *without new infrastructure*: it rides the
  distributed `Phoenix.PubSub` the app already runs.

  ## Model

  On each admitted request the plug calls `record/3`, which broadcasts the
  bucket (an IP, or `key:<id>` for an API key), its timestamp, its limit and
  this node's name. Every node's Replicator receives it, its own included, so
  a node ignores messages it sent: the plug already counted them. (Before
  2026-10-30 the message carried no origin and `broadcast_from` excluded only
  the request process, so each node counted its own requests twice.) Each node's Replicator applies remote timestamps
  into the same ETS table the plug reads, so every node's sliding window
  reflects cluster-wide traffic for that IP.

  This is **eventually consistent**: a burst can briefly exceed the cap on a
  node before peers' increments propagate (sub-millisecond on a healthy LAN).
  That is the right tradeoff for abuse-throttling — fast and infra-free, at the
  cost of a small, bounded leak. For a hard guarantee, enforce at the edge.

  Replication is best-effort and decoupled from the request path: if this
  process isn't running (single-node, tests) the limiter still works locally.
  """

  use GenServer
  require Logger

  alias Phoenix.PubSub

  @pubsub Bitblocks.PubSub
  @topic "rate_limiter:replication"
  @table :rate_limiter

  # -- public API --------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Broadcast a local request (IP + timestamp) to peer nodes. Best-effort: a
  failure here must never affect the request being served.
  """
  @spec record(String.t(), integer(), pos_integer()) :: :ok
  def record(bucket, now, limit) when is_binary(bucket) and is_integer(now) do
    PubSub.broadcast(@pubsub, @topic, {:rl_hit, node(), bucket, now, limit})
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # -- GenServer ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    PubSub.subscribe(@pubsub, @topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:rl_hit, origin, _bucket, _ts, _limit}, state) when origin == node(),
    do: {:noreply, state}

  def handle_info({:rl_hit, _origin, bucket, ts, limit}, state) do
    apply_remote_hit(bucket, ts, limit)
    {:noreply, state}
  end

  # Pre-2026-10-30 shape, from a peer still on the old release mid-deploy.
  def handle_info({:rl_hit, ip, ts}, state) do
    apply_remote_hit(ip, ts, config(:max_requests, 120))
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Merge a peer's timestamp into our local window for this IP. Bounded: we cap
  # the retained list so a flood of remote hits can't grow a single IP's entry
  # without limit (the plug only needs enough to count against max_requests).
  defp apply_remote_hit(ip, ts, limit) do
    ensure_table()
    window_ms = config(:window_ms, 60_000)
    cutoff = System.system_time(:millisecond) - window_ms

    existing =
      case :ets.lookup(@table, ip) do
        [{^ip, timestamps}] -> timestamps
        [] -> []
      end

    merged =
      [ts | existing]
      |> Enum.filter(&(&1 > cutoff))
      |> Enum.sort(:desc)
      |> Enum.take(max_retained(limit))

    :ets.insert(@table, {ip, merged})
  rescue
    _ -> :ok
  end

  # Keep a little headroom above max_requests so the count is accurate up to the
  # limit without retaining unbounded history.
  defp max_retained(limit), do: limit * 2 + 10

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp config(key, default) do
    Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, [])
    |> Keyword.get(key, default)
  end
end
