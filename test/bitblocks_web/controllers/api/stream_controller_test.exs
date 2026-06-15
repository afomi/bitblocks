defmodule BitblocksWeb.Api.StreamControllerTest do
  # async: false — toggles the shared SseLimiter config/ETS state.
  use BitblocksWeb.ConnCase, async: false

  alias BitblocksWeb.SseLimiter

  setup do
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

    case :ets.whereis(:sse_limiter) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:sse_limiter)
    end

    :ok
  end

  describe "GET /api/v1/stream/blocks — connection cap (threat T2)" do
    test "returns 503 when the SSE concurrency cap is exhausted", %{conn: conn} do
      # Cap at zero so the handler refuses before ever blocking on receive.
      Application.put_env(:bitblocks, SseLimiter, max_global: 0, max_per_ip: 0)

      conn = get(conn, ~p"/api/v1/stream/blocks")

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["30"]
    end

    test "a rejected stream consumes no SSE slot", %{conn: conn} do
      Application.put_env(:bitblocks, SseLimiter, max_global: 0, max_per_ip: 0)

      get(conn, ~p"/api/v1/stream/blocks")

      assert SseLimiter.global_count() == 0
    end
  end

  describe "SSE connection lifetime (threat T2)" do
    alias BitblocksWeb.Api.StreamController

    test "a fresh deadline is in the future and not yet expired" do
      deadline = StreamController.deadline()
      refute StreamController.expired?(deadline)
    end

    test "a deadline in the past is expired (connection will be recycled)" do
      past = System.monotonic_time(:millisecond) - 1
      assert StreamController.expired?(past)
    end

    test "the configured max lifetime is finite (no unbounded connections)" do
      deadline = StreamController.deadline()
      now = System.monotonic_time(:millisecond)
      # Default 30 min; assert it's a sane, finite, positive bound.
      assert deadline > now
      assert deadline - now <= 60 * 60_000
    end
  end

  describe "GET /api/v1/stream/order-book — token_id validation (threat T8)" do
    test "rejects a token_id that could inject a PubSub topic separator", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/stream/order-book?token_id=evil:injected")
      assert json_response(conn, 400)["error"] == "Invalid token_id"
    end

    test "a rejected subscription consumes no SSE slot", %{conn: conn} do
      get(conn, ~p"/api/v1/stream/order-book?token_id=#{"bad/value"}")
      assert SseLimiter.global_count() == 0
    end
  end
end
