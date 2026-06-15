defmodule BitblocksWeb.Api.UtxoControllerTest do
  use BitblocksWeb.ConnCase, async: true

  # Validation gate (threat T7): a non-hex / wrong-length txid is rejected
  # before any WhatsOnChain proxy call.

  describe "GET /api/v1/utxo/:txid/:vout/owner — validation" do
    test "rejects a non-hex txid with 400", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/utxo/not-a-valid-txid/0/owner")
      assert json_response(conn, 400)["error"] =~ "Invalid txid"
    end

    test "rejects a wrong-length txid with 400", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/utxo/#{String.duplicate("a", 10)}/0/owner")
      assert json_response(conn, 400)["error"] =~ "Invalid txid"
    end

    test "still rejects an invalid vout for a valid txid", %{conn: conn} do
      valid_txid = String.duplicate("a", 64)
      conn = get(conn, ~p"/api/v1/utxo/#{valid_txid}/-1/owner")
      assert json_response(conn, 400)["error"] =~ "Invalid vout"
    end
  end
end
