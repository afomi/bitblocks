defmodule Bitblocks.Chain.HeaderVerifier do
  @moduledoc """
  Verifies that a block header returned by the upstream BSV node actually
  hashes to the block hash the node claims for it.

  ## Why this exists

  bitblocks trusts a single upstream node (trust boundary TB2 in
  THREAT-MODEL.md). A rogue, buggy, or compromised node could return a
  `getblockheader` response whose fields do not actually hash to the hash we
  asked for — letting it write arbitrary "blocks" into our index (threat T4,
  asset A2 — data integrity). This module re-derives the block hash from the
  header fields and refuses any header that does not match.

  ## The check

  A Bitcoin block hash is `SHA256(SHA256(header))` over the canonical 80-byte
  serialized header:

      version (4, little-endian)
      prev_block_hash (32, internal/little-endian byte order)
      merkle_root (32, internal/little-endian byte order)
      time (4, little-endian)
      bits (4, little-endian)
      nonce (4, little-endian)

  RPC presents hashes as big-endian *display* hex, so prev/merkleroot/result
  are byte-reversed relative to the serialized form. We reverse on the way in
  and reverse the digest on the way out before comparing.

  Returns `:ok` when the header is self-consistent, or `{:error, reason}` so
  the caller can fail closed and skip the insert.
  """

  import Bitwise

  alias BSV.Hash

  @doc """
  Verify that `header` (a `getblockheader` result map) hashes to `claimed_hash`
  **and** that the hash satisfies the proof-of-work target encoded in `bits`.

  Two independent guarantees:

    1. **Self-consistency** — the fields hash to the hash the node claims, so a
       node can't relabel arbitrary data as a given block (threat T4).
    2. **Proof-of-work** — the hash, read as a little-endian 256-bit integer, is
       `≤` the target that `bits` (compact nBits) decodes to. Without this, a
       node could still hand us a self-consistent but trivially-mined fake.

  Fails closed: any missing/malformed field, a hash mismatch, or insufficient
  work is an error.

  ## Options

    * `:check_pow` (default `true`) — set `false` to verify only
      self-consistency. Use for synthetic/test headers that aren't real PoW.
  """
  @spec verify(map(), String.t(), keyword()) :: :ok | {:error, atom()}
  def verify(header, claimed_hash, opts \\ [])

  def verify(header, claimed_hash, opts) when is_map(header) and is_binary(claimed_hash) do
    with {:ok, version} <- fetch_int(header, "version"),
         {:ok, prev_hash} <- fetch_hash(header, "previousblockhash", allow_genesis: true),
         {:ok, merkle_root} <- fetch_hash(header, "merkleroot"),
         {:ok, time} <- fetch_int(header, "time"),
         {:ok, bits} <- fetch_bits(header, "bits"),
         {:ok, nonce} <- fetch_int(header, "nonce"),
         {:ok, claimed} <- decode_hash(claimed_hash) do
      serialized =
        <<
          version::little-32,
          # prev/merkle stored big-endian for display → reverse to internal order
          reverse(prev_hash)::binary,
          reverse(merkle_root)::binary,
          time::little-32,
          bits::little-32,
          nonce::little-32
        >>

      # Block hash is also displayed big-endian, so reverse the digest back.
      digest = Hash.sha256_sha256(serialized)
      computed = reverse(digest)

      cond do
        computed != claimed ->
          {:error, :hash_mismatch}

        Keyword.get(opts, :check_pow, true) ->
          check_pow(digest, bits)

        true ->
          :ok
      end
    end
  end

  def verify(_header, _claimed_hash, _opts), do: {:error, :invalid_input}

  # The hash satisfies PoW when its little-endian integer value is ≤ target.
  # `digest` here is the raw SHA256d (internal byte order), which is the
  # little-endian representation Bitcoin compares against the target.
  defp check_pow(digest, bits) do
    case decode_target(bits) do
      {:ok, target} ->
        hash_value = :binary.decode_unsigned(digest, :little)
        if hash_value <= target, do: :ok, else: {:error, :insufficient_pow}

      error ->
        error
    end
  end

  # Decode compact "nBits" into the full 256-bit target:
  #   target = mantissa × 256^(exponent - 3)
  # where the high byte is the exponent and the low 3 bytes are the mantissa.
  # Reject negative (sign bit), overflow, and out-of-range targets — fail closed.
  defp decode_target(bits) when is_integer(bits) and bits >= 0 do
    exponent = bits >>> 24
    mantissa = bits &&& 0x007FFFFF
    sign = bits &&& 0x00800000

    cond do
      sign != 0 ->
        {:error, :negative_target}

      mantissa == 0 ->
        {:error, :zero_target}

      exponent <= 3 ->
        {:ok, mantissa >>> (8 * (3 - exponent))}

      true ->
        target = mantissa <<< (8 * (exponent - 3))
        # A valid target must fit in 256 bits.
        if target < 1 <<< 256, do: {:ok, target}, else: {:error, :target_overflow}
    end
  end

  defp decode_target(_), do: {:error, :invalid_bits}

  # The genesis block's previousblockhash is all-zeros; the node may omit it.
  defp fetch_hash(header, key, opts \\ []) do
    case Map.get(header, key) do
      hex when is_binary(hex) ->
        decode_hash(hex)

      _ when key == "previousblockhash" ->
        if Keyword.get(opts, :allow_genesis, false),
          do: {:ok, <<0::256>>},
          else: {:error, :missing_prev_hash}

      _ ->
        {:error, :"missing_#{key}"}
    end
  end

  defp decode_hash(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<bytes::binary-size(32)>>} -> {:ok, bytes}
      _ -> {:error, :invalid_hash_hex}
    end
  end

  defp fetch_int(header, key) do
    case Map.get(header, key) do
      n when is_integer(n) and n >= 0 -> {:ok, n}
      _ -> {:error, :"invalid_#{key}"}
    end
  end

  # `bits` arrives from RPC as 8-char big-endian hex (the compact target).
  defp fetch_bits(header, key) do
    case Map.get(header, key) do
      hex when is_binary(hex) ->
        case Integer.parse(hex, 16) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> {:error, :invalid_bits}
        end

      n when is_integer(n) and n >= 0 ->
        {:ok, n}

      _ ->
        {:error, :invalid_bits}
    end
  end

  defp reverse(bin) when is_binary(bin),
    do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
end
