defmodule Bitblocks.Chain.MerkleBuilder do
  @moduledoc """
  A block's merkle root built one txid at a time, in O(log n) memory, for
  blocks streamed rather than held (`Bitblocks.Chain.BlockStream`, #66).

  The rule is `Bitblocks.Chain.MerkleVerifier`'s (Bitcoin's): each node is
  `SHA256d(left <> right)` in internal byte order, and a level with an odd
  number of nodes pairs its last node with itself. A 4M-tx block's txid list
  would be about 128 MB of binaries; this keeps a stack of at most one
  partial hash per level, 64 at the most.

  Push each tx's hash in block order, in internal byte order (the double
  SHA-256 of its bytes, not reversed), then take `root/1`.
  """

  @opaque t :: {non_neg_integer(), [{non_neg_integer(), binary()}]}

  @doc "An empty builder."
  @spec new() :: t()
  def new, do: {0, []}

  @doc "Adds the next leaf, a 32-byte hash in internal byte order."
  @spec push(t(), <<_::256>>) :: t()
  def push({count, stack}, <<_::binary-32>> = hash), do: {count + 1, merge([{0, hash} | stack])}

  @doc "How many leaves have been pushed."
  @spec count(t()) :: non_neg_integer()
  def count({count, _stack}), do: count

  @doc "The root in internal byte order, or `{:error, :empty_txid_list}`."
  @spec root(t()) :: {:ok, <<_::256>>} | {:error, :empty_txid_list}
  def root({0, _stack}), do: {:error, :empty_txid_list}
  def root({_count, [{level, hash} | rest]}), do: {:ok, fold(level, hash, rest)}

  # Two complete subtrees of the same height make one a level up. The stack's
  # levels strictly increase from top to bottom.
  defp merge([{level, right}, {level, left} | rest]),
    do: merge([{level + 1, sha256d(left <> right)} | rest])

  defp merge(stack), do: stack

  # What's left after the last leaf: a lone node at a lower level than its
  # neighbour is the odd one out at each level on the way up, so it pairs with
  # itself until it reaches its neighbour's height.
  defp fold(_level, hash, []), do: hash

  defp fold(level, hash, [{next, _} | _] = rest) when next > level,
    do: fold(level + 1, sha256d(hash <> hash), rest)

  defp fold(level, hash, [{level, left} | rest]), do: fold(level + 1, sha256d(left <> hash), rest)

  defp sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))
end
