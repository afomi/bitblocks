defmodule BitblocksWeb.Api.TokenControllerTest do
  use BitblocksWeb.ConnCase

  alias Bitblocks.Tokens
  alias Bitblocks.ProtocolRegistry

  @txid "aa" <> String.duplicate("0", 62)

  setup do
    ProtocolRegistry.get_protocol_by_name("BSV20") ||
      raise "BSV20 protocol not seeded — run mix ecto.migrate"

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

    %{token_id: token.token_id}
  end

  describe "GET /api/v1/tokens" do
    test "lists indexed tokens", %{conn: conn} do
      resp = conn |> get(~p"/api/v1/tokens") |> json_response(200)
      assert resp["count"] == 1
      assert [%{"sym" => "MEME", "standard" => "bsv-21"}] = resp["data"]
    end

    test "filters by standard", %{conn: conn} do
      resp = conn |> get(~p"/api/v1/tokens?standard=bsv-20") |> json_response(200)
      assert resp["count"] == 0
    end
  end

  describe "GET /api/v1/tokens/:id" do
    test "returns a token by token_id", %{conn: conn, token_id: token_id} do
      resp = conn |> get(~p"/api/v1/tokens/#{token_id}") |> json_response(200)
      assert resp["data"]["token_id"] == token_id
      assert resp["data"]["sym"] == "MEME"
    end

    test "404 for an unknown token", %{conn: conn} do
      unknown = "bb" <> String.duplicate("0", 62) <> "_0"
      resp = conn |> get(~p"/api/v1/tokens/#{unknown}") |> json_response(404)
      assert resp["error"] == "Token not found"
    end

    test "400 for an invalid token reference", %{conn: conn} do
      # Contains characters outside the token_id / ticker charset.
      resp = conn |> get(~p"/api/v1/tokens/not%2Fvalid%20id") |> json_response(400)
      assert resp["error"] == "Invalid token id"
    end
  end

  describe "GET /api/v1/tokens/:id/holders" do
    test "returns holder balances", %{conn: conn, token_id: token_id} do
      alice = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"

      {:ok, _} =
        Tokens.index_transfer(%{
          txid: "cc" <> String.duplicate("0", 62),
          vout: 1,
          recipient: alice,
          token: %{
            standard: "bsv-21",
            op: "transfer",
            token_id: token_id,
            tick: nil,
            amt: "500",
            max: nil,
            lim: nil,
            dec: nil,
            sym: nil,
            icon: nil
          }
        })

      resp = conn |> get(~p"/api/v1/tokens/#{token_id}/holders") |> json_response(200)
      assert [%{"address" => ^alice, "balance" => 500}] = resp["data"]
    end
  end

  describe "GET /api/v1/tokens/stats" do
    test "returns aggregate counts", %{conn: conn} do
      resp = conn |> get(~p"/api/v1/tokens/stats") |> json_response(200)
      assert resp["data"]["total_tokens"] == 1
    end
  end
end
