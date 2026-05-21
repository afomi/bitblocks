defmodule BitblocksWeb.Api.ProtocolFeedTest do
  use BitblocksWeb.ConnCase

  alias Bitblocks.{Chain, ProtocolRegistry}

  setup do
    # Ensure the Twetch protocol is seeded
    case ProtocolRegistry.get_protocol_by_address("19nknDdM3ueaAt7nFLFQ3aS3PVHVnJoMmU") do
      nil ->
        {:ok, _protocol} =
          ProtocolRegistry.create_protocol(%{
            address: "19nknDdM3ueaAt7nFLFQ3aS3PVHVnJoMmU",
            name: "Twetch",
            category: :data_storage,
            verification_status: :verified,
            description: "Twetch social media post protocol."
          })

      _existing ->
        :ok
    end

    :ok
  end

  describe "GET /api/v1/protocols/:address/feed" do
    test "returns 404 for unknown protocol address", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/protocols/1UnknownAddress123456789abcdef/feed")

      assert json_response(conn, 404)["error"] == "Protocol not found"
    end

    test "returns empty feed for protocol with no matching transactions", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/protocols/19nknDdM3ueaAt7nFLFQ3aS3PVHVnJoMmU/feed")

      response = json_response(conn, 200)
      assert response["data"] == []
      assert response["protocol"]["name"] == "Twetch"
      assert response["protocol"]["address"] == "19nknDdM3ueaAt7nFLFQ3aS3PVHVnJoMmU"
      assert response["meta"]["per_page"] == 25
      assert response["meta"]["next_cursor"] == nil
    end

    test "returns transactions matching protocol", %{conn: conn} do
      # Create a block first
      {:ok, _block} =
        Chain.create_block(%{
          hash: "000000000000000001abcdef",
          height: 620001,
          version: "536870912",
          prevblockhash: "000000000000000001abcdee",
          merkleroot: "abc123",
          time: 1_580_448_342,
          bits: "180bab74",
          nonce: 123_456,
          tx: ["txid_twetch_1"],
          size: 1000,
          difficulty: "1.0"
        })

      # Create a transaction tagged with Twetch protocol
      {:ok, _tx} =
        Chain.create_transaction(%{
          txid: "txid_twetch_1",
          raw: "01000000",
          version: "1",
          block_hash: "000000000000000001abcdef",
          block_height: 620_001,
          inputs: ["{}"],
          outputs: ["{}"],
          protocols: ["B://", "MAP", "AIP", "Twetch"]
        })

      conn = get(conn, ~p"/api/v1/protocols/19nknDdM3ueaAt7nFLFQ3aS3PVHVnJoMmU/feed")

      response = json_response(conn, 200)
      assert length(response["data"]) == 1

      item = hd(response["data"])
      assert item["txid"] == "txid_twetch_1"
      assert item["block_height"] == 620_001
    end

    test "respects per_page parameter", %{conn: conn} do
      conn =
        get(
          conn,
          ~p"/api/v1/protocols/19nknDdM3ueaAt7nFLFQ3aS3PVHVnJoMmU/feed?per_page=10"
        )

      response = json_response(conn, 200)
      assert response["meta"]["per_page"] == 10
    end
  end
end
