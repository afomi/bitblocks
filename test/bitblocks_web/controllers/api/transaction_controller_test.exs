defmodule BitblocksWeb.Api.TransactionControllerTest do
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.ChainFixtures

  describe "GET /api/v1/txs" do
    test "pages by (block_height, txid); old rows inserted later stay down", %{conn: conn} do
      high = "b" <> String.duplicate("0", 63)
      same = "a" <> String.duplicate("0", 63)
      low = "c" <> String.duplicate("0", 63)

      transaction_fixture(%{txid: same, block_height: 900})
      transaction_fixture(%{txid: high, block_height: 900})
      transaction_fixture(%{txid: low, block_height: 800})

      first = conn |> get(~p"/api/v1/txs?per_page=2") |> json_response(200)
      assert Enum.map(first["data"], & &1["txid"]) == [high, same]
      assert first["meta"]["next_cursor"] == "900:#{same}"

      transaction_fixture(%{block_height: 5})

      again = conn |> get(~p"/api/v1/txs?per_page=2") |> json_response(200)
      assert Enum.map(again["data"], & &1["txid"]) == [high, same]

      rest =
        conn
        |> get(~p"/api/v1/txs?per_page=1&cursor=#{first["meta"]["next_cursor"]}")
        |> json_response(200)

      assert Enum.map(rest["data"], & &1["txid"]) == [low]
    end

    test "a row with no block height isn't listed", %{conn: conn} do
      tx = heightless_transaction_fixture()
      body = conn |> get(~p"/api/v1/txs") |> json_response(200)
      refute tx.txid in Enum.map(body["data"], & &1["txid"])
    end

    test "meta.complete covers the one block under a block_hash filter", %{conn: conn} do
      block = block_fixture(%{sync_state: "header_only"})

      meta = conn |> get(~p"/api/v1/txs?block_hash=#{block.hash}") |> json_response(200)
      assert meta["meta"]["complete"] == false
      assert meta["meta"]["snapshot_height"] == block.height
    end

    test "a txid filter is a hex prefix, any case", %{conn: conn} do
      tx = transaction_fixture(%{txid: "abc" <> String.duplicate("0", 61)})

      for prefix <- ["abc", "ABC"] do
        body = conn |> get(~p"/api/v1/txs?txid=#{prefix}") |> json_response(200)
        assert Enum.map(body["data"], & &1["txid"]) == [tx.txid]
      end

      assert %{"data" => []} = conn |> get(~p"/api/v1/txs?txid=%25abc") |> json_response(200)
    end

    test "a type filter lists the txs whose types hold it, and says how far types reach",
         %{conn: conn} do
      stas = transaction_fixture(%{block_height: 30, tx_types: ["p2pkh", "stas"]})
      transaction_fixture(%{block_height: 31, tx_types: ["p2pkh"]})
      transaction_fixture(%{block_height: 32, tx_types: nil})

      body = conn |> get(~p"/api/v1/txs?type=stas") |> json_response(200)
      assert Enum.map(body["data"], & &1["txid"]) == [stas.txid]
      assert Map.has_key?(body["meta"], "typed_through_height")

      plain = conn |> get(~p"/api/v1/txs") |> json_response(200)
      refute Map.has_key?(plain["meta"], "typed_through_height")
    end

    test "an unknown type is refused", %{conn: conn} do
      assert %{"error" => error} = conn |> get(~p"/api/v1/txs?type=nope") |> json_response(400)
      assert error =~ "/api/v1/types"
    end

    test "a numeric id cursor from before #35 is refused", %{conn: conn} do
      assert conn |> get(~p"/api/v1/txs?cursor=100") |> json_response(400)
    end
  end

  describe "GET /api/v1/txs/:txid" do
    test "returns 404 for unknown txid", %{conn: conn} do
      conn =
        get(
          conn,
          ~p"/api/v1/txs/0000000000000000000000000000000000000000000000000000000000000000"
        )

      assert json_response(conn, 404)
    end

    test "returns transaction with spend_depth for a coinbase tx", %{conn: conn} do
      tx = transaction_fixture(%{coinbase: true, input_txids: []})
      conn = get(conn, ~p"/api/v1/txs/#{tx.txid}")
      body = json_response(conn, 200)
      assert body["data"]["txid"] == tx.txid
      assert body["data"]["spend_depth"] == 0
    end

    test "a tx in a header_only block isn't described as confirmed (#34)", %{conn: conn} do
      block_fixture(%{hash: "header_block", height: 700, sync_state: "header_only"})
      tx = transaction_fixture(%{block_hash: "header_block", block_height: 700})

      data = conn |> get(~p"/api/v1/txs/#{tx.txid}") |> json_response(200) |> Map.fetch!("data")

      assert data["confirmed"] == false
      assert data["confirmation"] == "unverified"
    end

    test "a tx left under an orphaned block isn't confirmed (#34)", %{conn: conn} do
      tx = transaction_fixture(%{block_hash: "orphaned_block", block_height: 700})

      data = conn |> get(~p"/api/v1/txs/#{tx.txid}") |> json_response(200) |> Map.fetch!("data")

      assert data["confirmed"] == false
      assert data["confirmation"] == "orphaned"
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
