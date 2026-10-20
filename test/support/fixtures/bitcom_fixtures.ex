defmodule Bitblocks.BitcomFixtures do
  @moduledoc """
  Bitcom command transactions: a first input spent by a known key (so the
  command's author is that key's address) and OP_RETURN outputs.
  """

  alias Bitblocks.{Bitcom, Chain, Repo, TransactionParser}
  alias Bitblocks.Chain.Transaction

  def address(privkey),
    do:
      privkey |> BSV.PubKey.from_privkey() |> BSV.Address.from_pubkey() |> BSV.Address.to_string()

  @doc """
  Raw hex of a tx whose first input is a P2PKH spend by `privkey` and with one
  `OP_FALSE OP_RETURN <cells…>` output per cell list. `salt` keeps txids distinct.
  """
  def bitcom_raw_tx(privkey, outputs, salt \\ 9) do
    pubkey = privkey |> BSV.PubKey.from_privkey() |> BSV.PubKey.to_binary()

    input = %BSV.TxIn{
      outpoint: %BSV.OutPoint{hash: :binary.copy(<<salt>>, 32), vout: 0},
      script: %BSV.Script{chunks: [:binary.copy(<<0x30>>, 71), pubkey]}
    }

    outputs =
      Enum.map(outputs, fn cells ->
        %BSV.TxOut{script: %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN | cells]}}
      end)

    BSV.Tx.to_binary(%BSV.Tx{inputs: [input], outputs: outputs}, encoding: :hex)
  end

  @doc "Stores `raw` as an analyzed transaction."
  def store_analyzed_tx(raw, attrs \\ %{}) do
    {:ok, analysis} = TransactionParser.analyze(raw)
    {:ok, decoded} = Chain.SafeTx.from_hex(raw)

    base = %{
      txid: BSV.Tx.get_txid(decoded),
      raw: raw,
      version: "1",
      inputs: [],
      outputs: [],
      block_hash: String.duplicate("b", 64)
    }

    {:ok, tx} =
      %Transaction{}
      |> Transaction.changeset(base |> Map.merge(analysis) |> Map.merge(attrs))
      |> Repo.insert()

    tx
  end

  @doc "Stores and indexes a Bitcom tx; returns `{tx, index_result}`."
  def bitcom_command_fixture(privkey, outputs, opts \\ []) do
    raw = bitcom_raw_tx(privkey, outputs, Keyword.get(opts, :salt, 9))
    tx = store_analyzed_tx(raw, Map.new(Keyword.get(opts, :attrs, %{})))
    {:ok, result} = Bitcom.index(tx)
    {tx, result}
  end
end
