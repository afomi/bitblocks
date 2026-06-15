defmodule BitblocksWeb.SseLimiter.ClusterStateTest do
  # async: false — shares the named ClusterState GenServer and SseLimiter ETS.
  use ExUnit.Case, async: false

  alias BitblocksWeb.SseLimiter
  alias BitblocksWeb.SseLimiter.ClusterState

  setup do
    # Clear any peer state and local counts left by other tests by sending a
    # nodedown for any fake nodes we inject, and resetting the ETS table.
    case :ets.whereis(:sse_limiter) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:sse_limiter)
    end

    on_exit(fn ->
      # Remove the fake peers we injected so they don't leak into other tests.
      for n <- [:"fake1@host", :"fake2@host"], do: send(ClusterState, {:nodedown, n})

      case :ets.whereis(:sse_limiter) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:sse_limiter)
      end
    end)

    :ok
  end

  describe "peer tally aggregation (T2 cluster-wide cap)" do
    test "sums global and per-IP counts across peer nodes" do
      send(ClusterState, {:sse_tally, :"fake1@host", 3, %{"1.1.1.1" => 2, "2.2.2.2" => 1}})
      send(ClusterState, {:sse_tally, :"fake2@host", 4, %{"1.1.1.1" => 1}})

      {global, ips} = ClusterState.peer_counts()

      assert global == 7
      assert ips["1.1.1.1"] == 3
      assert ips["2.2.2.2"] == 1
    end

    test "a node's own tally is ignored (no double-count of self)" do
      send(ClusterState, {:sse_tally, Node.self(), 99, %{"9.9.9.9" => 99}})

      {global, ips} = ClusterState.peer_counts()

      assert global == 0
      refute Map.has_key?(ips, "9.9.9.9")
    end

    test "nodedown drops that peer's contribution (crash self-heals)" do
      send(ClusterState, {:sse_tally, :"fake1@host", 5, %{"1.1.1.1" => 5}})
      assert {5, _} = ClusterState.peer_counts()

      send(ClusterState, {:nodedown, :"fake1@host"})
      assert {0, ips} = ClusterState.peer_counts()
      refute Map.has_key?(ips, "1.1.1.1")
    end
  end

  describe "SseLimiter.local_counts/0" do
    test "reports this node's per-IP counts, excluding the global key" do
      assert :ok = SseLimiter.acquire("7.7.7.7")
      assert :ok = SseLimiter.acquire("7.7.7.7")
      assert :ok = SseLimiter.acquire("8.8.8.8")

      {global, ips} = SseLimiter.local_counts()

      assert global == 3
      assert ips["7.7.7.7"] == 2
      assert ips["8.8.8.8"] == 1

      SseLimiter.release("7.7.7.7")
      SseLimiter.release("7.7.7.7")
      SseLimiter.release("8.8.8.8")
    end
  end

  describe "cluster-wide enforcement" do
    test "peer counts count against the per-IP cap" do
      prev = Application.get_env(:bitblocks, SseLimiter)
      Application.put_env(:bitblocks, SseLimiter, max_global: 100, max_per_ip: 3)
      on_exit(fn -> Application.put_env(:bitblocks, SseLimiter, prev) end)

      ip = "5.5.5.5"
      # A peer already holds 2 of this IP's 3 allowed connections.
      send(ClusterState, {:sse_tally, :"fake1@host", 2, %{ip => 2}})
      # Let the message be processed before we read peer_counts in acquire.
      _ = ClusterState.peer_counts()

      # Locally we may open only 1 more before the cluster-wide cap of 3.
      assert :ok = SseLimiter.acquire(ip)
      assert {:error, :too_many_connections} = SseLimiter.acquire(ip)

      SseLimiter.release(ip)
    end
  end
end
