defmodule Bitblocks.MultisigTest do
  use ExUnit.Case, async: true

  import Bitblocks.MultisigFixtures

  alias Bitblocks.Multisig

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
      assert [%{status: :checked, m: 2, n: 3, signed: [0, 2]} = input] = check([1, 3])
      assert input.vin == 0
      assert input.vout == 0
      assert input.pubkeys == vector()["pubkeys"]

      assert input.signatures == [
               %{index: 0, key: 0, result: :matched},
               %{index: 1, key: 2, result: :matched}
             ]
    end

    test "key 2 and key 3 signed" do
      assert [%{signed: [1, 2]}] = check([2, 3])
    end

    test "a signature from a key not in the lock couldn't match" do
      assert [%{signed: [2], signatures: signatures}] = check([4, 3])

      assert signatures == [
               %{index: 0, key: nil, result: :no_match},
               %{index: 1, key: 2, result: :matched}
             ]
    end

    test "signatures out of key order are named, not counted" do
      assert [%{signed: [2], signatures: [first, second]}] = check([3, 1])
      assert first == %{index: 0, key: 2, result: :matched}
      assert second == %{index: 1, key: 0, result: :out_of_order}
    end

    test "a signature over another tx's sighash couldn't match" do
      {funding_txid, _hex} = funding()
      {other_txid, _hex} = funding()
      {_txid, hex} = release(other_txid, [1, 3])
      tx = decode(hex)

      # The stored previous output is right, but the signatures were made
      # for a release spending another funding tx.
      tx = put_in(tx.inputs, [%{hd(tx.inputs) | outpoint: outpoint(funding_txid)}])

      assert [%{signed: [], signatures: sigs}] = Multisig.signers(tx, stored(funding_txid))
      assert Enum.all?(sigs, &(&1.result == :no_match))
    end

    test "previous output not in our index" do
      {funding_txid, _hex} = funding()
      {_txid, hex} = release(funding_txid, [1, 3])

      assert [%{status: :not_in_index, signed: [], signatures: sigs}] =
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

      assert Multisig.signers(decode(hex), %{{funding_txid, 0} => p2pkh}) == []
    end
  end

  test "signed_sentence names the keys that signed" do
    assert BitblocksWeb.MultisigComponents.signed_sentence([0, 2]) == "Key 1 and key 3 signed."
    assert BitblocksWeb.MultisigComponents.signed_sentence([1]) == "Key 2 signed."

    assert BitblocksWeb.MultisigComponents.signed_sentence([0, 1, 2]) ==
             "Key 1, key 2 and key 3 signed."
  end

  test "short_key keeps the first and last eight hex digits" do
    assert Multisig.short_key(hd(vector()["pubkeys"])) == "0279be66…16f81798"
  end

  defp check(privkeys) do
    {funding_txid, _hex} = funding()
    {_txid, hex} = release(funding_txid, privkeys)
    Multisig.signers(decode(hex), stored(funding_txid))
  end

  # The previous output as transactions.outputs stores it.
  defp stored(funding_txid) do
    json =
      Jason.encode!(%{
        "value" => vector()["satoshis"] / 100_000_000,
        "scriptPubKey" => %{"hex" => vector()["script_hex"]}
      })

    %{{funding_txid, 0} => json}
  end

  defp decode(hex) do
    {:ok, tx} = Bitblocks.Chain.SafeTx.from_hex(hex)
    tx
  end

  defp outpoint(txid) do
    %BSV.OutPoint{
      hash:
        txid
        |> Base.decode16!(case: :lower)
        |> :binary.bin_to_list()
        |> Enum.reverse()
        |> :binary.list_to_bin(),
      vout: 0
    }
  end
end
