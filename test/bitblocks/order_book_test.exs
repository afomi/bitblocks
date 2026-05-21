defmodule Bitblocks.OrderBookTest do
  use Bitblocks.DataCase

  alias Bitblocks.OrderBook
  alias Bitblocks.ProtocolRegistry

  @test_seller "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
  @test_token_id "abc123def456_0"

  # Ensure the OrderBook protocol is seeded
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

  describe "list_active_listings/1" do
    test "returns active, unspent listings", %{protocol: protocol} do
      _listing = create_listing(protocol)

      listings = OrderBook.list_active_listings()

      assert length(listings) == 1
      listing = hd(listings)
      assert listing.op == "list"
      assert listing.token_id == @test_token_id
      assert listing.status == "active"
      assert listing.spent == false
    end

    test "excludes spent listings", %{protocol: protocol} do
      _active = create_listing(protocol)
      _spent = create_listing(protocol, %{spent: true, state: %{"status" => "cancelled"}})

      listings = OrderBook.list_active_listings()

      assert length(listings) == 1
    end

    test "excludes cancelled listings", %{protocol: protocol} do
      _active = create_listing(protocol)
      _cancelled = create_listing(protocol, %{state: %{"status" => "cancelled"}, spent: true})

      listings = OrderBook.list_active_listings()

      assert length(listings) == 1
    end

    test "filters by token_id", %{protocol: protocol} do
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

      listings = OrderBook.list_active_listings(token_id: @test_token_id)

      assert length(listings) == 1
      assert hd(listings).token_id == @test_token_id
    end

    test "filters by seller_address", %{protocol: protocol} do
      _match = create_listing(protocol)

      _no_match =
        create_listing(protocol, %{
          parsed_data: %{
            "op" => "list",
            "token_id" => @test_token_id,
            "quantity" => "50",
            "price_satoshis" => "1000",
            "seller_address" => "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",
            "token_utxo" => "other:0"
          }
        })

      listings = OrderBook.list_active_listings(seller_address: @test_seller)

      assert length(listings) == 1
      assert hd(listings).seller_address == @test_seller
    end

    test "filters by price range", %{protocol: protocol} do
      _cheap = create_listing(protocol, %{
        parsed_data: %{
          "op" => "list",
          "token_id" => @test_token_id,
          "quantity" => "50",
          "price_satoshis" => "100",
          "seller_address" => @test_seller,
          "token_utxo" => "cheap:0"
        }
      })

      _expensive = create_listing(protocol, %{
        parsed_data: %{
          "op" => "list",
          "token_id" => @test_token_id,
          "quantity" => "50",
          "price_satoshis" => "50000",
          "seller_address" => @test_seller,
          "token_utxo" => "expensive:0"
        }
      })

      listings = OrderBook.list_active_listings(min_price: 1000, max_price: 10000)

      # Neither matches: 100 < 1000, 50000 > 10000
      assert length(listings) == 0

      listings = OrderBook.list_active_listings(min_price: 50, max_price: 200)
      assert length(listings) == 1
      assert hd(listings).price_satoshis == "100"
    end

    test "excludes expired listings", %{protocol: protocol} do
      past = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()

      _expired = create_listing(protocol, %{
        parsed_data: %{
          "op" => "list",
          "token_id" => @test_token_id,
          "quantity" => "50",
          "price_satoshis" => "1000",
          "seller_address" => @test_seller,
          "token_utxo" => "expired:0",
          "expires_at" => past
        }
      })

      listings = OrderBook.list_active_listings()

      assert length(listings) == 0
    end

    test "respects limit option", %{protocol: protocol} do
      for _ <- 1..5, do: create_listing(protocol)

      listings = OrderBook.list_active_listings(limit: 3)

      assert length(listings) == 3
    end
  end

  describe "get_listing/1" do
    test "returns a listing by txid", %{protocol: protocol} do
      instance = create_listing(protocol)

      listing = OrderBook.get_listing(instance.txid)

      assert listing.txid == instance.txid
      assert listing.token_id == @test_token_id
    end

    test "returns nil for unknown txid" do
      assert OrderBook.get_listing("nonexistent") == nil
    end
  end

  describe "cancel_listing/2" do
    test "marks the listing as cancelled and spent", %{protocol: protocol} do
      instance = create_listing(protocol)
      cancel_txid = random_txid()

      assert {:ok, updated} = OrderBook.cancel_listing(instance.txid, cancel_txid)

      assert updated.status == "cancelled"
      assert updated.spent == true
      assert updated.spent_txid == cancel_txid
    end

    test "returns error for unknown listing" do
      assert {:error, :not_found} = OrderBook.cancel_listing("nonexistent", random_txid())
    end
  end

  describe "fill_listing/3" do
    test "partially fills a listing", %{protocol: protocol} do
      instance = create_listing(protocol)
      fill_txid = random_txid()

      assert {:ok, updated} = OrderBook.fill_listing(instance.txid, fill_txid, "30")

      assert updated.status == "partially_filled"
      assert updated.quantity_remaining == "70"
      assert updated.spent == false
      assert length(updated.fills) == 1
    end

    test "fully fills a listing and marks as spent", %{protocol: protocol} do
      instance = create_listing(protocol)
      fill_txid = random_txid()

      assert {:ok, updated} = OrderBook.fill_listing(instance.txid, fill_txid, "100")

      assert updated.status == "filled"
      assert updated.quantity_remaining == "0"
      assert updated.spent == true
      assert updated.spent_txid == fill_txid
    end

    test "returns error for unknown listing" do
      assert {:error, :not_found} = OrderBook.fill_listing("nonexistent", random_txid(), "10")
    end
  end

  describe "index_listing/1" do
    test "creates a protocol instance and returns listing", %{protocol: _protocol} do
      txid = random_txid()

      assert {:ok, listing} =
               OrderBook.index_listing(%{
                 txid: txid,
                 vout: 0,
                 block_height: 500,
                 parsed_data: %{
                   "op" => "list",
                   "token_id" => @test_token_id,
                   "quantity" => "200",
                   "price_satoshis" => "3000",
                   "seller_address" => @test_seller,
                   "token_utxo" => "new:0"
                 }
               })

      assert listing.txid == txid
      assert listing.token_id == @test_token_id
      assert listing.quantity == "200"
      assert listing.status == "active"
    end
  end

  describe "listing_stats/0" do
    test "returns aggregate counts", %{protocol: protocol} do
      _active1 = create_listing(protocol)
      _active2 = create_listing(protocol)
      _cancelled = create_listing(protocol, %{spent: true, state: %{"status" => "cancelled"}})
      _filled = create_listing(protocol, %{spent: true, state: %{"status" => "filled"}})

      stats = OrderBook.listing_stats()

      assert stats.total_active == 2
      assert stats.total_cancelled == 1
      assert stats.total_filled == 1
      assert stats.unique_tokens == 1
    end
  end
end
