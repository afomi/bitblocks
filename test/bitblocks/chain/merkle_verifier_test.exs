defmodule Bitblocks.Chain.MerkleVerifierTest do
  use ExUnit.Case, async: true

  alias Bitblocks.Chain.MerkleVerifier

  # Real Bitcoin mainnet blocks — externally verifiable.

  # Block 0 (genesis): one transaction. The merkle root equals the lone txid.
  @genesis_root "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
  @genesis_txids ["4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"]

  # Block 170: the first ever peer-to-peer payment (Satoshi → Hal Finney).
  # Two transactions; exercises the pair-and-hash path.
  @block170_root "7dac2c5666815c17a3b36427de37bb9d2e2c5ccec3f8633eb91a4205cb4c10ff"
  @block170_txids [
    "b1fea52486ce0c62bb442b530a3f0132b826c74e473d1f2c220bfa78111c5082",
    "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16"
  ]

  describe "verify/2 — honest node" do
    test "single-tx (genesis) block: root is the lone txid" do
      assert :ok = MerkleVerifier.verify(@genesis_txids, @genesis_root)
    end

    test "two-tx block (170): pairs and hashes to the committed root" do
      assert :ok = MerkleVerifier.verify(@block170_txids, @block170_root)
    end
  end

  describe "verify/2 — poisoned txid list (threat T4)" do
    test "rejects a reordered txid list" do
      reordered = Enum.reverse(@block170_txids)
      assert {:error, :merkleroot_mismatch} = MerkleVerifier.verify(reordered, @block170_root)
    end

    test "rejects a list with a substituted txid" do
      [_first, second] = @block170_txids
      poisoned = [String.duplicate("ab", 32), second]
      assert {:error, :merkleroot_mismatch} = MerkleVerifier.verify(poisoned, @block170_root)
    end

    test "rejects a list with an extra (injected) txid" do
      poisoned = @block170_txids ++ [String.duplicate("cd", 32)]
      assert {:error, :merkleroot_mismatch} = MerkleVerifier.verify(poisoned, @block170_root)
    end

    test "rejects a dropped txid" do
      assert {:error, :merkleroot_mismatch} =
               MerkleVerifier.verify(tl(@block170_txids), @block170_root)
    end
  end

  describe "verify/2 — malformed input (fail closed)" do
    test "rejects an empty txid list" do
      assert {:error, :empty_txid_list} = MerkleVerifier.verify([], @genesis_root)
    end

    test "rejects a non-hex txid" do
      assert {:error, :invalid_hash_hex} = MerkleVerifier.verify(["not-hex"], @genesis_root)
    end

    test "rejects a short txid" do
      assert {:error, :invalid_hash_hex} = MerkleVerifier.verify(["deadbeef"], @genesis_root)
    end

    test "rejects a malformed merkleroot" do
      assert {:error, :invalid_hash_hex} = MerkleVerifier.verify(@genesis_txids, "nope")
    end

    test "rejects non-list input" do
      assert {:error, :invalid_input} = MerkleVerifier.verify("nope", @genesis_root)
    end
  end
end
