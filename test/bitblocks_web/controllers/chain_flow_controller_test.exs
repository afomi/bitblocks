defmodule BitblocksWeb.ChainFlowControllerTest do
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.FirstSpendFixtures

  test "serves the range's graph", %{conn: conn} do
    insert_first_spend()
    body = conn |> get("/chain-scrubber/flow?from=0&to=999") |> json_response(200)
    assert body["from"] == 0
    assert length(body["txs"]) == 3
    assert body["edges"] == [[0, 0, 2, 5_000_000_000]]
  end

  test "a bad range is a 400", %{conn: conn} do
    assert conn |> get("/chain-scrubber/flow?from=10&to=2") |> json_response(400)
    assert build_conn() |> get("/chain-scrubber/flow?from=x&to=2") |> json_response(400)
  end
end
