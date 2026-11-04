defmodule Bitblocks.TokensTest do
  use Bitblocks.DataCase

  alias Bitblocks.Tokens
  alias Bitblocks.OrderBook
  alias Bitblocks.ProtocolRegistry

  # The BSV20 protocol is seeded by migration; ensure it exists for the test DB.
  setup do
    protocol =
      ProtocolRegistry.get_protocol_by_name("BSV20") ||
        raise "BSV20 protocol not seeded — run mix ecto.migrate"

    %{protocol: protocol}
  end

  defp mint(overrides \\ %{}) do
    Map.merge(
      %{
        txid: "aa" <> String.duplicate("0", 62),
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
      },
      overrides
    )
  end

  # Records that `spender` spends `txid:vout` (the RecordSpends step does this
  # before tokens are indexed), so the transfer has a token input.
  defp spend!(txid, vout, spender, vin \\ 0) do
    Repo.insert!(%Bitblocks.Chain.Spend{
      txid: txid,
      vout: vout,
      spending_txid: spender,
      spending_vin: vin
    })
  end

  defp transfer(token_id, recipient, amt, txid, vout \\ 1) do
    %{
      txid: txid,
      vout: vout,
      block_height: 101,
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

  describe "index_token/1" do
    test "indexes a deploy+mint and stamps token_id as <txid>_<vout>" do
      attrs = mint()
      assert {:ok, token} = Tokens.index_token(attrs)
      assert token.standard == "bsv-21"
      assert token.op == "deploy+mint"
      assert token.token_id == "#{attrs.txid}_0"
      assert token.sym == "MEME"
      assert token.supply == "21000000"
    end

    test "get_token/1 resolves by token_id" do
      {:ok, token} = Tokens.index_token(mint())
      assert %{sym: "MEME"} = Tokens.get_token(token.token_id)
    end

    test "is idempotent on the same outpoint" do
      assert {:ok, _} = Tokens.index_token(mint())
      assert {:error, _} = Tokens.index_token(mint())
    end
  end

  describe "transfers and holders" do
    test "index_transfer credits recipients and token_holders sums them" do
      {:ok, token} = Tokens.index_token(mint())
      tid = token.token_id
      alice = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
      bob = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
      minter = "1CounterpartyXXXXXXXXXXXXXXXUWLpVr"
      b1 = "b1" <> String.duplicate("0", 62)

      # One tx spends the mint output: 150 to alice over two outputs, 30 to
      # bob, the rest back to the minter.
      spend!(token.txid, 0, b1)
      {:ok, _} = Tokens.index_transfer(transfer(tid, alice, "100", b1, 1))
      {:ok, _} = Tokens.index_transfer(transfer(tid, alice, "50", b1, 2))
      {:ok, _} = Tokens.index_transfer(transfer(tid, bob, "30", b1, 3))
      {:ok, view} = Tokens.index_transfer(transfer(tid, minter, "20999820", b1, 4))
      assert %{validated: true, status: "valid"} = view

      holders = Tokens.token_holders(tid)

      assert [
               %{address: ^minter, balance: 20_999_820},
               %{address: ^alice, balance: 150},
               %{address: ^bob, balance: 30}
             ] = holders

      assert Tokens.balance_of(tid, alice) == 150
      assert Tokens.balance_of(tid, bob) == 30
    end

    test "a transfer with no token input credits no one" do
      {:ok, token} = Tokens.index_token(mint())
      alice = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"

      {:ok, view} =
        Tokens.index_transfer(
          transfer(token.token_id, alice, "100", "b9" <> String.duplicate("0", 62))
        )

      # No input recorded at all: pending, never valid by default.
      assert %{validated: false, status: "pending"} = view
      assert Tokens.token_holders(token.token_id) == []
    end

    test "holders are net: a spent output no longer counts" do
      {:ok, token} = Tokens.index_token(mint())
      tid = token.token_id
      alice = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
      bob = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
      t1 = "c1" <> String.duplicate("0", 62)
      t2 = "c2" <> String.duplicate("0", 62)

      spend!(token.txid, 0, t1)
      {:ok, _} = Tokens.index_transfer(transfer(tid, alice, "100", t1))
      # Alice sends her 100 on to Bob: t2 spends t1:1.
      Repo.insert!(%Bitblocks.Chain.Spend{txid: t1, vout: 1, spending_txid: t2, spending_vin: 0})
      {:ok, _} = Tokens.index_transfer(transfer(tid, bob, "100", t2))

      assert Tokens.balance_of(tid, alice) == 0
      assert Tokens.balance_of(tid, bob) == 100
      assert [%{address: ^bob, balance: 100}] = Tokens.token_holders(tid)
    end
  end

  describe "unspent_outputs/2" do
    test "lists an address's unspent token outputs with mint metadata" do
      {:ok, token} = Tokens.index_token(mint())
      tid = token.token_id
      alice = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
      spent = "d1" <> String.duplicate("0", 62)
      kept = "d2" <> String.duplicate("0", 62)

      bob = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"

      # `spent` splits the mint: 40 to alice, 60 to bob; bob sends his 60 on
      # to alice in `kept`; alice's 40 is then spent elsewhere.
      spend!(token.txid, 0, spent)
      {:ok, _} = Tokens.index_transfer(transfer(tid, alice, "40", spent, 1))
      {:ok, _} = Tokens.index_transfer(transfer(tid, bob, "60", spent, 2))
      spend!(spent, 2, kept)
      {:ok, _} = Tokens.index_transfer(transfer(tid, alice, "60", kept))
      spend!(spent, 1, "ee" <> String.duplicate("0", 62))

      assert [utxo] = Tokens.unspent_outputs(alice, standard: "bsv-21")

      assert %{txid: ^kept, vout: 1, token_id: ^tid, amt: "60", sym: "MEME", dec: "8"} = utxo
      assert Tokens.unspent_outputs(alice, token_id: "nope_0") == []
      assert Tokens.unspent_outputs(alice, standard: "bsv-20") == []
    end

    test "the mint output belongs to its recipient" do
      alice = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
      {:ok, token} = Tokens.index_token(Map.put(mint(), :recipient, alice))

      assert [%{op: "deploy+mint", amt: "21000000"}] = Tokens.unspent_outputs(alice)
      assert Tokens.balance_of(token.token_id, alice) == 21_000_000
    end
  end

  describe "classic BSV-20 (detect-only)" do
    test "index routes a classic deploy to index_classic" do
      attrs = %{
        txid: "cc" <> String.duplicate("0", 62),
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
      }

      assert {:ok, view} = Tokens.index(attrs)
      assert view.standard == "bsv-20"
      assert view.tick == "ordi"
      # get_token resolves classic tokens by ticker too
      assert %{tick: "ordi"} = Tokens.get_token("ordi")
    end
  end

  describe "token_stats/0" do
    test "counts tokens and transfers" do
      {:ok, token} = Tokens.index_token(mint())

      {:ok, _} =
        Tokens.index_transfer(
          transfer(
            token.token_id,
            "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
            "1",
            "d1" <> String.duplicate("0", 62)
          )
        )

      stats = Tokens.token_stats()
      assert stats.total_tokens == 1
      assert stats.total_transfers == 1
    end
  end

  describe "DEX linkage" do
    test "an order-book listing's token_id resolves to an indexed token" do
      # A BSV-21 mint produces token_id "<txid>_<vout>" — exactly the format the
      # order book carries as token_id. Index a token, then list it, and confirm
      # the listing's token_id looks up the real token.
      {:ok, token} = Tokens.index_token(mint())
      tid = token.token_id

      {:ok, _listing} =
        OrderBook.index_listing(%{
          txid: "ee" <> String.duplicate("0", 62),
          vout: 0,
          block_height: 200,
          parsed_data: %{
            "op" => "list",
            "token_id" => tid,
            "quantity" => "100",
            "price_satoshis" => "5000",
            "seller_address" => "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
            "token_utxo" => "ee:0"
          }
        })

      [listing] = OrderBook.list_active_listings(token_id: tid)
      assert Tokens.get_token(listing.token_id).sym == "MEME"
    end
  end
end
