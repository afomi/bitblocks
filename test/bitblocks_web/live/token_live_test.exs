defmodule BitblocksWeb.TokenLiveTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Bitblocks.Tokens
  alias Bitblocks.ProtocolRegistry

  @txid "aa" <> String.duplicate("0", 62)

  setup do
    ProtocolRegistry.get_protocol_by_name("BSV20") ||
      raise "BSV20 protocol not seeded — run mix ecto.migrate"

    :ok
  end

  defp index_meme do
    {:ok, token} =
      Tokens.index_token(%{
        txid: @txid,
        vout: 0,
        block_height: 100,
        token: %{
          standard: "bsv-21",
          op: "deploy+mint",
          token_id: nil,
          tick: nil,
          amt: "21000000",
          max: "21000000",
          lim: nil,
          dec: "8",
          sym: "MEME",
          icon: nil
        }
      })

    token
  end

  describe "list view" do
    test "renders indexed tokens", %{conn: conn} do
      index_meme()

      {:ok, _view, html} = live(conn, ~p"/tokens")
      assert html =~ "Tokens"
      assert html =~ "MEME"
      assert html =~ "bsv-21"
    end

    test "shows an empty state when no tokens", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/tokens")
      assert html =~ "No tokens indexed yet"
    end

    test "live-updates when a new token is broadcast", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tokens")

      index_meme()

      assert render(view) =~ "MEME"
    end
  end

  describe "detail view" do
    test "renders a token's supply and holders", %{conn: conn} do
      token = index_meme()

      {:ok, _} =
        Tokens.index_transfer(%{
          txid: "cc" <> String.duplicate("0", 62),
          vout: 1,
          recipient: "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
          token: %{
            standard: "bsv-21",
            op: "transfer",
            token_id: token.token_id,
            tick: nil,
            amt: "500",
            max: nil,
            lim: nil,
            dec: nil,
            sym: nil,
            icon: nil
          }
        })

      {:ok, _view, html} = live(conn, ~p"/tokens/#{token.token_id}")
      assert html =~ "MEME"
      assert html =~ "Holders"
      assert html =~ "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
      assert html =~ "500"
    end

    test "shows not-found for an unknown token", %{conn: conn} do
      unknown = "ff" <> String.duplicate("0", 62) <> "_0"
      {:ok, _view, html} = live(conn, ~p"/tokens/#{unknown}")
      assert html =~ "Token not found"
    end
  end

  describe "cross-link from order book" do
    test "an order-book listing links to the token page", %{conn: conn} do
      token = index_meme()

      {:ok, _} =
        Bitblocks.OrderBook.index_listing(%{
          txid: "ee" <> String.duplicate("0", 62),
          vout: 0,
          block_height: 200,
          parsed_data: %{
            "op" => "list",
            "token_id" => token.token_id,
            "quantity" => "100",
            "price_satoshis" => "5000",
            "seller_address" => "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
            "token_utxo" => "ee:0"
          }
        })

      {:ok, _view, html} = live(conn, ~p"/order-book")
      assert html =~ ~s(href="/tokens/#{token.token_id}")
    end
  end
end
