defmodule Bitblocks.BitcomOwnershipTest do
  @moduledoc """
  Bitcom prefix ownership is proven on-chain, not seeded: a `$ useradd
  <address>` counts only when the tx was spent from <address>.
  """
  use Bitblocks.DataCase, async: true

  alias Bitblocks.{Chain, ProtocolRegistry, TransactionParser}
  alias Bitblocks.Chain.Transaction
  alias Bitblocks.Protocol.{Context, Handlers}

  defp address(privkey),
    do:
      privkey |> BSV.PubKey.from_privkey() |> BSV.Address.from_pubkey() |> BSV.Address.to_string()

  # A tx whose first input is a P2PKH spend by `privkey` and whose single
  # output is OP_FALSE OP_RETURN <cells…>.
  defp raw_tx(privkey, cells) do
    pubkey = privkey |> BSV.PubKey.from_privkey() |> BSV.PubKey.to_binary()
    fake_sig = :binary.copy(<<0x30>>, 71)

    input = %BSV.TxIn{
      outpoint: %BSV.OutPoint{hash: :binary.copy(<<9>>, 32), vout: 0},
      script: %BSV.Script{chunks: [fake_sig, pubkey]}
    }

    output = %BSV.TxOut{script: %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN | cells]}}
    BSV.Tx.to_binary(%BSV.Tx{inputs: [input], outputs: [output]}, encoding: :hex)
  end

  defp store(raw) do
    {:ok, analysis} = TransactionParser.analyze(raw)
    {:ok, decoded} = Chain.SafeTx.from_hex(raw)

    attrs =
      Map.merge(
        %{
          txid: BSV.Tx.get_txid(decoded),
          raw: raw,
          version: "1",
          inputs: [],
          outputs: [],
          block_hash: String.duplicate("b", 64)
        },
        analysis
      )

    {:ok, tx} = Repo.insert(Transaction.changeset(%Transaction{}, attrs))
    tx
  end

  describe "Context.first_input_address/1" do
    test "is the P2PKH address that spent the first input" do
      privkey = BSV.PrivKey.new()
      {:ok, tx} = Chain.SafeTx.from_hex(raw_tx(privkey, ["x"]))
      assert Context.first_input_address(tx) == address(privkey)
    end

    test "is nil for a tx with no inputs" do
      assert Context.first_input_address(%BSV.Tx{inputs: [], outputs: []}) == nil
    end
  end

  describe "Bitcom handler" do
    test "detects a `$` command segment, not the substring \"bitcom\"" do
      privkey = BSV.PrivKey.new()
      {:ok, a} = TransactionParser.analyze(raw_tx(privkey, ["$", "useradd", address(privkey)]))
      {:ok, b} = TransactionParser.analyze(raw_tx(privkey, ["i love bitcom"]))

      assert "Bitcom" in a.protocols
      refute "Bitcom" in b.protocols
    end

    test "parse/1 reads the command and args" do
      chunks =
        Bitblocks.Script.OpReturn.parse_data(%BSV.Script{
          chunks: [:OP_FALSE, :OP_RETURN, "$", "useradd", "1abc"]
        })

      assert {:ok, %{command: "useradd", args: ["1abc"]}} = Handlers.parse(chunks, "Bitcom")
    end
  end

  describe "Chain.index_bitcom/1" do
    test "a useradd spent from the claimed address proves ownership of a new prefix" do
      privkey = BSV.PrivKey.new()
      addr = address(privkey)
      tx = store(raw_tx(privkey, ["$", "useradd", addr]))

      assert Chain.index_bitcom(tx) == 1
      assert %{ownership_proof_txid: proof} = ProtocolRegistry.get_protocol_by_address(addr)
      assert proof == tx.txid
    end

    test "a useradd claiming someone else's address proves nothing" do
      victim = address(BSV.PrivKey.new())
      tx = store(raw_tx(BSV.PrivKey.new(), ["$", "useradd", victim]))

      assert Chain.index_bitcom(tx) == 0
      assert ProtocolRegistry.get_protocol_by_address(victim) == nil
    end

    test "proves an already-registered protocol without touching its curation status" do
      privkey = BSV.PrivKey.new()
      addr = address(privkey)

      {:ok, _} =
        ProtocolRegistry.create_protocol(%{
          address: addr,
          name: "Mine",
          verification_status: :beta
        })

      tx = store(raw_tx(privkey, ["$", "useradd", addr]))
      assert Chain.index_bitcom(tx) == 1

      protocol = ProtocolRegistry.get_protocol_by_address(addr)
      assert protocol.ownership_proof_txid == tx.txid
      assert protocol.verification_status == :beta
    end

    test "is a no-op for a tx not tagged Bitcom" do
      tx = store(raw_tx(BSV.PrivKey.new(), ["hello"]))
      assert Chain.index_bitcom(tx) == 0
    end
  end
end
