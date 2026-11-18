defmodule Bitblocks.MultisigFixtures do
  @moduledoc """
  A funding and release pair for qart's `p2ms_2_of_3` vector
  (`test/support/fixtures/multisig/p2ms_2_of_3.json`): the funding tx locks
  its first output to the vector's script, and a release spends it with
  signatures from chosen private keys. The vector's keys belong to private
  keys 1, 2 and 3, so `release/2` with `[1, 3]` is signed by key 1 and
  key 3, and private key 4 signs for none of them.
  """

  import Bitblocks.OrdinalFixtures, only: [p2pkh: 2, address: 0, funding_outpoint: 0, tx: 2]

  @vector_path Path.expand("multisig/p2ms_2_of_3.json", __DIR__)
  @external_resource @vector_path
  @vector @vector_path |> File.read!() |> Jason.decode!()

  @doc "The vector as stored: script_hex, satoshis, threshold, pubkeys."
  def vector, do: @vector

  @doc "The vector's locking script."
  def lock_script,
    do: @vector["script_hex"] |> Base.decode16!(case: :lower) |> BSV.Script.from_binary!()

  @doc "The vector's output: its script and value."
  def lock_output, do: %BSV.TxOut{satoshis: @vector["satoshis"], script: lock_script()}

  @doc "A funding tx, `{txid, hex}`, whose output 0 is the vector's lock."
  def funding, do: tx([funding_outpoint()], [lock_output(), p2pkh(address(), 5_000)])

  @doc """
  A release, `{txid, hex}`, spending output 0 of `funding_txid` with one
  signature per private key in `privkeys` (integers), in that order.
  """
  def release(funding_txid, privkeys) do
    input = %BSV.TxIn{
      outpoint: %BSV.OutPoint{
        hash: funding_txid |> Base.decode16!(case: :lower) |> reverse(),
        vout: 0
      },
      script: %BSV.Script{chunks: []}
    }

    unsigned = %BSV.Tx{inputs: [input], outputs: [p2pkh(address(), 900)]}

    signatures =
      for k <- privkeys,
          do: BSV.Sig.sign(unsigned, 0, lock_output(), BSV.PrivKey.from_binary!(<<k::256>>))

    tx = %{unsigned | inputs: [%{input | script: %BSV.Script{chunks: [:OP_0 | signatures]}}]}
    {BSV.Tx.get_txid(tx), BSV.Tx.to_binary(tx, encoding: :hex)}
  end

  defp reverse(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
end
