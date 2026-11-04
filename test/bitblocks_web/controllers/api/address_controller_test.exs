defmodule BitblocksWeb.Api.AddressControllerTest do
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.ChainFixtures
  import Ecto.Query

  alias Bitblocks.Chain.{Block, RawBlock, Spend, Transaction, TxIngest}
  alias Bitblocks.FirstSpendFixtures
  alias Bitblocks.OrdinalFixtures
  alias Bitblocks.Repo

  # A valid BSV address (base58check, correct charset/length).
  @address "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"

  # Block 9's coinbase key: 50 coins at block 9, spent at 170, 40 back as change.
  @satoshi "12cbQLTFMXRnSzktFkuoG3eHoMeFtpTu3S"

  # Stores a real tx paying `outputs` into the stored block at `height`.
  defp store(outputs, height, inputs \\ [OrdinalFixtures.funding_outpoint()]) do
    {txid, hex} = OrdinalFixtures.tx(inputs, outputs)
    block = Repo.get_by!(Block, height: height)
    :ok = TxIngest.store(RawBlock.tx_json(txid, Base.decode16!(hex, case: :mixed)), block)
    txid
  end

  defp pay(sats), do: OrdinalFixtures.p2pkh(@address, sats)

  # Spends (txid, vout) from a stored tx at `height`.
  defp spend(txid, vout, height),
    do: store([OrdinalFixtures.p2pkh(OrdinalFixtures.address(), 1)], height, ["#{txid}_#{vout}"])

  describe "GET /api/v1/addresses/:address/utxos — validation" do
    test "rejects an address with base58-invalid characters", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/addresses/1BvBMSEYst0OIlInvalid/utxos")
      assert json_response(conn, 400)["error"] == "Invalid address"
    end

    test "rejects an over-long address", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/addresses/#{String.duplicate("a", 60)}/utxos")
      assert json_response(conn, 400)["error"] == "Invalid address"
    end
  end

  describe "GET /api/v1/addresses/:address/balance — validation" do
    test "rejects an address with base58-invalid characters", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/addresses/1BvBMSEYst0OIlInvalid/balance")
      assert json_response(conn, 400)["error"] == "Invalid address"
    end
  end

  describe "GET /api/v1/addresses/:address/utxos — local data" do
    setup do
      completed_chain_fixture(6)
      :ok
    end

    test "an address with no outputs has none, exactly", %{conn: conn} do
      body = json_response(get(conn, ~p"/api/v1/addresses/#{@address}/utxos"), 200)
      assert body["data"] == []
      assert body["unknown"] == []
      assert body["meta"]["source"] == "local"
      assert body["meta"]["status"] == "exact"
      assert body["meta"]["indexed_through_height"] == 6
      assert body["meta"]["count"] == 0
    end

    test "lists unspent outputs and leaves out spent ones", %{conn: conn} do
      txid = store([pay(100_000), pay(200_000)], 5)
      spend(txid, 0, 6)

      body = json_response(get(conn, ~p"/api/v1/addresses/#{@address}/utxos"), 200)
      assert body["meta"]["count"] == 1

      assert [%{"txid" => ^txid, "vout" => 1, "satoshis" => 200_000, "block_height" => 5}] =
               body["data"]
    end

    test "lists outputs as unknown, not unspent, while the index is behind the tip", %{
      conn: conn
    } do
      txid = store([pay(100_000)], 5)
      block_fixture(%{height: 7, sync_state: "header_only"})

      body = json_response(get(conn, ~p"/api/v1/addresses/#{@address}/utxos"), 200)
      assert body["data"] == []
      assert [%{"txid" => ^txid, "vout" => 0}] = body["unknown"]
      assert body["meta"]["status"] == "partial"
      assert body["meta"]["indexed_through_height"] == 6
      assert body["meta"]["tip_height"] == 7
    end
  end

  describe "GET /api/v1/addresses/:address/balance — local data" do
    test "is exact through the tip: confirmed and indexed_through_height", %{conn: conn} do
      completed_chain_fixture(6)
      txid = store([pay(100_000), pay(200_001)], 5)
      spend(txid, 0, 6)

      body = json_response(get(conn, ~p"/api/v1/addresses/#{@address}/balance"), 200)

      assert body["data"] == %{
               "status" => "exact",
               "confirmed" => 200_001,
               "indexed_through_height" => 6,
               "tip_height" => 6
             }

      assert body["meta"]["source"] == "local"
    end

    test "has no confirmed key when a spend's block isn't synced yet", %{conn: conn} do
      FirstSpendFixtures.insert_first_spend()
      completed_chain_fixture(170)

      # Block 170 is a header we hold but haven't synced.
      Repo.delete_all(from(t in Transaction, where: t.block_height == 170))
      Repo.delete_all(Spend)
      Repo.update_all(from(b in Block, where: b.height == 170), set: [sync_state: "header_only"])

      body = json_response(get(conn, ~p"/api/v1/addresses/#{@satoshi}/balance"), 200)

      assert body["data"] == %{
               "status" => "partial",
               "unknown" => 5_000_000_000,
               "indexed_through_height" => 169,
               "tip_height" => 170
             }
    end

    test "the first spend, fully synced, is exact in satoshis from the raw txs", %{conn: conn} do
      FirstSpendFixtures.insert_first_spend()
      completed_chain_fixture(170)

      body = json_response(get(conn, ~p"/api/v1/addresses/#{@satoshi}/balance"), 200)
      assert %{"status" => "exact", "confirmed" => 4_000_000_000} = body["data"]
    end

    test "with nothing indexed it is unknown, not zero confirmed", %{conn: conn} do
      body = json_response(get(conn, ~p"/api/v1/addresses/#{@address}/balance"), 200)
      assert %{"status" => "unknown", "unknown" => 0} = data = body["data"]
      refute Map.has_key?(data, "confirmed")
    end

    test "an output with no address is left out", %{conn: conn} do
      completed_chain_fixture(5)
      store([OrdinalFixtures.data_output(), pay(700), OrdinalFixtures.contract()], 5)

      body = json_response(get(conn, ~p"/api/v1/addresses/#{@address}/balance"), 200)
      assert %{"status" => "exact", "confirmed" => 700} = body["data"]

      body = json_response(get(build_conn(), ~p"/api/v1/addresses/#{@address}/utxos"), 200)
      assert [%{"vout" => 1}] = body["data"]
    end
  end
end
