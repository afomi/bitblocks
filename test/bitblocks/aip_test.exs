defmodule Bitblocks.AipTest do
  @moduledoc """
  AIP verification parity with qart. The recorded vector was produced by an
  independent signer, `@1sat/actions` (the Yours Wallet path), and is the same
  one qart verifies in `test/qart/protocol/aip_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Bitblocks.Aip
  alias Bitblocks.Protocol.Handlers

  # OP_FALSE OP_RETURN <5 receipt fields> | AIP BITCOIN_ECDSA <addr> <65-byte sig>
  @one_sat_signed_script "006a2068747470733a2f2f7279616e776f6c642e6e65742f72656365697074732f76310673686132353640653432336638363830393462343766666335623635663263396662336238663534356465343931323461666663336435313932343463326231376361303939623368747470733a2f2f7279616e776f6c642e6e65742f7279616e2d776f6c642f3230323630393235543132303030305a2e7663660a746578742f7663617264017c22313550636948473232534e4c514a584d6f53556157566937575371633768436676610d424954434f494e5f4543445341213166397473564c577053424c584841353834536355463472483276684c38395a544120c59f5723e53ce0d55a71b0104bf8f92d9e5565a51b396de94a5703c2c9a44976260faa9be87fda5127a49e92bbfe8e4375acbfcc86e93942c601313863e23b15"
  @one_sat_signer "1f9tsVLWpSBLXHA584ScUF4rH2vhL89ZT"
  @one_sat_digest "e423f868094b47ffc5b65f2c9fb3b8f545de49124affc3d519244c2b17ca099b"

  defp chunks(hex), do: BSV.Script.from_binary!(hex, encoding: :hex).chunks

  defp sign(fields, privkey) do
    address = privkey |> BSV.PubKey.from_privkey() |> BSV.Address.from_pubkey()
    sig = BSV.Message.sign(<<0x6A>> <> Enum.join(fields) <> "|", privkey)
    fields ++ ["|", Aip.prefix(), "BITCOIN_ECDSA", BSV.Address.to_string(address), sig]
  end

  describe "recorded vector from @1sat/actions (qart parity)" do
    test "verifies against the signer address" do
      assert {:ok, @one_sat_signer} = Aip.verify(chunks(@one_sat_signed_script))
      assert Aip.verified_signers(chunks(@one_sat_signed_script)) == [@one_sat_signer]
    end

    test "tampering with a signed field invalidates it" do
      tampered =
        @one_sat_signed_script
        |> chunks()
        |> Enum.map(fn
          @one_sat_digest -> String.duplicate("0", 64)
          cell -> cell
        end)

      assert {:error, :invalid_signature} = Aip.verify(tampered)
      assert Aip.verified_signers(tampered) == []
    end
  end

  describe "spec base64 signatures" do
    test "verify a freshly signed MAP-style payload" do
      privkey = BSV.PrivKey.new()
      signed = sign(["1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", "SET", "app", "qart"], privkey)
      address = privkey |> BSV.PubKey.from_privkey() |> BSV.Address.from_pubkey()
      assert {:ok, signer} = Aip.verify([:OP_FALSE, :OP_RETURN | signed])
      assert signer == BSV.Address.to_string(address)
    end

    test "a signature claiming someone else's address is invalid" do
      signed = sign(["hello"], BSV.PrivKey.new())
      other = BSV.PrivKey.new() |> BSV.PubKey.from_privkey() |> BSV.Address.from_pubkey()
      forged = List.replace_at(signed, -2, BSV.Address.to_string(other))
      assert {:error, :invalid_signature} = Aip.verify(forged)
    end

    test "no AIP section" do
      assert {:error, :no_aip} = Aip.verify(["hello", "world"])
      assert Aip.signatures(["hello"]) == []
    end

    test "a truncated AIP section is invalid, not a crash" do
      assert [%{valid: false}] = Aip.signatures(["x", "|", Aip.prefix(), "BITCOIN_ECDSA"])
    end
  end

  describe "AIP handler parse/1" do
    test "parses OpReturn chunk maps and reports the verified signer" do
      script = BSV.Script.from_binary!(@one_sat_signed_script, encoding: :hex)
      data_chunks = Bitblocks.Script.OpReturn.parse_data(script)

      assert {:ok, %{signer: @one_sat_signer, valid: true}} = Handlers.parse(data_chunks, "AIP")
    end
  end

  describe "TransactionParser.analyze/1" do
    test "stamps verified AIP signers" do
      out = %BSV.TxOut{script: BSV.Script.from_binary!(@one_sat_signed_script, encoding: :hex)}
      raw = BSV.Tx.to_binary(%BSV.Tx{inputs: [], outputs: [out]}, encoding: :hex)

      assert {:ok, %{aip_signers: [@one_sat_signer], script_analysis_version: 6} = meta} =
               Bitblocks.TransactionParser.analyze(raw)

      assert "AIP" in meta.protocols
    end

    test "no AIP, no signers" do
      out = %BSV.TxOut{script: %BSV.Script{chunks: [:OP_FALSE, :OP_RETURN, "hi"]}}
      raw = BSV.Tx.to_binary(%BSV.Tx{inputs: [], outputs: [out]}, encoding: :hex)
      assert {:ok, %{aip_signers: []}} = Bitblocks.TransactionParser.analyze(raw)
    end
  end
end
