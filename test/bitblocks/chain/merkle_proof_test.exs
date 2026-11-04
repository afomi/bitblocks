defmodule Bitblocks.Chain.MerkleProofTest do
  use ExUnit.Case, async: true

  alias Bitblocks.Chain.{MerkleProof, MerkleVerifier}

  defp txids(n),
    do: for(i <- 1..n, do: :crypto.hash(:sha256, <<i>>) |> Base.encode16(case: :lower))

  test "every leaf of trees from 1 to 9 txs climbs to the root MerkleVerifier accepts" do
    for n <- 1..9, index <- 0..(n - 1) do
      list = txids(n)
      siblings = MerkleProof.branch(list, index)
      root = MerkleProof.climb(Enum.at(list, index), index, siblings)

      assert MerkleVerifier.verify(list, root) == :ok, "n=#{n} index=#{index}"
    end
  end

  test "a single-tx block's proof is no siblings: the txid is the root" do
    [txid] = txids(1)
    assert MerkleProof.branch([txid], 0) == []
    assert MerkleProof.climb(txid, 0, []) == txid
  end

  test "the wrong index does not climb to the root" do
    list = txids(4)
    siblings = MerkleProof.branch(list, 1)
    refute MerkleVerifier.verify(list, MerkleProof.climb(Enum.at(list, 1), 0, siblings)) == :ok
  end
end
