defmodule BitblocksWeb.Plugs.RateLimiter.ReplicatorTest do
  # async: false — shares the named :rate_limiter ETS table and the PubSub topic.
  use ExUnit.Case, async: false

  alias BitblocksWeb.Plugs.RateLimiter.Replicator

  @table :rate_limiter
  @topic "rate_limiter:replication"

  setup do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@table)
    end

    on_exit(fn ->
      case :ets.whereis(@table) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(@table)
      end
    end)

    :ok
  end

  describe "applying remote hits (T1/T12 cluster replication)" do
    test "a remote :rl_hit merges a timestamp into the shared ETS window" do
      ip = "203.0.113.merge.#{System.unique_integer([:positive])}"
      now = System.system_time(:millisecond)

      # Simulate a peer node broadcasting a hit. The running Replicator (started
      # in the app supervision tree) subscribes to @topic and applies it.
      Phoenix.PubSub.broadcast(Bitblocks.PubSub, @topic, {:rl_hit, ip, now})

      # Give the GenServer a moment to handle the cast.
      wait_until(fn -> lookup(ip) != [] end)

      assert [{^ip, timestamps}] = lookup(ip)
      assert now in timestamps
    end

    test "remote hits from the same IP accumulate toward the window" do
      # Unique IP per run so async residue from other tests can't interfere with
      # the count assertion on the shared (app-owned) Replicator + ETS table.
      ip = "203.0.113.#{System.unique_integer([:positive]) |> rem(250)}.acc"
      base = System.system_time(:millisecond)

      for offset <- 0..4 do
        Phoenix.PubSub.broadcast(Bitblocks.PubSub, @topic, {:rl_hit, ip, base + offset})
      end

      wait_until(fn ->
        case lookup(ip) do
          [{^ip, ts}] -> length(ts) >= 5
          _ -> false
        end
      end)

      assert [{^ip, ts}] = lookup(ip)
      assert length(ts) >= 5
    end

    test "retained timestamps are bounded (a flood can't grow one IP unboundedly)" do
      # Pin a small max_requests so the retention cap (max_requests*2 + 10 = 30)
      # is well below the flood size, making the bound observable.
      prev = Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter)
      Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, window_ms: 60_000, max_requests: 10)
      on_exit(fn -> Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, prev) end)

      ip = "203.0.113.flood.#{System.unique_integer([:positive])}"
      base = System.system_time(:millisecond)

      for i <- 1..500 do
        Phoenix.PubSub.broadcast(Bitblocks.PubSub, @topic, {:rl_hit, ip, base + i})
      end

      wait_until(fn ->
        case lookup(ip) do
          [{^ip, ts}] -> length(ts) >= 30
          _ -> false
        end
      end)

      Process.sleep(50)
      assert [{^ip, ts}] = lookup(ip)
      # max_retained = 10*2 + 10 = 30. Must be capped there, not 500.
      assert length(ts) <= 30
    end
  end

  describe "record/2 — best effort, never crashes the caller" do
    test "returns :ok even with the topic in place" do
      assert :ok = Replicator.record("198.51.100.1", System.system_time(:millisecond))
    end
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      attempts <= 0 -> flunk("condition not met in time")
      fun.() -> :ok
      true ->
        Process.sleep(5)
        wait_until(fun, attempts - 1)
    end
  end

  # Table-safe lookup: the :rate_limiter ETS table is created lazily, so it may
  # not exist yet when a test first reads it. Treat absent as empty.
  defp lookup(ip) do
    case :ets.whereis(@table) do
      :undefined -> []
      _ -> :ets.lookup(@table, ip)
    end
  end
end
