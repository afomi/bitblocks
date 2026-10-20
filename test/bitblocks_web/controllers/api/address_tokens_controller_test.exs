defmodule BitblocksWeb.Api.AddressTokensControllerTest do
  @moduledoc """
  GET /api/v1/addresses/:address/tokens — unspent BSV-21 outputs by address,
  through the real ingest path (stored raw tx → Chain.index_tokens).
  """
  use BitblocksWeb.ConnCase, async: true

  alias Bitblocks.{Chain, Repo}
  alias Bitblocks.Chain.{Spend, Transaction}

  @address "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
  @pkh :binary.copy(<<0xBB>>, 20)

  defp inscription_script(body) do
    %BSV.Script{
      chunks:
        [:OP_FALSE, :OP_IF, "ord", :OP_1, "application/bsv-20", :OP_0, body, :OP_ENDIF] ++
          [:OP_DUP, :OP_HASH160, @pkh, :OP_EQUALVERIFY, :OP_CHECKSIG]
    }
  end

  defp ingest(txid, body) do
    script = inscription_script(body)
    out = %BSV.TxOut{script: script, satoshis: 1}
    raw = BSV.Tx.to_binary(%BSV.Tx{inputs: [], outputs: [out]}, encoding: :hex)
    {:ok, analysis} = Bitblocks.TransactionParser.analyze(raw)

    outputs = [
      Jason.encode!(%{"value" => 0.00000001, "scriptPubKey" => %{"addresses" => [@address]}})
    ]

    attrs =
      Map.merge(
        %{
          txid: txid,
          raw: raw,
          version: "1",
          inputs: [],
          outputs: outputs,
          block_height: 500,
          block_hash: String.duplicate("b", 64)
        },
        analysis
      )

    tx = Repo.insert!(Transaction.changeset(%Transaction{}, attrs))
    assert Chain.index_tokens(tx) == 1
    BSV.Script.to_binary(script, encoding: :hex)
  end

  test "lists unspent BSV-21 outputs with amounts and locking scripts", %{conn: conn} do
    mint_txid = "cc" <> String.duplicate("0", 62)
    xfer_txid = "dd" <> String.duplicate("0", 62)
    token_id = "#{mint_txid}_0"

    ingest(mint_txid, ~s({"p":"bsv-20","op":"deploy+mint","amt":"1000","sym":"HODL","dec":"2"}))

    xfer_script =
      ingest(xfer_txid, ~s({"p":"bsv-20","op":"transfer","id":"#{token_id}","amt":"250"}))

    # The transfer spent the mint output.
    Repo.insert!(%Spend{txid: mint_txid, vout: 0, spending_txid: xfer_txid, spending_vin: 0})

    body =
      conn
      |> get(~p"/api/v1/addresses/#{@address}/tokens?standard=bsv-21")
      |> json_response(200)

    assert %{"meta" => %{"count" => 1, "source" => "local"}, "data" => [utxo]} = body

    assert %{
             "txid" => ^xfer_txid,
             "vout" => 0,
             "token_id" => ^token_id,
             "amt" => "250",
             "sym" => "HODL",
             "dec" => "2",
             "satoshis" => 1,
             "locking_script" => ^xfer_script,
             "height" => 500
           } = utxo
  end

  test "filters by token_id", %{conn: conn} do
    ingest("cc" <> String.duplicate("0", 62), ~s({"p":"bsv-20","op":"deploy+mint","amt":"5"}))

    body =
      conn
      |> get("/api/v1/addresses/#{@address}/tokens", token_id: String.duplicate("e", 64) <> "_0")
      |> json_response(200)

    assert body["data"] == []
  end

  test "400 on bad address, standard, or token_id", %{conn: conn} do
    assert conn |> get(~p"/api/v1/addresses/notanaddress/tokens") |> json_response(400)

    assert build_conn()
           |> get(~p"/api/v1/addresses/#{@address}/tokens?standard=erc-20")
           |> json_response(400)

    assert build_conn()
           |> get("/api/v1/addresses/#{@address}/tokens", token_id: "../../x")
           |> json_response(400)
  end
end
