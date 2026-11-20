defmodule BitblocksWeb.Plugs.OpenCorsTest do
  @moduledoc """
  A browser wallet on any site can call the open routes, keys included
  (https://github.com/afomi/bitblocks/issues/121): the preflight is answered,
  a 429's Retry-After is readable, and `*` never comes with credentials.
  """
  # async: false: the limiter's ETS table and config are global.
  use BitblocksWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  @origin "https://wallet.example"

  # The open CORS routes, one per path shape.
  @open_paths [
    "/api/v1/keys/challenge",
    "/api/v1/keys",
    "/api/v1/status",
    "/api/v1/price/bsv",
    "/api/v1/support",
    "/api/v1/types",
    "/api/v1/types/export",
    "/api/v1/bitcom/snapshots",
    "/api/v1/headers",
    "/api/v1/headers/1",
    "/bitcom.json",
    "/interop/vectors/v1.json"
  ]

  setup do
    :ets.delete_all_objects(:rate_limiter)
    previous = Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter)
    on_exit(fn -> Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, previous) end)
    :ok
  end

  defp limit_to(n),
    do: Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, max_requests: n)

  defp preflight(path, method, headers \\ "content-type") do
    build_conn()
    |> put_req_header("origin", @origin)
    |> put_req_header("access-control-request-method", method)
    |> put_req_header("access-control-request-headers", headers)
    |> options(path)
  end

  defp header(conn, name), do: get_resp_header(conn, name)

  test "a preflight for a JSON POST to /api/v1/keys is a 204 that allows it" do
    conn = preflight("/api/v1/keys", "POST")

    assert conn.status == 204
    assert conn.halted
    assert header(conn, "access-control-allow-origin") == ["*"]
    assert [methods] = header(conn, "access-control-allow-methods")
    assert "POST" in String.split(methods, ", ")
    assert [allowed] = header(conn, "access-control-allow-headers")
    assert "content-type" in String.split(allowed, ", ")
    assert header(conn, "access-control-max-age") == ["86400"]
    assert header(conn, "access-control-allow-credentials") == []
  end

  test "every open route answers its preflight with a 204" do
    for path <- @open_paths do
      conn = preflight(path, "GET")
      assert conn.status == 204, "#{path} preflight was #{conn.status}"
      assert header(conn, "access-control-allow-origin") == ["*"], path
    end
  end

  test "a keyed route under :public_api allows the key headers" do
    [allowed] =
      preflight("/api/v1/types", "GET", "authorization") |> header("access-control-allow-headers")

    assert "authorization" in String.split(allowed, ", ")
    assert "x-api-key" in String.split(allowed, ", ")
  end

  test "a preflight costs no rate budget" do
    limit_to(1)
    ip = {10, 9, 0, 1}

    for _ <- 1..5 do
      assert %{build_conn() | remote_ip: ip}
             |> put_req_header("access-control-request-method", "GET")
             |> options("/api/v1/keys/challenge")
             |> Map.fetch!(:status) == 204
    end

    assert %{build_conn() | remote_ip: ip} |> get("/api/v1/keys/challenge") |> Map.fetch!(:status) ==
             200
  end

  test "a 429 on an open route is readable cross-origin, Retry-After included" do
    limit_to(1)
    ip = {10, 9, 0, 2}

    hit = fn ->
      %{build_conn() | remote_ip: ip}
      |> put_req_header("origin", @origin)
      |> get("/api/v1/keys/challenge")
    end

    assert hit.().status == 200

    {limited, _log} = with_log(hit)

    assert limited.status == 429
    assert [_] = header(limited, "retry-after")
    assert header(limited, "access-control-allow-origin") == ["*"]
    assert [exposed] = header(limited, "access-control-expose-headers")
    exposed = String.split(exposed, ", ")
    assert "retry-after" in exposed
    assert "x-ratelimit-limit" in exposed
    assert "x-ratelimit-remaining" in exposed
  end

  test "no response pairs * with credentials" do
    for path <- @open_paths,
        conn <- [
          preflight(path, "GET"),
          build_conn() |> put_req_header("origin", @origin) |> get(path)
        ] do
      assert header(conn, "access-control-allow-credentials") == [], path
    end
  end

  test "keyed routes outside the open pipelines get no CORS headers" do
    conn = build_conn() |> put_req_header("origin", @origin) |> get("/api/v1/blocks")
    assert header(conn, "access-control-allow-origin") == []
  end
end
