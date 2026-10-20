defmodule Bitblocks.Script.DescriptorTest do
  use ExUnit.Case, async: true

  alias Bitblocks.Script.Descriptor

  # Real genesis coinbase — its single output is a P2PK.
  @genesis_raw "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"

  test "from_tx builds one descriptor per output with type, hashes and asm" do
    {:ok, tx} = Bitblocks.Chain.SafeTx.from_hex(@genesis_raw)

    assert [descriptor] = Descriptor.from_tx(tx)
    assert descriptor.vout == 0
    assert descriptor.satoshis == 5_000_000_000
    assert descriptor.type == :p2pk
    assert %{type: :p2pk, pubkey: "04678afd" <> _} = descriptor.fields
    assert String.length(descriptor.script_hash) == 64
    assert String.length(descriptor.template_hash) == 64
    assert descriptor.asm =~ "OP_CHECKSIG"
  end

  test "an unknown script degrades to asm fields, never raises" do
    output = %BSV.TxOut{satoshis: 0, script: %BSV.Script{chunks: [:OP_ADD, :OP_EQUAL]}}

    descriptor = Descriptor.from_output(output, 3)

    assert descriptor.vout == 3
    assert descriptor.type == :unknown
    assert %{type: :unknown, asm: _} = descriptor.fields
  end
end
