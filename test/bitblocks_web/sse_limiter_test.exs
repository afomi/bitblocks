defmodule BitblocksWeb.SseLimiterTest do
  # async: false — the limiter uses a shared named ETS table and global config.
  use ExUnit.Case, async: false

  alias BitblocksWeb.SseLimiter

  setup do
    # Start from a clean table so counts don't leak between tests.
    case :ets.whereis(:sse_limiter) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:sse_limiter)
    end

    prev = Application.get_env(:bitblocks, SseLimiter)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:bitblocks, SseLimiter, prev),
        else: Application.delete_env(:bitblocks, SseLimiter)

      case :ets.whereis(:sse_limiter) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:sse_limiter)
      end
    end)

    :ok
  end

  defp configure(opts), do: Application.put_env(:bitblocks, SseLimiter, opts)

  describe "per-IP cap (threat T2)" do
    test "allows connections up to max_per_ip, then rejects" do
      configure(max_global: 100, max_per_ip: 3)
      ip = "1.2.3.4"

      assert :ok = SseLimiter.acquire(ip)
      assert :ok = SseLimiter.acquire(ip)
      assert :ok = SseLimiter.acquire(ip)
      assert SseLimiter.ip_count(ip) == 3

      assert {:error, :too_many_connections} = SseLimiter.acquire(ip)
      # A rejected acquire must not consume a global slot.
      assert SseLimiter.global_count() == 3
    end

    test "releasing a slot lets a new connection in" do
      configure(max_global: 100, max_per_ip: 1)
      ip = "5.6.7.8"

      assert :ok = SseLimiter.acquire(ip)
      assert {:error, :too_many_connections} = SseLimiter.acquire(ip)

      SseLimiter.release(ip)
      assert SseLimiter.ip_count(ip) == 0
      assert :ok = SseLimiter.acquire(ip)
    end

    test "one IP hitting its cap does not block another IP" do
      configure(max_global: 100, max_per_ip: 1)

      assert :ok = SseLimiter.acquire("10.0.0.1")
      assert {:error, :too_many_connections} = SseLimiter.acquire("10.0.0.1")
      assert :ok = SseLimiter.acquire("10.0.0.2")
    end
  end

  describe "global cap (threat T2)" do
    test "rejects once the global ceiling is reached, across IPs" do
      configure(max_global: 2, max_per_ip: 10)

      assert :ok = SseLimiter.acquire("a")
      assert :ok = SseLimiter.acquire("b")
      assert {:error, :too_many_connections} = SseLimiter.acquire("c")
      assert SseLimiter.global_count() == 2
    end
  end

  describe "release safety" do
    test "double release cannot drive counters negative" do
      configure(max_global: 100, max_per_ip: 5)
      ip = "9.9.9.9"

      assert :ok = SseLimiter.acquire(ip)
      SseLimiter.release(ip)
      SseLimiter.release(ip)

      assert SseLimiter.ip_count(ip) == 0
      assert SseLimiter.global_count() == 0

      # Counters are still sane afterwards.
      assert :ok = SseLimiter.acquire(ip)
      assert SseLimiter.ip_count(ip) == 1
    end
  end
end
