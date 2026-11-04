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
      assert html =~ ~s(href="/types/bsv-21")
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

      # The transfer spends the mint output.
      Bitblocks.Repo.insert!(%Bitblocks.Chain.Spend{
        txid: @txid,
        vout: 0,
        spending_txid: "cc" <> String.duplicate("0", 62),
        spending_vin: 0
      })

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

    test "a classic BSV-20 deploy shows max as max, not as Supply", %{conn: conn} do
      {:ok, _} =
        Tokens.index(%{
          txid: "dc" <> String.duplicate("0", 62),
          vout: 0,
          token: %{
            standard: "bsv-20",
            op: "deploy",
            token_id: nil,
            tick: "ordi",
            amt: nil,
            max: "21000000",
            lim: "1000",
            dec: nil,
            sym: nil,
            icon: nil
          }
        })

      {:ok, view, _html} = live(conn, ~p"/tokens/ordi")

      refute has_element?(view, "#token-supply")
      assert has_element?(view, "#token-max", "Max (deploy)")
      assert has_element?(view, "#token-max", "21,000,000")
    end

    test "the standard badge links to the standard's type page", %{conn: conn} do
      token = index_meme()

      {:ok, view, _html} = live(conn, ~p"/tokens/#{token.token_id}")

      assert has_element?(view, ~s(a#token-standard[href="/types/bsv-21"]), "bsv-21")
    end

    test "shows not-found for an unknown token", %{conn: conn} do
      unknown = "ff" <> String.duplicate("0", 62) <> "_0"
      {:ok, _view, html} = live(conn, ~p"/tokens/#{unknown}")
      assert html =~ "Token not found"
    end

    test "a token with no listings says so", %{conn: conn} do
      token = index_meme()

      {:ok, _view, html} = live(conn, ~p"/tokens/#{token.token_id}")

      assert html =~ "There are no open listings."
    end

    test "a token with listings links to the filtered order book", %{conn: conn} do
      token = index_meme()

      {:ok, _} =
        Bitblocks.OrderBook.index_listing(%{
          txid: "bb" <> String.duplicate("1", 62),
          vout: 0,
          block_height: 210,
          parsed_data: %{
            "op" => "list",
            "token_id" => token.token_id,
            "quantity" => "10",
            "price_satoshis" => "100",
            "seller_address" => "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
            "token_utxo" => "bb:0"
          }
        })

      {:ok, _view, html} = live(conn, ~p"/tokens/#{token.token_id}")

      assert html =~ "/order-book?token_id=#{token.token_id}"
      refute html =~ "There are no open listings."
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
