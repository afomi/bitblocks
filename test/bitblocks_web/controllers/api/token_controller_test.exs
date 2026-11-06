defmodule BitblocksWeb.Api.TokenControllerTest do
  use BitblocksWeb.ConnCase

  alias Bitblocks.Repo
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
      xfer = "cc" <> String.duplicate("0", 62)

      # The transfer spends the mint output.
      Repo.insert!(%Bitblocks.Chain.Spend{
        txid: @txid,
        vout: 0,
        spending_txid: xfer,
        spending_vin: 0
      })

      {:ok, _} = Tokens.index_transfer(transfer_attrs(xfer, alice, token_id, "500"))

      resp = conn |> get(~p"/api/v1/tokens/#{token_id}/holders") |> json_response(200)
      assert [%{"address" => ^alice, "balance" => 500}] = resp["data"]
      assert resp["transfers"] == %{"valid" => 1, "invalid" => 0, "pending" => 0}
    end

    test "a transfer with no input of the token is in no balance, and counted",
         %{conn: conn, token_id: token_id} do
      bob = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
      copy = "cd" <> String.duplicate("0", 62)

      {:ok, view} = Tokens.index_transfer(transfer_attrs(copy, bob, token_id, "500"))
      assert view.validated == false

      resp = conn |> get(~p"/api/v1/tokens/#{token_id}/holders") |> json_response(200)
      assert resp["data"] == []
      assert resp["transfers"] == %{"valid" => 0, "invalid" => 0, "pending" => 1}

      transfers =
        build_conn() |> get(~p"/api/v1/tokens/#{token_id}/transfers") |> json_response(200)

      assert [%{"validated" => false, "status" => "pending"}] = transfers["data"]
    end
  end

  describe "holders on GET /api/v1/tokens/:id" do
    test "a mint with an unspent balance is not holders: 0", %{conn: conn} do
      alice = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
      txid = "ab" <> String.duplicate("0", 62)

      {:ok, token} =
        Tokens.index_token(%{
          txid: txid,
          vout: 0,
          recipient: alice,
          token: %{standard: "bsv-21", op: "deploy+mint", token_id: nil, amt: "10", sym: "ONE"}
        })

      resp = conn |> get(~p"/api/v1/tokens/#{token.token_id}") |> json_response(200)
      assert %{"holders" => 1, "validated" => true, "status" => "valid"} = resp["data"]
    end

    test "says when a mint's recipient is unknown, and names a cosigner", %{conn: conn} do
      token = %{standard: "bsv-21", op: "deploy+mint", token_id: nil, amt: "10", sym: "L"}

      {:ok, other} =
        Tokens.index_token(%{
          txid: "ac" <> String.duplicate("0", 62),
          vout: 0,
          lock: %{type: "other", owner: nil, cosigner: nil},
          token: token
        })

      {:ok, cosign} =
        Tokens.index_token(%{
          txid: "ad" <> String.duplicate("0", 62),
          vout: 0,
          recipient: "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
          lock: %{type: "cosign", owner: "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", cosigner: "02cc"},
          token: token
        })

      assert %{"recipient" => nil, "recipient_status" => "unknown", "lock" => "other"} =
               conn
               |> get(~p"/api/v1/tokens/#{other.token_id}")
               |> json_response(200)
               |> Map.get("data")

      assert %{"recipient_status" => "known", "lock" => "cosign", "cosigner" => "02cc"} =
               conn
               |> get(~p"/api/v1/tokens/#{cosign.token_id}")
               |> json_response(200)
               |> Map.get("data")
    end
  end

  defp transfer_attrs(txid, recipient, token_id, amt) do
    %{
      txid: txid,
      vout: 1,
      recipient: recipient,
      token: %{
        standard: "bsv-21",
        op: "transfer",
        token_id: token_id,
        tick: nil,
        amt: amt,
        max: nil,
        lim: nil,
        dec: nil,
        sym: nil,
        icon: nil
      }
    }
  end

  describe "GET /api/v1/tokens/stats" do
    test "returns aggregate counts", %{conn: conn} do
      resp = conn |> get(~p"/api/v1/tokens/stats") |> json_response(200)
      assert resp["data"]["total_tokens"] == 1
    end
  end
end
