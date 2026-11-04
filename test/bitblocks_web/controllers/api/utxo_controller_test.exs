defmodule BitblocksWeb.Api.UtxoControllerTest do
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.ChainFixtures
  import Ecto.Query

  alias Bitblocks.Chain.{Block, Spend, Transaction}
  alias Bitblocks.FirstSpendFixtures, as: FS
  alias Bitblocks.OrdinalFixtures
  alias Bitblocks.Repo

  @satoshi "12cbQLTFMXRnSzktFkuoG3eHoMeFtpTu3S"

  # Validation gate (threat T7): a non-hex / wrong-length txid is rejected
  # before any lookup.

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

  describe "GET /api/v1/utxo/:txid/:vout/owner — local" do
    setup do
      FS.insert_first_spend()
      completed_chain_fixture(170)
      :ok
    end

    test "a spent output names the spender the spend index holds", %{conn: conn} do
      body = json_response(get(conn, ~p"/api/v1/utxo/#{FS.coinbase_9()}/0/owner"), 200)
      spend = Repo.one!(from(s in Spend, where: s.txid == ^FS.coinbase_9() and s.vout == 0))

      assert body == %{
               "address" => @satoshi,
               "spent" => true,
               "spent_by" => spend.spending_txid,
               "spent_by_vin" => spend.spending_vin,
               "status" => "spent",
               "source" => "local",
               "indexed_through_height" => 170,
               "tip_height" => 170
             }
    end

    test "an unspent output is unspent from local data when the index reaches the tip", %{
      conn: conn
    } do
      body = json_response(get(conn, ~p"/api/v1/utxo/#{FS.first_spend()}/1/owner"), 200)

      assert %{
               "address" => @satoshi,
               "spent" => false,
               "status" => "unspent",
               "source" => "local"
             } =
               body

      refute Repo.exists?(from(s in Spend, where: s.txid == ^FS.first_spend()))
    end

    test "an output beyond the tx's outputs is a 404", %{conn: conn} do
      # Not stored locally under that vout, and the WoC stub doesn't know the tx.
      conn = get(conn, ~p"/api/v1/utxo/#{FS.first_spend()}/9/owner")
      assert json_response(conn, 404)["error"] == "Output not found"
    end
  end

  describe "GET /api/v1/utxo/:txid/:vout/owner — not settled locally" do
    setup do
      FS.insert_first_spend()
      completed_chain_fixture(170)

      # Block 170 is a header we hold but haven't synced.
      Repo.delete_all(from(t in Transaction, where: t.block_height == 170))
      Repo.delete_all(Spend)
      Repo.update_all(from(b in Block, where: b.height == 170), set: [sync_state: "header_only"])
      :ok
    end

    test "asks WhatsOnChain and says so", %{conn: conn} do
      OrdinalFixtures.spend("#{FS.coinbase_9()}_0", FS.first_spend(), 0)

      body = json_response(get(conn, ~p"/api/v1/utxo/#{FS.coinbase_9()}/0/owner"), 200)

      assert body == %{
               "address" => @satoshi,
               "spent" => true,
               "spent_by" => FS.first_spend(),
               "spent_by_vin" => 0,
               "status" => "spent",
               "source" => "whatsonchain"
             }
    end

    test "is unknown, from local data, when WhatsOnChain can't answer", %{conn: conn} do
      Process.put(:woc_spent, %{"#{FS.coinbase_9()}_0" => {:error, :timeout}})

      body = json_response(get(conn, ~p"/api/v1/utxo/#{FS.coinbase_9()}/0/owner"), 200)

      assert %{
               "address" => @satoshi,
               "spent" => nil,
               "status" => "unknown",
               "source" => "local",
               "indexed_through_height" => 169,
               "tip_height" => 170
             } = body
    end
  end

  describe "GET /api/v1/utxo/:txid/:vout/owner — a tx we don't hold" do
    test "comes from WhatsOnChain, checked against its txid, and says so", %{conn: conn} do
      addr = OrdinalFixtures.address()

      {txid, _} =
        t =
        OrdinalFixtures.tx([OrdinalFixtures.funding_outpoint()], [
          OrdinalFixtures.p2pkh(addr, 546)
        ])

      OrdinalFixtures.publish(t)

      body = json_response(get(conn, ~p"/api/v1/utxo/#{txid}/0/owner"), 200)

      assert body == %{
               "address" => addr,
               "spent" => false,
               "status" => "unspent",
               "source" => "whatsonchain"
             }
    end

    test "is a 404 when WhatsOnChain doesn't know it either", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/utxo/#{String.duplicate("ab", 32)}/0/owner")
      assert json_response(conn, 404)["error"] == "Output not found"
    end
  end
end
