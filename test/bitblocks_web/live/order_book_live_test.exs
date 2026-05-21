defmodule BitblocksWeb.OrderBookLiveTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest

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
            "token_utxo" => "abc123:0"
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

  test "renders the order book page with empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/order-book")

    assert html =~ "Open Order Book"
    assert html =~ "No active listings"
  end

  test "renders listings table when listings exist", %{conn: conn, protocol: protocol} do
    _listing = create_listing(protocol)

    {:ok, _view, html} = live(conn, "/order-book")

    assert html =~ "Open Order Book"
    assert html =~ @test_token_id
    assert html =~ "5,000"
    assert html =~ "active"
  end

  test "displays stats banner", %{conn: conn, protocol: protocol} do
    _listing = create_listing(protocol)

    {:ok, _view, html} = live(conn, "/order-book")

    assert html =~ "Active Listings"
    assert html =~ "Trades Completed"
    assert html =~ "Unique Tokens"
  end

  test "filters listings by token_id", %{conn: conn, protocol: protocol} do
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

    {:ok, view, _html} = live(conn, "/order-book")

    rendered =
      view
      |> element("form")
      |> render_change(%{"token_id" => @test_token_id, "seller" => "", "min_price" => "", "max_price" => ""})

    assert rendered =~ @test_token_id
    refute rendered =~ "other_token_0"
  end

  test "shows empty state when filters match nothing", %{conn: conn, protocol: protocol} do
    _listing = create_listing(protocol)

    {:ok, view, _html} = live(conn, "/order-book")

    rendered =
      view
      |> element("form")
      |> render_change(%{"token_id" => "nonexistent", "seller" => "", "min_price" => "", "max_price" => ""})

    assert rendered =~ "No active listings"
  end

  test "clear filters restores all listings", %{conn: conn, protocol: protocol} do
    _listing = create_listing(protocol)

    {:ok, view, _html} = live(conn, "/order-book")

    # Apply filter that hides listings
    view
    |> element("form")
    |> render_change(%{"token_id" => "nonexistent", "seller" => "", "min_price" => "", "max_price" => ""})

    # Clear filters
    rendered =
      view
      |> element("button", "Clear Filters")
      |> render_click()

    assert rendered =~ @test_token_id
  end

  test "displays API reference section", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/order-book")

    assert html =~ "Order Book API"
    assert html =~ "/api/v1/order-book/listings"
    assert html =~ "/api/v1/stream/order-book"
  end
end
