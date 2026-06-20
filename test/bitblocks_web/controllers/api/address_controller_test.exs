defmodule BitblocksWeb.Api.AddressControllerTest do
  use BitblocksWeb.ConnCase, async: true

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain

  # A valid BSV address (base58check, correct charset/length).
  @address "19JJzPiWzWKPQWMa6zj7JqPyYEMoP2xwEr"

  # Builds a JSON-encoded vout entry for the given address and BSV value.
  defp vout_json(address, bsv_value, index \\ 0) do
    Jason.encode!(%{
      "n" => index,
      "value" => bsv_value,
      "scriptPubKey" => %{
        "type" => "pubkeyhash",
        "addresses" => [address]
      }
    })
  end

  # Records a spend of (txid, vout) by a new transaction.
  defp spend(txid, vout) do
    spending_tx = transaction_fixture(%{
      inputs: [Jason.encode!(%{"txid" => txid, "vout" => vout, "scriptSig" => %{"hex" => "00"}})],
      input_count: 1
    })
    Chain.record_spends(spending_tx)
    spending_tx
  end

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
    test "returns empty list for address with no transactions", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/addresses/#{@address}/utxos")
      body = json_response(conn, 200)
      assert body["data"] == []
      assert body["meta"]["source"] == "local"
      assert body["meta"]["count"] == 0
    end

    test "returns unspent output for address", %{conn: conn} do
      _tx = transaction_fixture(%{
        output_addresses: [@address],
        outputs: [vout_json(@address, 0.005)],
        output_count: 1
      })

      conn = get(conn, ~p"/api/v1/addresses/#{@address}/utxos")
      body = json_response(conn, 200)
      assert body["meta"]["count"] == 1
      [utxo] = body["data"]
      assert utxo["vout"] == 0
      assert utxo["satoshis"] == 500_000
    end

    test "excludes spent outputs", %{conn: conn} do
      tx = transaction_fixture(%{
        output_addresses: [@address],
        outputs: [vout_json(@address, 0.001, 0), vout_json(@address, 0.002, 1)],
        output_count: 2
      })
      spend(tx.txid, 0)

      conn = get(conn, ~p"/api/v1/addresses/#{@address}/utxos")
      body = json_response(conn, 200)
      assert body["meta"]["count"] == 1
      [utxo] = body["data"]
      assert utxo["vout"] == 1
      assert utxo["satoshis"] == 200_000
    end

    test "returns UTXOs across multiple transactions", %{conn: conn} do
      transaction_fixture(%{
        output_addresses: [@address],
        outputs: [vout_json(@address, 0.001)],
        output_count: 1
      })
      transaction_fixture(%{
        output_addresses: [@address],
        outputs: [vout_json(@address, 0.002)],
        output_count: 1
      })

      conn = get(conn, ~p"/api/v1/addresses/#{@address}/utxos")
      body = json_response(conn, 200)
      assert body["meta"]["count"] == 2
    end
  end

  describe "GET /api/v1/addresses/:address/balance — local data" do
    test "returns 0 for address with no transactions", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/addresses/#{@address}/balance")
      body = json_response(conn, 200)
      assert body["data"]["confirmed"] == 0
      assert body["meta"]["source"] == "local"
    end

    test "returns sum of unspent satoshis", %{conn: conn} do
      transaction_fixture(%{
        output_addresses: [@address],
        outputs: [vout_json(@address, 0.001, 0), vout_json(@address, 0.002, 1)],
        output_count: 2
      })

      conn = get(conn, ~p"/api/v1/addresses/#{@address}/balance")
      body = json_response(conn, 200)
      assert body["data"]["confirmed"] == 300_000
    end

    test "excludes spent outputs from balance", %{conn: conn} do
      tx = transaction_fixture(%{
        output_addresses: [@address],
        outputs: [vout_json(@address, 0.001, 0), vout_json(@address, 0.002, 1)],
        output_count: 2
      })
      spend(tx.txid, 0)

      conn = get(conn, ~p"/api/v1/addresses/#{@address}/balance")
      body = json_response(conn, 200)
      assert body["data"]["confirmed"] == 200_000
    end
  end
end
