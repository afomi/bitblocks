defmodule Bitblocks.Chain.IndexTokensTest do
  @moduledoc """
  End-to-end ingest test for the BSV-20/21 token indexing hook.

  Builds a real raw transaction with an ordinal inscription output, stores it as a
  `Transaction`, and confirms `Chain.index_tokens/1` extracts and indexes the token
  — the same path `FetchTransactionsWorker.store_batch/1` runs on ingest.
  """
  use Bitblocks.DataCase

  alias Bitblocks.{Chain, Tokens, ProtocolRegistry}
  alias Bitblocks.Chain.Transaction

  setup do
    ProtocolRegistry.get_protocol_by_name("BSV20") ||
      raise "BSV20 protocol not seeded — run mix ecto.migrate"

    :ok
  end

  # Build a raw tx (hex) whose single 1-sat output carries a bsv-20 inscription
  # followed by a P2PKH to `pkh`.
  defp inscription_raw(body, pkh) do
    chunks =
      [:OP_FALSE, :OP_IF, "ord", :OP_1, "application/bsv-20", :OP_0, body, :OP_ENDIF] ++
        [:OP_DUP, :OP_HASH160, pkh, :OP_EQUALVERIFY, :OP_CHECKSIG]

    out = %BSV.TxOut{script: %BSV.Script{chunks: chunks}, satoshis: 1}
    tx = %BSV.Tx{version: 1, inputs: [], outputs: [out], lock_time: 0}
    BSV.Tx.to_binary(tx, encoding: :hex)
  end

  # Store a Transaction row the way the worker does: raw + analysis (protocols) +
  # the node-style output JSON (carrying the recipient address).
  defp store_tx(raw, txid, address) do
    {:ok, analysis} = Bitblocks.TransactionParser.analyze(raw)

    outputs = [
      Jason.encode!(%{
        "value" => 0.00000001,
        "scriptPubKey" => %{"addresses" => [address]}
      })
    ]

    attrs =
      Map.merge(
        %{
          txid: txid,
          raw: raw,
          version: "1",
          inputs: [],
          block_height: 500,
          block_hash: "bh" <> String.duplicate("0", 62),
          outputs: outputs
        },
        analysis
      )

    {:ok, tx} = Repo.insert(Transaction.changeset(%Transaction{}, attrs))
    tx
  end

  test "index_tokens indexes a deploy+mint from a real inscription tx" do
    pkh = :binary.copy(<<0xAA>>, 20)
    address = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
    body = ~s({"p":"bsv-20","op":"deploy+mint","amt":"21000000","sym":"MEME"})
    txid = "aa" <> String.duplicate("0", 62)

    tx = store_tx(inscription_raw(body, pkh), txid, address)

    # The tx must have been tagged BSV20 by analyze for the hook to run.
    assert "BSV20" in tx.protocols

    assert Chain.index_tokens(tx) == 1

    token = Tokens.get_token("#{txid}_0")
    assert token.sym == "MEME"
    assert token.supply == "21000000"
    assert token.standard == "bsv-21"
  end

  test "index_tokens is a no-op for a tx not tagged BSV20" do
    tx = %Transaction{protocols: ["B://"], raw: "00", txid: "x"}
    assert Chain.index_tokens(tx) == 0
  end

  test "index_tokens records the recipient so holder balance resolves" do
    pkh = :binary.copy(<<0xBB>>, 20)
    address = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"

    # First a mint to establish the token id.
    mint_txid = "cc" <> String.duplicate("0", 62)
    mint_body = ~s({"p":"bsv-20","op":"deploy+mint","amt":"1000","sym":"HODL"})
    mint_tx = store_tx(inscription_raw(mint_body, pkh), mint_txid, address)
    assert Chain.index_tokens(mint_tx) == 1
    token_id = "#{mint_txid}_0"

    # Then a transfer crediting `address`.
    xfer_txid = "dd" <> String.duplicate("0", 62)
    xfer_body = ~s({"p":"bsv-20","op":"transfer","id":"#{token_id}","amt":"250"})
    xfer_tx = store_tx(inscription_raw(xfer_body, pkh), xfer_txid, address)
    assert Chain.index_tokens(xfer_tx) == 1

    # Balances are net: the mint output is still unspent here, so both count.
    assert Tokens.balance_of(token_id, address) == 1250

    # Once the transfer spends the mint output, only the transfer remains.
    Repo.insert!(%Bitblocks.Chain.Spend{
      txid: mint_txid,
      vout: 0,
      spending_txid: xfer_txid,
      spending_vin: 0
    })

    assert Tokens.balance_of(token_id, address) == 250
  end
end
