defmodule BitblocksWeb.Api.WocControllerTest do
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.ChainFixtures

  # Valid BSV address (base58check).
  @address "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"

  # Stores a real tx paying @address into the stored block at `height`.
  defp store_paying(sats, height) do
    {txid, hex} =
      Bitblocks.OrdinalFixtures.tx(
        [Bitblocks.OrdinalFixtures.funding_outpoint()],
        [Bitblocks.OrdinalFixtures.p2pkh(@address, sats)]
      )

    block = Bitblocks.Repo.get_by!(Bitblocks.Chain.Block, height: height)

    :ok =
      Bitblocks.Chain.TxIngest.store(
        Bitblocks.Chain.RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed)),
        block
      )

    txid
  end

  describe "GET /api/v1/woc/chain/info" do
    test "returns WoC-shaped chain info from the latest block (bare, no envelope)", %{conn: conn} do
      block_fixture(%{
        height: 700_000,
        hash: "deadbeef",
        difficulty: "1.5",
        chainwork: "ff",
        mediantime: 123
      })

      body = json_response(get(conn, ~p"/api/v1/woc/chain/info"), 200)

      # Bare object — WoC field names, no {data: ...} wrapper.
      refute Map.has_key?(body, "data")
      assert body["blocks"] == 700_000
      assert body["bestblockhash"] == "deadbeef"
      assert body["headers"] == 700_000
      assert Map.has_key?(body, "chainwork")
    end
  end

  describe "GET /api/v1/woc/tx/:txid/hex" do
    test "returns the raw hex as plain text", %{conn: conn} do
      tx = transaction_fixture(%{raw: "0100abcdef"})

      conn = get(conn, ~p"/api/v1/woc/tx/#{tx.txid}/hex")
      assert response(conn, 200) == "0100abcdef"
      assert response_content_type(conn, :text)
    end

    test "404s for an unknown txid", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/woc/tx/#{String.duplicate("0", 64)}/hex")
      assert json_response(conn, 404)["error"] =~ "not found"
    end
  end

  describe "GET /api/v1/woc/address/:address/unspent" do
    test "returns a bare array in WoC shape (tx_hash/tx_pos/value/height)", %{conn: conn} do
      completed_chain_fixture(5)
      txid = store_paying(100_000, 5)

      body = json_response(get(conn, ~p"/api/v1/woc/address/#{@address}/unspent"), 200)

      assert is_list(body)
      assert [utxo] = body
      assert utxo["tx_hash"] == txid
      assert utxo["tx_pos"] == 0
      assert utxo["value"] == 100_000
      assert utxo["height"] == 5
      # WoC shape only — no native keys leaking through.
      refute Map.has_key?(utxo, "txid")
      refute Map.has_key?(utxo, "satoshis")
    end

    test "rejects an invalid address", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/woc/address/1BvBMSEYst0OIlInvalid/unspent")
      assert json_response(conn, 400)["error"] == "Invalid address"
    end

    test "is a 503 naming the indexed height while the index is behind the tip", %{conn: conn} do
      completed_chain_fixture(5)
      store_paying(100_000, 5)
      block_fixture(%{height: 6, sync_state: "header_only"})

      body = json_response(get(conn, ~p"/api/v1/woc/address/#{@address}/unspent"), 503)
      assert %{"status" => "partial", "indexed_through_height" => 5, "tip_height" => 6} = body
    end
  end

  describe "GET /api/v1/woc/address/:address/balance" do
    test "returns {confirmed, unconfirmed} with unconfirmed always 0", %{conn: conn} do
      completed_chain_fixture(5)
      store_paying(200_000, 5)

      body = json_response(get(conn, ~p"/api/v1/woc/address/#{@address}/balance"), 200)
      assert body["confirmed"] == 200_000
      assert body["unconfirmed"] == 0
      refute Map.has_key?(body, "data")
    end

    test "is a 503 with no confirmed number while the index is behind the tip", %{conn: conn} do
      completed_chain_fixture(5)
      store_paying(200_000, 5)
      block_fixture(%{height: 6, sync_state: "header_only"})

      body = json_response(get(conn, ~p"/api/v1/woc/address/#{@address}/balance"), 503)
      refute Map.has_key?(body, "confirmed")
      assert %{"status" => "partial", "indexed_through_height" => 5} = body
    end
  end

  describe "POST /api/v1/woc/tx/raw" do
    test "400s when txhex is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/woc/tx/raw", %{})
      assert json_response(conn, 400)["error"] =~ "txhex"
    end

    test "400s when txhex is empty", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/woc/tx/raw", %{"txhex" => ""})
      assert json_response(conn, 400)["error"] =~ "txhex"
    end
  end
end
