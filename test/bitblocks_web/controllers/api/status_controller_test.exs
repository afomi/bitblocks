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
end
