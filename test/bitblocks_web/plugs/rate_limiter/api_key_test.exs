defmodule BitblocksWeb.Plugs.RateLimiter.ApiKeyTest do
  @moduledoc """
  API keys give a caller (qart's server first) its own rate budget instead of
  sharing its IP's anonymous one. #12 / #13 / #29 step 5.
  """
  # async: false — the limiter's ETS table and config are global.
  use BitblocksWeb.ConnCase, async: false

  alias Bitblocks.ApiKeys

  setup do
    case :ets.whereis(:rate_limiter) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:rate_limiter)
    end

    previous = Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter)
    Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, max_requests: 2)
    on_exit(fn -> Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, previous) end)

    {:ok, key, token} = ApiKeys.create("qart", 5)
    %{key: key, token: token}
  end

  defp get_with(headers) do
    Enum.reduce(headers, build_conn(), fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> get("/api/v1/blocks")
  end

  test "a key has its own budget, past the anonymous one", %{token: token} do
    statuses = for _ <- 1..5, do: get_with([{"authorization", "Bearer #{token}"}]).status
    assert statuses == List.duplicate(200, 5)

    over = get_with([{"authorization", "Bearer #{token}"}])
    assert over.status == 429
    assert get_resp_header(over, "x-ratelimit-limit") == ["5"]
  end

  test "x-api-key works the same as a bearer token", %{token: token} do
    conn = get_with([{"x-api-key", token}])
    assert conn.status == 200
    assert get_resp_header(conn, "x-ratelimit-limit") == ["5"]
  end

  test "anonymous callers keep the per-IP limit" do
    assert [200, 200, 429] == for(_ <- 1..3, do: get_with([]).status)
  end

  test "an unknown or revoked key is a 401, not a silent fallback", %{key: key, token: token} do
    bogus = get_with([{"authorization", "Bearer bbk_not-a-real-key"}])
    assert bogus.status == 401
    assert %{"error" => "Invalid API key" <> _} = Jason.decode!(bogus.resp_body)

    {:ok, _} = ApiKeys.revoke(key.id)
    assert get_with([{"authorization", "Bearer #{token}"}]).status == 401
  end

  test "only a hash of the key is stored", %{key: key, token: token} do
    refute key.token_hash == token
    assert key.token_hash == :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    assert String.starts_with?(token, "bbk_")
  end
end
