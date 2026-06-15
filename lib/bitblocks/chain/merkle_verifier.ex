defmodule Bitblocks.Chain.MerkleVerifier do
  @moduledoc """
  Verifies that a block's ordered txid list actually produces the merkle root
  committed in its (PoW-verified) header.

  ## Why this exists

  `HeaderVerifier` establishes that a block header is authentic and backed by
  real proof-of-work — which means its `merkleroot` is trustworthy. But the
  transaction *list* arrives separately (`getblock` verbosity 1 → the `tx`
  array), and is just as untrusted as any other node output (trust boundary
  TB2, threat T4). A rogue node could return a header we accept, then hand us a
  doctored or reordered txid list under it.

  Rebuilding the merkle root from the txid list and comparing it to the header's
  committed root closes that gap: the ordered set of txids is authenticated by
  the same proof-of-work that secures the header. (Verifying that each *tx body*
  hashes to its claimed txid is a further, separate check — see THREAT-MODEL.md.)

  ## The computation

  Bitcoin's merkle tree, with its well-known quirks:

    * txids are displayed big-endian, but hashed in internal (little-endian)
      byte order — reverse on the way in;
    * each internal node is `SHA256d(left ++ right)`;
    * when a level has an odd number of nodes, the last is duplicated (paired
      with itself);
    * a single-tx block's root is just that tx's (internal-order) hash.

  Returns `:ok` on match, `{:error, reason}` otherwise. Total and bounded — it
  never raises on malformed input.
  """

  alias BSV.Hash

  @doc """
  Verify that `txids` (the block's ordered txid list, big-endian display hex)
  combine to the `merkleroot` (also big-endian display hex) from the header.
  """
  @spec verify([String.t()], String.t()) :: :ok | {:error, atom()}
  def verify(txids, merkleroot)
      when is_list(txids) and txids != [] and is_binary(merkleroot) do
    with {:ok, leaves} <- decode_leaves(txids),
         {:ok, expected} <- decode_hash(merkleroot) do
      computed = merkle_root(leaves)
      if computed == expected, do: :ok, else: {:error, :merkleroot_mismatch}
    end
  end

  def verify([], _merkleroot), do: {:error, :empty_txid_list}
  def verify(_txids, _merkleroot), do: {:error, :invalid_input}

  # Fold the leaf list up the tree until a single root remains. Each pass
  # halves (rounding up) the node count, so the loop is bounded by log2(n).
  defp merkle_root([root]), do: root

  defp merkle_root(level) do
    level
    |> pair_up()
    |> Enum.map(fn {l, r} -> Hash.sha256_sha256(l <> r) end)
    |> merkle_root()
  end

  # Pair adjacent nodes; an unpaired final node is duplicated (paired with self).
  defp pair_up([]), do: []
  defp pair_up([a]), do: [{a, a}]
  defp pair_up([a, b | rest]), do: [{a, b} | pair_up(rest)]

  defp decode_leaves(txids) do
    Enum.reduce_while(txids, {:ok, []}, fn txid, {:ok, acc} ->
      case decode_hash(txid) do
        {:ok, bytes} -> {:cont, {:ok, [bytes | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # Hashes are displayed big-endian; the tree works in internal order.
  defp decode_hash(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<bytes::binary-size(32)>>} -> {:ok, reverse(bytes)}
      _ -> {:error, :invalid_hash_hex}
    end
  end

  defp decode_hash(_), do: {:error, :invalid_hash_hex}

  defp reverse(bin) when is_binary(bin),
    do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
end
