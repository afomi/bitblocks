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
          height: 620_001,
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

    test "orders by confirmation; a later insert at a lower height stays down (#35)",
         %{conn: conn} do
      feed = ~p"/api/v1/protocols/19nknDdM3ueaAt7nFLFQ3aS3PVHVnJoMmU/feed"

      for {txid, height} <- [{"tx_a", 700}, {"tx_c", 700}, {"tx_b", 500}] do
        twetch_tx(txid, height)
      end

      first = conn |> get(feed <> "?per_page=2") |> json_response(200)
      assert Enum.map(first["data"], & &1["txid"]) == ["tx_c", "tx_a"]
      assert first["meta"]["next_cursor"] == "700:tx_a"

      # A backfill reaches an old block: a new id, a low height.
      twetch_tx("tx_old", 100)

      assert ["tx_c", "tx_a"] ==
               conn
               |> get(feed <> "?per_page=2")
               |> json_response(200)
               |> Map.fetch!("data")
               |> Enum.map(& &1["txid"])

      rest = conn |> get(feed <> "?cursor=700:tx_a") |> json_response(200)
      assert Enum.map(rest["data"], & &1["txid"]) == ["tx_b", "tx_old"]
      assert rest["meta"]["next_cursor"] == nil
    end

    test "a tx that fails to parse keeps its position, with parse_error (#35)", %{conn: conn} do
      twetch_tx("tx_bad", 700, "zz")
      twetch_tx("tx_lower", 600, "zz")

      body =
        conn
        |> get(~p"/api/v1/protocols/19nknDdM3ueaAt7nFLFQ3aS3PVHVnJoMmU/feed?per_page=1")
        |> json_response(200)

      assert [%{"txid" => "tx_bad", "parse_error" => error} = item] = body["data"]
      assert is_binary(error) and error != ""
      refute Map.has_key?(item, "parsed")
      assert body["meta"]["next_cursor"] == "700:tx_bad"
    end

    test "meta.complete is false until every block to the snapshot is completed", %{conn: conn} do
      feed = ~p"/api/v1/protocols/19nknDdM3ueaAt7nFLFQ3aS3PVHVnJoMmU/feed"

      block_fixture_at(0, "completed")
      block_fixture_at(1, "header_only")

      meta = conn |> get(feed) |> json_response(200) |> Map.fetch!("meta")
      assert meta["complete"] == false
      assert meta["snapshot_height"] == 1
      assert meta["indexed_through_height"] == 0

      Bitblocks.Repo.update_all(Bitblocks.Chain.Block, set: [sync_state: "completed"])

      meta = conn |> get(feed) |> json_response(200) |> Map.fetch!("meta")
      assert meta["complete"] == true
      assert meta["indexed_through_height"] == 1
    end

    test "a stale or malformed cursor is refused", %{conn: conn} do
      feed = ~p"/api/v1/protocols/19nknDdM3ueaAt7nFLFQ3aS3PVHVnJoMmU/feed"

      assert conn |> get(feed <> "?cursor=12345") |> json_response(400)
      assert conn |> get(feed <> "?cursor=x:y") |> json_response(400)
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

  defp twetch_tx(txid, height, raw \\ "01000000") do
    {:ok, tx} =
      Chain.create_transaction(%{
        txid: txid,
        raw: raw,
        version: "1",
        block_hash: "hash_#{height}",
        block_height: height,
        inputs: ["{}"],
        outputs: ["{}"],
        protocols: ["Twetch"]
      })

    tx
  end

  defp block_fixture_at(height, state) do
    {:ok, block} =
      Chain.create_block(%{
        hash: "feedblock_#{height}",
        height: height,
        version: "1",
        prevblockhash: "p",
        merkleroot: "m",
        time: 1,
        bits: "1d00ffff",
        nonce: 1,
        tx: [],
        size: 1,
        difficulty: "1.0",
        sync_state: state
      })

    block
  end
end
