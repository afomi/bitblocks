defmodule BitblocksWeb.TransactionLive.ShowTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  alias Bitblocks.Script.Templates

  # The genesis coinbase: one P2PK output paying 50 BSV to Satoshi's key.
  @genesis_txid "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
  @genesis_raw "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"
  @genesis_pubkey "04678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5f"

  defp insert_tx(raw, txid) do
    block = block_fixture()

    transaction_fixture(
      txid: txid,
      raw: raw,
      block_hash: block.hash,
      block_height: block.height
    )
  end

  # Serializes a minimal one-input, one-output transaction whose sole output
  # carries the given locking script.
  defp raw_hex_with_output(%BSV.Script{} = script, satoshis) do
    tx = %BSV.Tx{
      version: 1,
      inputs: [
        %BSV.TxIn{
          outpoint: %BSV.OutPoint{hash: :crypto.strong_rand_bytes(32), vout: 0},
          script: %BSV.Script{chunks: []},
          sequence: 0xFFFFFFFF
        }
      ],
      outputs: [%BSV.TxOut{satoshis: satoshis, script: script}],
      lock_time: 0
    }

    BSV.Tx.to_binary(tx, encoding: :hex)
  end

  describe "script cards" do
    test "renders the genesis coinbase with a P2PK card showing the pubkey", %{conn: conn} do
      insert_tx(@genesis_raw, @genesis_txid)

      {:ok, _view, html} = live(conn, ~p"/transactions/#{@genesis_txid}")

      assert html =~ "Output #0"
      assert html =~ "P2PK"
      assert html =~ "Public Key:"
      assert html =~ @genesis_pubkey
      # 50 BSV output value on the card
      assert html =~ "50.00000000 BSV"
      # no registered template for P2PK — no badge
      refute html =~ "Template:"
    end

    test "renders an unknown-script output with its full ASM without crashing", %{conn: conn} do
      script = %BSV.Script{chunks: [:OP_ADD, :OP_EQUAL]}
      raw = raw_hex_with_output(script, 1_000)
      tx = insert_tx(raw, "unknown#{System.unique_integer([:positive])}")

      {:ok, _view, html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert html =~ "Output #0"
      assert html =~ "Locking Script (ASM):"
      assert html =~ "OP_ADD OP_EQUAL"
      refute html =~ "Template:"
    end

    test "shows a template badge when a registered template matches the script", %{conn: conn} do
      digest = :crypto.hash(:sha256, "puzzle")
      script = %BSV.Script{chunks: [:OP_SHA256, digest, :OP_EQUAL]}

      {:ok, _template} =
        Templates.register(%{
          name: "Hash Puzzle",
          template_hash: Bitblocks.Script.template_hash(script)
        })

      raw = raw_hex_with_output(script, 546)
      tx = insert_tx(raw, "templated#{System.unique_integer([:positive])}")

      {:ok, _view, html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert html =~ "Template: Hash Puzzle"
      assert html =~ "OP_SHA256"
    end

    test "renders an OP_RETURN output as a minimal chunk-count card", %{conn: conn} do
      script = %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, "hello", "world"]}
      raw = raw_hex_with_output(script, 0)
      tx = insert_tx(raw, "opreturn#{System.unique_integer([:positive])}")

      {:ok, _view, html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert html =~ "OP_RETURN (2 chunks)"
      # the deep-dive section below the cards still renders the chunk data
      assert html =~ "OP_RETURN Data (1)"
      assert html =~ "hello"
    end

    test "badges an OP_RETURN card with its detected protocol handler", %{conn: conn} do
      script = %BSV.Script{
        chunks: [:OP_FALSE, :OP_RETURN, "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", "SET", "app", "x"]
      }

      raw = raw_hex_with_output(script, 0)
      tx = insert_tx(raw, "opreturnmap#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, ~p"/transactions/#{tx.txid}")

      assert has_element?(view, "span.bg-blue-100", "MAP")
    end
  end
end
