defmodule Bitblocks.ScriptTest do
  use ExUnit.Case, async: true

  alias Bitblocks.Script

  # 20-byte / 32-byte / 33-byte stand-ins for hashes and keys.
  @pkh :binary.copy(<<0xAB>>, 20)
  @sh :binary.copy(<<0xCD>>, 20)
  @pubkey33 <<0x02>> <> :binary.copy(<<0x11>>, 32)
  @pubkey65 <<0x04>> <> :binary.copy(<<0x22>>, 64)

  defp script(chunks), do: %BSV.Script{chunks: chunks}

  describe "classify/1" do
    test "p2pkh" do
      assert Script.classify(script([:OP_DUP, :OP_HASH160, @pkh, :OP_EQUALVERIFY, :OP_CHECKSIG])) ==
               :p2pkh
    end

    test "p2sh" do
      assert Script.classify(script([:OP_HASH160, @sh, :OP_EQUAL])) == :p2sh
    end

    test "p2pk with compressed and uncompressed keys" do
      assert Script.classify(script([@pubkey33, :OP_CHECKSIG])) == :p2pk
      assert Script.classify(script([@pubkey65, :OP_CHECKSIG])) == :p2pk
    end

    test "op_return, bare and OP_FALSE-prefixed" do
      assert Script.classify(script([:OP_RETURN, "data"])) == :op_return
      assert Script.classify(script([:OP_FALSE, :OP_RETURN, "data"])) == :op_return
    end

    test "2-of-3 multisig" do
      chunks = [:OP_2, @pubkey33, @pubkey33, @pubkey33, :OP_3, :OP_CHECKMULTISIG]
      assert Script.classify(script(chunks)) == :multisig
    end

    test "anything else is unknown" do
      assert Script.classify(script([:OP_ADD, :OP_EQUAL])) == :unknown
      assert Script.classify(script(["just-data"])) == :unknown
    end
  end

  describe "extract_fields/1" do
    test "p2pkh pubkey hash" do
      fields =
        Script.extract_fields(script([:OP_DUP, :OP_HASH160, @pkh, :OP_EQUALVERIFY, :OP_CHECKSIG]))

      assert fields == %{type: :p2pkh, pubkey_hash: Base.encode16(@pkh, case: :lower)}
    end

    test "multisig m, n and pubkeys" do
      chunks = [:OP_2, @pubkey33, @pubkey65, @pubkey33, :OP_3, :OP_CHECKMULTISIG]
      fields = Script.extract_fields(script(chunks))

      assert fields.type == :multisig
      assert fields.m == 2
      assert fields.n == 3
      assert length(fields.pubkeys) == 3
    end

    test "unknown falls back to asm" do
      fields = Script.extract_fields(script([:OP_ADD, :OP_EQUAL]))
      assert fields.type == :unknown
      assert is_binary(fields.asm)
    end
  end

  describe "script_hash/1 (Electrum/WhatsOnChain convention)" do
    test "is sha256 of the script bytes, byte-reversed, lowercase hex" do
      s = script([:OP_DUP, :OP_HASH160, @pkh, :OP_EQUALVERIFY, :OP_CHECKSIG])

      expected =
        :crypto.hash(:sha256, BSV.Script.to_binary(s))
        |> :binary.bin_to_list()
        |> Enum.reverse()
        |> :binary.list_to_bin()
        |> Base.encode16(case: :lower)

      assert Script.script_hash(s) == expected
      assert String.length(Script.script_hash(s)) == 64
    end

    test "differs for different scripts" do
      a = script([:OP_DUP, :OP_HASH160, @pkh, :OP_EQUALVERIFY, :OP_CHECKSIG])
      b = script([:OP_DUP, :OP_HASH160, @sh, :OP_EQUALVERIFY, :OP_CHECKSIG])
      refute Script.script_hash(a) == Script.script_hash(b)
    end
  end

  describe "template_hash/1" do
    test "same template with different push-data args hashes identically" do
      a = script([:OP_DUP, :OP_HASH160, @pkh, :OP_EQUALVERIFY, :OP_CHECKSIG])
      b = script([:OP_DUP, :OP_HASH160, @sh, :OP_EQUALVERIFY, :OP_CHECKSIG])
      assert Script.template_hash(a) == Script.template_hash(b)
    end

    test "args of different lengths still share the template" do
      a = script([@pubkey33, :OP_CHECKSIG])
      b = script([@pubkey65, :OP_CHECKSIG])
      assert Script.template_hash(a) == Script.template_hash(b)
    end

    test "different opcode structure hashes differently" do
      a = script([:OP_DUP, :OP_HASH160, @pkh, :OP_EQUALVERIFY, :OP_CHECKSIG])
      b = script([:OP_HASH160, @pkh, :OP_EQUAL])
      refute Script.template_hash(a) == Script.template_hash(b)
    end

    # Golden vectors: template_hash is a cross-project id (qart Holdings, the
    # mobile pack manifest). It must not drift with script_analysis_version or
    # a BSV library upgrade — if one of these fails, the canonical form changed.
    test "P2PKH template hash is pinned, parsed from raw bytes" do
      raw = <<0x76, 0xA9, 0x14>> <> :binary.copy(<<1>>, 20) <> <<0x88, 0xAC>>

      assert Script.template_hash(BSV.Script.from_binary!(raw)) ==
               "09507a7ca50f690592bd1c63b0c826f82e835c4b68d967aea9c5e2c4e666b2d5"
    end

    test "OP_FALSE OP_RETURN <data> template hash is pinned, parsed from raw bytes" do
      raw = <<0x00, 0x6A, 0x02, 0xAB, 0xCD>>

      assert Script.template_hash(BSV.Script.from_binary!(raw)) ==
               "c1418b7f3f39a5c483fd51a1be115b68dfcbf1a12ef315badc83d156b755ffbf"
    end

    test "small-int opcodes are structure, not PUSH placeholders" do
      one_of_one = BSV.Script.from_binary!(<<0x51, 0x21>> <> @pubkey33 <> <<0x51, 0xAE>>)
      two_of_two = BSV.Script.from_binary!(<<0x52, 0x21>> <> @pubkey33 <> <<0x52, 0xAE>>)
      refute Script.template_hash(one_of_one) == Script.template_hash(two_of_two)
    end
  end
end
