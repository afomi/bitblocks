defmodule BitblocksWeb.Api.OrderBookControllerTest do
  use BitblocksWeb.ConnCase

  alias Bitblocks.ProtocolRegistry

  @test_seller "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
  @test_token_id "abc123def456_0"

  setup do
    case ProtocolRegistry.get_protocol_by_name("OrderBook") do
      nil ->
        {:ok, protocol} =
          ProtocolRegistry.create_protocol(%{
            address: "orderbook",
            name: "OrderBook",
            category: :multi_party,
            verification_status: :verified,
            description: "Open Order Book protocol"
          })

        %{protocol: protocol}

      protocol ->
        %{protocol: protocol}
    end
  end

  defp create_listing(protocol, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          protocol_id: protocol.id,
          txid: random_txid(),
          vout: 0,
          block_height: 100,
          parsed_data: %{
            "op" => "list",
            "token_id" => @test_token_id,
            "quantity" => "100",
            "price_satoshis" => "5000",
            "seller_address" => @test_seller,
            "token_utxo" => "abc123:0",
            "expires_at" => nil,
            "min_quantity" => nil
          },
          state: %{"status" => "active", "quantity_remaining" => "100"},
          spent: false
        },
        overrides
      )

    {:ok, instance} = ProtocolRegistry.create_instance(attrs)
    instance
  end

  defp random_txid do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  describe "GET /api/v1/order-book/listings" do
    test "returns active listings as JSON", %{conn: conn, protocol: protocol} do
      _listing = create_listing(protocol)

      conn = get(conn, ~p"/api/v1/order-book/listings")

      response = json_response(conn, 200)
      assert response["count"] == 1
      assert length(response["data"]) == 1

      listing = hd(response["data"])
      assert listing["token_id"] == @test_token_id
      assert listing["quantity"] == "100"
      assert listing["price_satoshis"] == "5000"
      assert listing["seller_address"] == @test_seller
      assert listing["status"] == "active"
    end

    test "filters by token_id", %{conn: conn, protocol: protocol} do
      _match = create_listing(protocol)

      _no_match =
        create_listing(protocol, %{
          parsed_data: %{
            "op" => "list",
            "token_id" => "other_token_0",
            "quantity" => "50",
            "price_satoshis" => "1000",
            "seller_address" => @test_seller,
            "token_utxo" => "other:0"
          }
        })

      conn = get(conn, ~p"/api/v1/order-book/listings?token_id=#{@test_token_id}")

      response = json_response(conn, 200)
      assert response["count"] == 1
      assert hd(response["data"])["token_id"] == @test_token_id
    end

    test "returns empty list when no listings", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/order-book/listings")

      response = json_response(conn, 200)
      assert response["count"] == 0
      assert response["data"] == []
    end
  end

  describe "GET /api/v1/order-book/listings/:txid" do
    test "returns listing details", %{conn: conn, protocol: protocol} do
      instance = create_listing(protocol)

      conn = get(conn, ~p"/api/v1/order-book/listings/#{instance.txid}")

      response = json_response(conn, 200)
      assert response["data"]["txid"] == instance.txid
      assert response["data"]["token_id"] == @test_token_id
    end

    test "returns 404 for unknown txid", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/order-book/listings/nonexistent")

      assert json_response(conn, 404)["error"] =~ "not found"
    end
  end

  describe "GET /api/v1/order-book/tokens/:token_id" do
    test "returns listings for a specific token", %{conn: conn, protocol: protocol} do
      _listing = create_listing(protocol)

      conn = get(conn, ~p"/api/v1/order-book/tokens/#{@test_token_id}")

      response = json_response(conn, 200)
      assert response["token_id"] == @test_token_id
      assert response["count"] == 1
    end

    test "returns empty for unknown token", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/order-book/tokens/unknown_token")

      response = json_response(conn, 200)
      assert response["count"] == 0
    end
  end

  describe "GET /api/v1/order-book/sellers/:address" do
    test "returns listings by seller", %{conn: conn, protocol: protocol} do
      _listing = create_listing(protocol)

      conn = get(conn, ~p"/api/v1/order-book/sellers/#{@test_seller}")

      response = json_response(conn, 200)
      assert response["seller_address"] == @test_seller
      assert response["count"] == 1
    end
  end

  describe "GET /api/v1/order-book/tokens/:token_id/market" do
    test "returns a market summary as JSON", %{conn: conn, protocol: protocol} do
      create_listing(protocol, %{
        parsed_data: %{
          "op" => "list",
          "token_id" => @test_token_id,
          "quantity" => "100",
          "price_satoshis" => "5000",
          "seller_address" => @test_seller,
          "token_utxo" => "filled:0"
        },
        state: %{
          "status" => "filled",
          "quantity_remaining" => "0",
          "fills" => [%{"txid" => random_txid(), "quantity" => "100"}]
        },
        spent: true
      })

      _active = create_listing(protocol)

      conn = get(conn, ~p"/api/v1/order-book/tokens/#{@test_token_id}/market")

      response = json_response(conn, 200)
      assert response["token_id"] == @test_token_id
      assert response["data"]["total_volume"] == 500_000
      assert response["data"]["num_trades"] == 1
      assert response["data"]["num_active_listings"] == 1
      assert response["data"]["floor_price"] == 5000
    end
  end

  describe "GET /api/v1/order-book/tokens/:token_id/trades" do
    test "returns recent trades as JSON", %{conn: conn, protocol: protocol} do
      create_listing(protocol, %{
        parsed_data: %{
          "op" => "list",
          "token_id" => @test_token_id,
          "quantity" => "100",
          "price_satoshis" => "5000",
          "seller_address" => @test_seller,
          "token_utxo" => "filled:0"
        },
        state: %{
          "status" => "filled",
          "quantity_remaining" => "0",
          "fills" => [
            %{"txid" => "trade_1", "quantity" => "40"},
            %{"txid" => "trade_2", "quantity" => "60"}
          ]
        },
        spent: true
      })

      conn = get(conn, ~p"/api/v1/order-book/tokens/#{@test_token_id}/trades")

      response = json_response(conn, 200)
      assert response["token_id"] == @test_token_id
      assert response["count"] == 2

      trade = hd(response["data"])
      assert trade["price_satoshis"] == 5000
      assert trade["total_satoshis"] == trade["quantity"] * trade["price_satoshis"]
    end

    test "returns empty for a token with no fills", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/order-book/tokens/no_fills_token/trades")

      response = json_response(conn, 200)
      assert response["count"] == 0
      assert response["data"] == []
    end
  end

  describe "GET /api/v1/order-book/stats" do
    test "returns aggregate statistics", %{conn: conn, protocol: protocol} do
      _active = create_listing(protocol)
      _cancelled = create_listing(protocol, %{spent: true, state: %{"status" => "cancelled"}})

      conn = get(conn, ~p"/api/v1/order-book/stats")

      response = json_response(conn, 200)
      assert response["data"]["total_active"] == 1
      assert response["data"]["total_cancelled"] == 1
    end
  end
end
