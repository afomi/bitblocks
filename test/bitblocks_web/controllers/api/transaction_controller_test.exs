defmodule BitblocksWeb.Api.TransactionControllerTest do
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.ChainFixtures

  describe "GET /api/v1/txs/:txid" do
    test "returns 404 for unknown txid", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/txs/0000000000000000000000000000000000000000000000000000000000000000")
      assert json_response(conn, 404)
    end

    test "returns transaction with spend_depth for a coinbase tx", %{conn: conn} do
      tx = transaction_fixture(%{coinbase: true, input_txids: []})
      conn = get(conn, ~p"/api/v1/txs/#{tx.txid}")
      body = json_response(conn, 200)
      assert body["data"]["txid"] == tx.txid
      assert body["data"]["spend_depth"] == 0
    end

    test "returns spend_depth 1 for direct child of coinbase", %{conn: conn} do
      cb = transaction_fixture(%{coinbase: true, input_txids: []})
      child = transaction_fixture(%{coinbase: false, input_txids: [cb.txid]})
      conn = get(conn, ~p"/api/v1/txs/#{child.txid}")
      body = json_response(conn, 200)
      assert body["data"]["spend_depth"] == 1
    end

    test "returns spend_depth error map when txid chain is not indexed", %{conn: conn} do
      # A non-coinbase tx whose input_txids are not in the DB
      tx = transaction_fixture(%{coinbase: false, input_txids: ["aaaa"]})
      conn = get(conn, ~p"/api/v1/txs/#{tx.txid}")
      body = json_response(conn, 200)
      assert body["data"]["spend_depth"]["error"] == "not_found"
    end
  end
end
