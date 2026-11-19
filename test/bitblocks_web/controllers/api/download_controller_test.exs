defmodule BitblocksWeb.Api.DownloadControllerTest do
  # GET /api/v1/downloads/quote (https://github.com/afomi/bitblocks/issues/111):
  # the free quote for agents, from stored block sizes.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.ChainFixtures

  setup do
    for {size, height} <- Enum.with_index([285, 1_000, 2_000]) do
      block_fixture(%{height: height, size: size, sync_state: "completed"})
    end

    block_fixture(%{height: 3, size: 5_000, sync_state: "header_only"})
    :ok
  end

  test "quotes a range with no price set", %{conn: conn} do
    body =
      conn
      |> get(~p"/api/v1/downloads/quote?from=1&to=2&data=raw")
      |> json_response(200)

    assert %{
             "from" => 1,
             "to" => 2,
             "data" => "raw",
             "format" => "bin",
             "files" => 2,
             "bytes" => 3_000,
             "bytes_exact" => true,
             "sizes_missing" => 0,
             "complete_through" => 2,
             "price_usd" => nil,
             "price" => "on_request",
             "checkout" => "not_built"
           } = body["data"]

    assert body["data"]["contact"] =~ "mailto:"
    assert body["meta"]["size_source"] == "blocks.size"
  end

  test "refuses a range above complete_through with that height", %{conn: conn} do
    body =
      conn
      |> get(~p"/api/v1/downloads/quote?from=0&to=3&data=raw")
      |> json_response(422)

    assert body["error"] == "above_complete_through"
    assert body["complete_through"] == 2
    assert body["message"] =~ "through 2"
  end

  test "refuses data that is coming", %{conn: conn} do
    body =
      conn
      |> get(~p"/api/v1/downloads/quote?from=0&to=1&data=tx_json")
      |> json_response(422)

    assert body["error"] == "coming"
  end
end
