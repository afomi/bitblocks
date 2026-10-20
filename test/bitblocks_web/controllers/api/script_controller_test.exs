defmodule BitblocksWeb.Api.ScriptControllerTest do
  use BitblocksWeb.ConnCase

  import Bitblocks.ChainFixtures

  alias Bitblocks.Script
  alias Bitblocks.TransactionParser

  # A P2PKH scriptPubKey (hex) and a second instance of the same template with
  # a different pubkey hash — computed against Bitblocks.Script itself so the
  # endpoints and the analyzer can never drift apart.
  @p2pkh_chunks [:OP_DUP, :OP_HASH160, :binary.copy(<<0xAB>>, 20), :OP_EQUALVERIFY, :OP_CHECKSIG]

  defp p2pkh_script, do: %BSV.Script{chunks: @p2pkh_chunks}
  defp p2pkh_hex, do: p2pkh_script() |> BSV.Script.to_binary() |> Base.encode16(case: :lower)

  defp seed_tx_with_script(script, attrs) do
    script_hash = Script.script_hash(script)
    template_hash = Script.template_hash(script)
    hex = script |> BSV.Script.to_binary() |> Base.encode16(case: :lower)

    output = Jason.encode!(%{"value" => 0.5, "n" => 0, "scriptPubKey" => %{"hex" => hex}})

    tx =
      transaction_fixture(
        Map.merge(
          %{
            outputs: [output],
            output_script_hashes: [script_hash],
            output_template_hashes: [template_hash]
          },
          attrs
        )
      )

    {tx, script_hash, template_hash}
  end

  describe "GET /api/v1/script/:scripthash/history" do
    test "returns transactions carrying the script", %{conn: conn} do
      {tx, script_hash, _} = seed_tx_with_script(p2pkh_script(), %{block_height: 500})

      conn = get(conn, ~p"/api/v1/script/#{script_hash}/history")

      assert %{"scripthash" => ^script_hash, "history" => [entry], "source" => "local"} =
               json_response(conn, 200)

      assert entry["txid"] == tx.txid
      assert entry["block_height"] == 500
    end

    test "empty history for an unseen scripthash", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/script/#{String.duplicate("aa", 32)}/history")
      assert %{"history" => []} = json_response(conn, 200)
    end

    test "rejects a malformed scripthash", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/script/not-a-hash/history")
      assert json_response(conn, 400)["error"] =~ "Invalid scripthash"
    end
  end

  describe "GET /api/v1/script/:scripthash/unspent" do
    test "returns unspent outputs, excluding spent ones", %{conn: conn} do
      {tx, script_hash, _} = seed_tx_with_script(p2pkh_script(), %{block_height: 600})

      conn1 = get(conn, ~p"/api/v1/script/#{script_hash}/unspent")

      assert %{"unspent" => [utxo]} = json_response(conn1, 200)
      assert utxo["txid"] == tx.txid
      assert utxo["vout"] == 0
      assert utxo["satoshis"] == 50_000_000

      # Record a spend of that outpoint — it must drop out.
      Bitblocks.Repo.insert!(
        Bitblocks.Chain.Spend.changeset(%Bitblocks.Chain.Spend{}, %{
          txid: tx.txid,
          vout: 0,
          spending_txid: String.duplicate("cd", 32),
          spending_vin: 0
        })
      )

      conn2 = get(build_conn(), ~p"/api/v1/script/#{script_hash}/unspent")
      assert %{"unspent" => []} = json_response(conn2, 200)
    end
  end

  describe "POST /api/v1/script/decode" do
    test "decodes a P2PKH script with type, fields, hashes", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/script/decode", %{"script" => p2pkh_hex()})

      body = json_response(conn, 200)
      assert body["type"] == "p2pkh"
      assert body["fields"]["pubkey_hash"] == String.duplicate("ab", 20)
      assert body["script_hash"] == Script.script_hash(p2pkh_script())
      assert body["template_hash"] == Script.template_hash(p2pkh_script())
      assert body["template"] == nil
      assert body["asm"] =~ "OP_DUP"
    end

    test "reports a registered template match", %{conn: conn} do
      {:ok, _} =
        Bitblocks.Script.Templates.register(%{
          "name" => "p2pkh-standard",
          "template_hash" => Script.template_hash(p2pkh_script()),
          "source" => "test"
        })

      conn = post(conn, ~p"/api/v1/script/decode", %{"script" => p2pkh_hex()})

      assert json_response(conn, 200)["template"]["name"] == "p2pkh-standard"
    end

    test "rejects garbage hex", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/script/decode", %{"script" => "zzzz"})
      assert json_response(conn, 400)["error"] =~ "Invalid script"
    end
  end

  describe "template registry endpoints" do
    test "register → show → history round-trip", %{conn: conn} do
      template_hash = Script.template_hash(p2pkh_script())

      create =
        post(conn, ~p"/api/v1/script/templates", %{
          "name" => "escrow-test",
          "template_hash" => template_hash,
          "body_asm" => "OP_DUP OP_HASH160 <pkh> OP_EQUALVERIFY OP_CHECKSIG",
          "args" => %{"args" => [%{"name" => "pkh", "type" => "hash160"}]},
          "source" => "terms"
        })

      assert json_response(create, 201)["template"]["name"] == "escrow-test"

      show = get(build_conn(), ~p"/api/v1/script/templates/#{template_hash}")
      assert json_response(show, 200)["template"]["template_hash"] == template_hash

      # A tx whose outputs carry this template shows up in template history.
      {tx, _, ^template_hash} = seed_tx_with_script(p2pkh_script(), %{block_height: 700})

      history = get(build_conn(), ~p"/api/v1/script/templates/#{template_hash}/history")
      body = json_response(history, 200)
      assert body["template"]["name"] == "escrow-test"
      assert [%{"txid" => txid}] = body["history"]
      assert txid == tx.txid
    end

    test "rejects an invalid args spec", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/script/templates", %{
          "name" => "bad-args",
          "template_hash" => String.duplicate("ef", 32),
          "args" => %{"args" => [%{"nope" => true}]}
        })

      assert json_response(conn, 422)["errors"]["args"] != nil
    end

    test "unknown template 404s", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/script/templates/#{String.duplicate("00", 32)}")
      assert json_response(conn, 404)
    end
  end

  test "analyze/1 derives the same hashes the endpoints serve" do
    genesis_raw =
      "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"

    assert {:ok, meta} = Bitblocks.TransactionParser.analyze(genesis_raw)
    assert meta.script_analysis_version == TransactionParser.script_analysis_version()
    assert [script_hash] = meta.output_script_hashes
    assert [template_hash] = meta.output_template_hashes
    assert String.length(script_hash) == 64
    assert String.length(template_hash) == 64

    {:ok, tx} = Bitblocks.Chain.SafeTx.from_hex(genesis_raw)
    [output] = tx.outputs
    assert script_hash == Script.script_hash(output.script)
    assert template_hash == Script.template_hash(output.script)
  end
end
