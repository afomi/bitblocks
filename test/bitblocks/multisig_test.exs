defmodule Bitblocks.MultisigTest do
  use ExUnit.Case, async: true

  import Bitblocks.MultisigFixtures

  alias Bitblocks.Multisig
  alias BitblocksWeb.MultisigComponents

  # qart's p2ms_2_of_3 vector reads as a 2-of-3 lock with its three keys.
  test "the qart vector classifies as a 2-of-3 multisig with its keys" do
    fields = Bitblocks.Script.extract_fields(lock_script())

    assert fields.m == vector()["threshold"]
    assert fields.n == 3
    assert fields.pubkeys == vector()["pubkeys"]
    assert Multisig.lock_sentence(fields.m, fields.n) == "Locked to 2 of these 3 keys"
  end

  test "the keys are private keys 1, 2 and 3, so the tests can sign for them" do
    for {pubkey, k} <- Enum.with_index(vector()["pubkeys"], 1) do
      derived =
        BSV.PrivKey.from_binary!(<<k::256>>)
        |> BSV.PubKey.from_privkey()
        |> BSV.PubKey.to_binary(encoding: :hex)

      assert derived == pubkey
    end
  end

  describe "signers/2" do
    test "key 1 and key 3 signed, key 2 did not" do
      assert {[%{status: :checked, m: 2, n: 3, signed: [0, 2]} = input], false} = check([1, 3])
      assert input.vin == 0
      assert input.vout == 0
      assert input.pubkeys == vector()["pubkeys"]

      assert input.signatures == [
               %{index: 0, key: 0, result: :matched, reason: nil},
               %{index: 1, key: 2, result: :matched, reason: nil}
             ]

      assert MultisigComponents.headline(input) == "Key 1 and key 3 signed."

      assert MultisigComponents.key_states(input) == %{
               0 => :signed,
               1 => :not_signed,
               2 => :signed
             }
    end

    test "key 2 and key 3 signed" do
      assert {[%{signed: [1, 2]}], false} = check([2, 3])
    end

    test "a signature from a key not in the lock couldn't match" do
      assert {[%{signed: [2], signatures: signatures} = input], false} = check([4, 3])

      assert signatures == [
               %{index: 0, key: nil, result: :no_match, reason: nil},
               %{index: 1, key: 2, result: :matched, reason: nil}
             ]

      assert MultisigComponents.signature_note(hd(signatures), 3) ==
               "Signature 1 couldn't match any of the 3 keys."

      assert MultisigComponents.key_states(input)[0] == :not_signed
    end

    test "signatures out of key order are named, not counted" do
      assert {[%{signed: [2], signatures: [first, second]}], false} = check([3, 1])
      assert first == %{index: 0, key: 2, result: :matched, reason: nil}
      assert second == %{index: 1, key: 0, result: :out_of_order, reason: nil}

      assert MultisigComponents.signature_note(second, 3) ==
               "Signature 2 is from key 1, but out of order, so it doesn't count."
    end

    test "a signature over another tx's sighash couldn't match" do
      {funding_txid, _hex} = funding()
      {other_txid, _hex} = funding()
      {_txid, hex} = release(other_txid, [1, 3])
      tx = decode(hex)

      # The stored previous output is right, but the signatures were made
      # for a release spending another funding tx.
      tx = put_in(tx.inputs, [%{hd(tx.inputs) | outpoint: outpoint(funding_txid, 0)}])

      assert {[%{signed: [], signatures: sigs}], false} =
               Multisig.signers(tx, stored(funding_txid))

      assert Enum.all?(sigs, &(&1.result == :no_match))
    end

    test "previous output not in our index" do
      {funding_txid, _hex} = funding()
      {_txid, hex} = release(funding_txid, [1, 3])

      assert {[%{status: :not_in_index, signed: [], signatures: sigs}], false} =
               Multisig.signers(decode(hex), %{})

      assert length(sigs) == 2
    end

    test "an input spending a stored output that isn't multisig is left out" do
      {funding_txid, _hex} = funding()
      {_txid, hex} = release(funding_txid, [1, 3])

      p2pkh =
        Jason.encode!(%{
          "value" => 0.00001,
          "scriptPubKey" => %{"hex" => "76a914" <> String.duplicate("00", 20) <> "88ac"}
        })

      assert Multisig.signers(decode(hex), %{{funding_txid, 0} => p2pkh}) == {[], false}
    end

    test "a stored output over 16 KB is not decoded, so the input is left out" do
      {funding_txid, _hex} = funding()
      {_txid, hex} = release(funding_txid, [1, 3])

      # A real multisig script, padded past the guard: the guard reads only
      # the element's size, never its contents.
      padded =
        Jason.encode!(%{
          "value" => vector()["satoshis"] / 100_000_000,
          "scriptPubKey" => %{"hex" => vector()["script_hex"]},
          "padding" => String.duplicate("0", 16_384)
        })

      assert byte_size(padded) > 16_384
      assert Multisig.signers(decode(hex), %{{funding_txid, 0} => padded}) == {[], false}
    end

    test "an input reads at most as many signatures as its lock has keys" do
      assert {[%{signed: [0, 1, 2], signatures: sigs, extra_pushes: 1}], false} =
               check([1, 2, 3, 1])

      assert length(sigs) == 3
    end
  end

  describe "the bounds" do
    test "only the first 20 multisig inputs are read, and the page knows there are more" do
      {funding_txid, _hex} = funding(21)
      {_txid, hex} = release_many(funding_txid, List.duplicate([1, 3], 21))

      assert {inputs, true} = Multisig.signers(decode(hex), %{})
      assert length(inputs) == Multisig.max_inputs()
      assert List.last(inputs).vin == 19
    end

    test "exactly 20 multisig inputs leave nothing unread" do
      {funding_txid, _hex} = funding(20)
      {_txid, hex} = release_many(funding_txid, List.duplicate([1, 3], 20))

      assert {inputs, false} = Multisig.signers(decode(hex), %{})
      assert length(inputs) == 20
    end

    # Each [1, 3] input costs 4 checks (one sighash, then key 1, key 2, key 3);
    # the [3, 1] input costs 5. 5 + 14 * 4 = 61, so input 15 has 3 checks: its
    # sighash, key 1 for the first signature, and key 2 for the second, which
    # then runs out before key 3.
    test "the 64-check budget runs out part way through an input" do
      signers = [[3, 1] | List.duplicate([1, 3], 15)]
      {funding_txid, _hex} = funding(16)
      {_txid, hex} = release_many(funding_txid, signers)

      assert {inputs, false} = Multisig.signers(decode(hex), stored(funding_txid, 16))

      for input <- Enum.slice(inputs, 1..14), do: assert(input.signed == [0, 2])
      last = List.last(inputs)
      assert last.vin == 15
      assert last.signed == [0]

      assert last.signatures == [
               %{index: 0, key: 0, result: :matched, reason: nil},
               %{index: 1, key: nil, result: :not_checked, reason: :budget}
             ]

      assert MultisigComponents.headline(last) == "Key 1 signed. We checked 1 of 2 signatures."

      assert MultisigComponents.key_states(last) == %{
               0 => :signed,
               1 => :not_checked,
               2 => :not_checked
             }

      assert MultisigComponents.signature_note(List.last(last.signatures), 3) ==
               "Signature 2 wasn't checked: we stop after 64 checks on one page."
    end

    test "an input reached with no budget left is not checked, never \"didn't sign\"" do
      signers = List.duplicate([1, 3], 17)
      {funding_txid, _hex} = funding(17)
      {_txid, hex} = release_many(funding_txid, signers)

      # 16 inputs of 4 checks spend all 64.
      assert {inputs, false} = Multisig.signers(decode(hex), stored(funding_txid, 17))
      last = List.last(inputs)
      assert last.signed == []
      assert Enum.all?(last.signatures, &(&1 == %{&1 | result: :not_checked, reason: :budget}))
      assert MultisigComponents.headline(last) == "We checked 0 of 2 signatures."
      refute MultisigComponents.headline(last) =~ "No signature matched"
      assert Enum.all?(Map.values(MultisigComponents.key_states(last)), &(&1 == :not_checked))
    end

    # A legacy (no FORKID) SIGHASH_SINGLE signature on an input with no
    # output of its own index: the BSV library raises, where consensus signs
    # the constant 1. That signature is not checked, not "couldn't match".
    test "a sighash we can't compute leaves the signature not checked" do
      {funding_txid, _hex} = funding()
      {_txid, hex} = release(funding_txid, [1, 3])
      tx = decode(hex)

      fake_single = <<0x30, 6, 2, 1, 1, 2, 1, 1, 0x03>>

      tx = %{
        tx
        | inputs: [%{hd(tx.inputs) | script: %BSV.Script{chunks: [:OP_0, fake_single]}}],
          outputs: []
      }

      assert {[%{signed: [], signatures: [sig]} = input], false} =
               Multisig.signers(tx, stored(funding_txid))

      assert sig == %{index: 0, key: nil, result: :not_checked, reason: :no_sighash}

      assert MultisigComponents.signature_note(sig, 3) ==
               "Signature 1 wasn't checked: we couldn't compute what this signature signs."

      assert MultisigComponents.headline(input) == "We checked 0 of 1 signature."
    end
  end

  test "signed_sentence names the keys that signed" do
    assert MultisigComponents.signed_sentence([0, 2]) == "Key 1 and key 3 signed."
    assert MultisigComponents.signed_sentence([1]) == "Key 2 signed."
    assert MultisigComponents.signed_sentence([0, 1, 2]) == "Key 1, key 2 and key 3 signed."
  end

  test "short_key keeps the first and last eight hex digits" do
    assert Multisig.short_key(hd(vector()["pubkeys"])) == "0279be66…16f81798"
  end

  defp check(privkeys) do
    {funding_txid, _hex} = funding()
    {_txid, hex} = release(funding_txid, privkeys)
    Multisig.signers(decode(hex), stored(funding_txid))
  end

  # The previous outputs as transactions.outputs stores them.
  defp stored(funding_txid, count \\ 1) do
    json =
      Jason.encode!(%{
        "value" => vector()["satoshis"] / 100_000_000,
        "scriptPubKey" => %{"hex" => vector()["script_hex"]}
      })

    for vout <- 0..(count - 1), into: %{}, do: {{funding_txid, vout}, json}
  end

  defp decode(hex) do
    {:ok, tx} = Bitblocks.Chain.SafeTx.from_hex(hex)
    tx
  end

  defp outpoint(txid, vout) do
    %BSV.OutPoint{
      hash:
        txid
        |> Base.decode16!(case: :lower)
        |> :binary.bin_to_list()
        |> Enum.reverse()
        |> :binary.list_to_bin(),
      vout: vout
    }
  end
end
