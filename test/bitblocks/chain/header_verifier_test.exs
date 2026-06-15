defmodule Bitblocks.Chain.HeaderVerifierTest do
  use ExUnit.Case, async: true

  alias Bitblocks.Chain.HeaderVerifier

  # Real Bitcoin mainnet headers as `getblockheader(hash, true)` returns them.
  # These are canonical, externally-verifiable values.

  @genesis %{
    "hash" => "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f",
    "version" => 1,
    "merkleroot" => "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b",
    "time" => 1_231_006_505,
    "bits" => "1d00ffff",
    "nonce" => 2_083_236_893
    # genesis has no previousblockhash
  }

  @block_1 %{
    "hash" => "00000000839a8e6886ab5951d76f411475428afc90947ee320161bbf18eb6048",
    "version" => 1,
    "previousblockhash" =>
      "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f",
    "merkleroot" => "0e3e2357e806b6cdb1f70b54c3a3a17b6714ee1f0e68bebb44a74b1efd512098",
    "time" => 1_231_469_665,
    "bits" => "1d00ffff",
    "nonce" => 2_573_394_689
  }

  describe "verify/2 — honest node" do
    test "accepts the genesis header (no previousblockhash)" do
      assert :ok = HeaderVerifier.verify(@genesis, @genesis["hash"])
    end

    test "accepts a normal header whose fields hash to the claimed hash" do
      assert :ok = HeaderVerifier.verify(@block_1, @block_1["hash"])
    end
  end

  describe "verify/2 — rogue node (threat T4)" do
    test "rejects a tampered merkleroot" do
      poisoned = Map.put(@block_1, "merkleroot", String.duplicate("ab", 32))
      assert {:error, :hash_mismatch} = HeaderVerifier.verify(poisoned, @block_1["hash"])
    end

    test "rejects a tampered nonce" do
      poisoned = Map.put(@block_1, "nonce", @block_1["nonce"] + 1)
      assert {:error, :hash_mismatch} = HeaderVerifier.verify(poisoned, @block_1["hash"])
    end

    test "rejects a header claimed under a hash that isn't its own" do
      # Node returns block 1's real fields but claims they belong to genesis.
      assert {:error, :hash_mismatch} = HeaderVerifier.verify(@block_1, @genesis["hash"])
    end
  end

  describe "verify/3 — proof of work (threat T4)" do
    test "real headers satisfy their own difficulty target (PoW on by default)" do
      # These pass only because the genuine hash meets the genuine `bits` target.
      assert :ok = HeaderVerifier.verify(@genesis, @genesis["hash"])
      assert :ok = HeaderVerifier.verify(@block_1, @block_1["hash"])
    end

    test "rejects a self-consistent header that doesn't meet its claimed difficulty" do
      # Build a header that hashes to itself (self-consistent) but whose `bits`
      # claims the maximum difficulty — its hash will not clear that target,
      # so a node can't pass off a trivially-mined block as high-difficulty.
      header = self_consistent_header(bits: "01010000")

      # Hash matches (self-consistent) ...
      assert :ok = HeaderVerifier.verify(header, header["hash"], check_pow: false)
      # ... but PoW fails when enforced.
      assert {:error, :insufficient_pow} = HeaderVerifier.verify(header, header["hash"])
    end

    test "rejects a malformed compact target (negative sign bit)" do
      header = self_consistent_header(bits: "21008000")
      assert {:error, reason} = HeaderVerifier.verify(header, header["hash"])
      assert reason in [:negative_target, :insufficient_pow, :target_overflow, :zero_target]
    end

    test "check_pow: false skips the work check for synthetic headers" do
      header = self_consistent_header(bits: "01010000")
      assert :ok = HeaderVerifier.verify(header, header["hash"], check_pow: false)
    end
  end

  describe "verify/2 — malformed input (fail closed)" do
    test "rejects a missing required field" do
      assert {:error, _} =
               HeaderVerifier.verify(Map.delete(@block_1, "merkleroot"), @block_1["hash"])
    end

    test "rejects non-hex hash fields" do
      assert {:error, _} =
               HeaderVerifier.verify(Map.put(@block_1, "merkleroot", "not-hex"), @block_1["hash"])
    end

    test "rejects a hash of the wrong length" do
      assert {:error, _} = HeaderVerifier.verify(@block_1, "deadbeef")
    end

    test "rejects non-map input" do
      assert {:error, :invalid_input} = HeaderVerifier.verify("nope", @block_1["hash"])
    end
  end

  # Build a header map whose "hash" genuinely is its own SHA256d, so it passes
  # self-consistency. Mirrors the verifier's serialization (byte-order included)
  # so we can control `bits` independently and exercise the PoW branch.
  defp self_consistent_header(opts) do
    version = 1
    prev = String.duplicate("00", 32)
    merkle = String.duplicate("11", 32)
    time = 1_700_000_000
    nonce = 0
    bits = Keyword.get(opts, :bits, "1d00ffff")

    {bits_int, ""} = Integer.parse(bits, 16)

    serialized =
      <<
        version::little-32,
        reverse_hex(prev)::binary,
        reverse_hex(merkle)::binary,
        time::little-32,
        bits_int::little-32,
        nonce::little-32
      >>

    hash = serialized |> BSV.Hash.sha256_sha256() |> reverse_bin() |> Base.encode16(case: :lower)

    %{
      "hash" => hash,
      "version" => version,
      "previousblockhash" => prev,
      "merkleroot" => merkle,
      "time" => time,
      "bits" => bits,
      "nonce" => nonce
    }
  end

  defp reverse_hex(hex), do: hex |> Base.decode16!(case: :mixed) |> reverse_bin()

  defp reverse_bin(bin),
    do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
end
