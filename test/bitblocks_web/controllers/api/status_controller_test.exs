defmodule BitblocksWeb.Api.StatusControllerTest do
  # GET /api/v1/status: how healthy and how current Bitblocks is, public and
  # cheap (cached state only), never the node's address.
  use BitblocksWeb.ConnCase, async: false

  test "answers health as JSON", %{conn: conn} do
    body = conn |> get("/api/v1/status") |> json_response(200)

    assert body["status"] in ["ok", "degraded", "down"]
    assert Map.has_key?(body, "index")
    assert Map.has_key?(body["index"], "complete_through")
    assert Map.has_key?(body, "node")
    assert Map.has_key?(body, "lag")
    refute Jason.encode!(body) =~ "8332"
  end

  test "names the running release", %{conn: conn} do
    body = conn |> get("/api/v1/status") |> json_response(200)
    assert Map.has_key?(body["release"], "sha")
  end

  test "coverage answers a curve", %{conn: conn} do
    :persistent_term.erase({Bitblocks.Ops, :coverage})
    body = conn |> get("/api/v1/status/coverage") |> json_response(200)
    assert body["bucket_size"] == 10_000
    assert is_list(body["buckets"])
    assert Map.has_key?(body, "eta_hours")
  end
end
