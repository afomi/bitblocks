defmodule Bitblocks.Chain.RawTxTest do
  use ExUnit.Case, async: true

  alias Bitblocks.Chain.RawTx

  test "decodes like BSV.Tx when every script parses" do
    {_txid, hex} =
      Bitblocks.OrdinalFixtures.tx(
        [Bitblocks.OrdinalFixtures.funding_outpoint()],
        [Bitblocks.OrdinalFixtures.p2pkh(Bitblocks.OrdinalFixtures.address(), 5_000)]
      )

    {:ok, expected} = BSV.Tx.from_binary(hex, encoding: :hex)
    assert {:ok, tx} = RawTx.parse(hex)
    assert tx.outputs == expected.outputs
    assert Enum.map(tx.inputs, & &1.outpoint) == Enum.map(expected.inputs, & &1.outpoint)
  end

  test "keeps the readable chunks of a script that BSV.Tx can't parse" do
    # P2PKH-ish prefix, then an 11-byte push with only 2 bytes left.
    script = <<0x76, 0xA9, 0x0B, 1, 2>>

    raw =
      <<1::little-32, 1, :binary.copy(<<7>>, 32)::binary, 0::little-32, 0, 0xFFFFFFFF::little-32,
        1, 1::little-64, byte_size(script), script::binary, 0::little-32>>

    hex = Base.encode16(raw, case: :lower)
    assert {:error, _} = Bitblocks.Chain.SafeTx.from_hex(hex)

    assert {:ok, %BSV.Tx{outputs: [%BSV.TxOut{satoshis: 1, script: s}]}} = RawTx.parse(hex)
    assert s.chunks == [:OP_DUP, :OP_HASH160, <<0x0B, 1, 2>>]
  end

  test "rejects truncated or non-hex input" do
    assert {:error, :invalid_tx} = RawTx.parse("zz")
    assert {:error, :invalid_tx} = RawTx.parse("01000000")
  end
end
