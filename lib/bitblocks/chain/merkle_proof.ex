defmodule Bitblocks.Chain.MerkleProof do
  @moduledoc """
  A merkle inclusion proof for a stored transaction that a caller can check
  without trusting bitblocks (#43): the tx's `index` in its block and the
  `siblings` that climb from its txid to the header's `merkleroot`.

  ## Where the siblings come from

    * **`block_txids`**: the block's stored `tx` array, when it holds the
      whole list (`length == TxidSource.expected_tx_count/1`). The list is
      first rebuilt into a root with `MerkleVerifier` and compared to the
      header's; the branch is then computed locally.
    * **`gettxoutproof`**: blocks above the 10k-txid threshold don't keep
      their list, and fetching one (up to 128 MB) per request is too much
      for a public endpoint. For those the node's `gettxoutproof` blob (a
      serialized merkleblock: header + partial merkle tree) is parsed here.
      Its header must hash to the block's hash and carry the block's
      `merkleroot`, its tree must rebuild that root, and it must match our
      txid exactly once. The branch is read from the parsed tree.

  Either way the branch is climbed once more before it is returned, and a
  climb that misses the header's root is `{:error, :merkleroot_mismatch}`.
  No path returns an unchecked proof.

  ## Canonical

  Tip sync deletes an orphaned block's row on a reorg
  (`SyncHeadersWorker.delete_orphans/2`), while its tx rows keep the orphan's
  hash until `Reorgs.Reconcile` moves or removes them. So a tx's block is
  canonical, as far as this index knows, when:

    * a block row with the tx's `block_hash` exists (heights are unique, so
      it is the only block we hold at that height);
    * its height equals the tx row's `block_height`, when the row has one
      (older rows were stored without it; `Release.backfill_tx_block_heights/0`);
    * the stored block one height up, if any, names it as `prevblockhash`
      (tip sync checks that continuity on insert; this catches a stale pair).

  Anything else is `{:error, :not_canonical}`, never a proof for the old root.

  ## Trust

  The header (and so `merkleroot`) is trusted because tip sync stored it
  only after `HeaderVerifier` checked that its fields hash to its hash and
  that the hash meets the proof-of-work target in `bits`, and that it chains
  onto its stored predecessor. The proof is inclusion under that header; a
  caller who wants more checks the header against their own header chain.
  This is not a BEEF body (#17).
  """

  import Ecto.Query

  alias Bitblocks.Repo
  alias Bitblocks.Chain
  alias Bitblocks.Chain.{Block, MerkleVerifier, TxidSource}
  alias Bitblocks.Sync
  alias BSV.Hash

  @trust %{
    header:
      "merkleroot is from a block header bitblocks stored only after checking it hashes to " <>
        "block_hash, meets the proof-of-work target in its bits, and chains onto its parent.",
    proof:
      "siblings and index were climbed back to merkleroot before this response was sent; " <>
        "climb them yourself: at each level, an even index hashes running <> sibling, " <>
        "an odd index sibling <> running, with sha256d over internal (reversed) byte order.",
    canonical:
      "the block is the one this index holds at block_height, and the next stored block builds on it."
  }

  @type proof :: %{
          txid: String.t(),
          index: non_neg_integer(),
          siblings: [String.t()],
          merkleroot: String.t(),
          block_hash: String.t(),
          block_height: integer(),
          confirmations: pos_integer(),
          source: String.t(),
          trust: map()
        }

  @doc """
  Builds a checked proof for a stored tx.

  Errors: `:not_found` (no tx row), `:not_canonical` (its block was
  orphaned or is no longer the chain's), `:merkleroot_mismatch` (the txids
  or the node's tree don't rebuild the header's root), `:tx_not_in_block`,
  `:proof_unavailable` (no stored txid list, and the node gave no usable proof).
  """
  @spec build(String.t()) :: {:ok, proof()} | {:error, atom()}
  def build(txid) when is_binary(txid) do
    with {:tx, tx} when not is_nil(tx) <- {:tx, Chain.get_transaction_by_txid(txid)},
         {:ok, block} <- canonical_block(tx),
         {:ok, root} <- header_root(block),
         {:ok, index, siblings, source} <- branch_for(block, txid),
         :ok <- check_climb(txid, index, siblings, root) do
      {:ok,
       %{
         txid: txid,
         index: index,
         siblings: siblings,
         merkleroot: root,
         block_hash: block.hash,
         block_height: block.height,
         confirmations: confirmations(block),
         source: source,
         trust: @trust
       }}
    else
      {:tx, nil} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # --- canonical ---------------------------------------------------------------

  defp canonical_block(tx) do
    with %Block{} = block <- Repo.one(from b in Block, where: b.hash == ^tx.block_hash),
         # A row stored before block_height was written has none; the
         # block_hash still names its block. Only a different height is a mismatch.
         true <- tx.block_height in [nil, block.height],
         true <- child_builds_on?(block) do
      {:ok, block}
    else
      _ -> {:error, :not_canonical}
    end
  end

  defp child_builds_on?(%Block{height: height, hash: hash}) do
    case Repo.one(
           from b in Block, where: b.height == ^(height + 1), select: b.prevblockhash, limit: 1
         ) do
      nil -> true
      ^hash -> true
      _other -> false
    end
  end

  defp header_root(%Block{merkleroot: root}) when is_binary(root) do
    case Base.decode16(root, case: :mixed) do
      {:ok, <<_::binary-size(32)>>} -> {:ok, String.downcase(root)}
      _ -> {:error, :merkleroot_mismatch}
    end
  end

  defp header_root(_block), do: {:error, :merkleroot_mismatch}

  defp confirmations(%Block{height: height}), do: (Sync.tip() || height) - height + 1

  # --- branch ------------------------------------------------------------------

  defp branch_for(%Block{tx: txids} = block, txid)
       when is_list(txids) and txids != [] do
    if length(txids) == TxidSource.expected_tx_count(block) do
      from_txids(txids, block.merkleroot, txid)
    else
      from_node(block, txid)
    end
  end

  defp branch_for(block, txid), do: from_node(block, txid)

  defp from_txids(txids, root, txid) do
    with :ok <- verified(MerkleVerifier.verify(txids, root)),
         index when is_integer(index) <- Enum.find_index(txids, &(&1 == txid)) do
      {:ok, index, branch(txids, index), "block_txids"}
    else
      nil -> {:error, :tx_not_in_block}
      {:error, _} = error -> error
    end
  end

  defp verified(:ok), do: :ok
  defp verified({:error, _}), do: {:error, :merkleroot_mismatch}

  defp from_node(block, txid) do
    case cli().gettxoutproof([txid], block.hash) do
      hex when is_binary(hex) -> from_merkleblock(hex, block, txid)
      _ -> {:error, :proof_unavailable}
    end
  end

  @doc """
  The siblings (big-endian display hex, leaf to root) for the leaf at
  `index` of an ordered txid list. A level with an odd count pairs its last
  node with itself, so that node's sibling is its own hash.
  """
  @spec branch([String.t()], non_neg_integer()) :: [String.t()]
  def branch(txids, index) do
    txids |> Enum.map(&internal/1) |> do_branch(index, []) |> Enum.map(&display/1)
  end

  defp do_branch([_root], _index, acc), do: Enum.reverse(acc)

  defp do_branch(level, index, acc) do
    sibling_index = Bitwise.bxor(index, 1)
    sibling = Enum.at(level, sibling_index) || Enum.at(level, index)
    do_branch(next_level(level), div(index, 2), [sibling | acc])
  end

  defp next_level([]), do: []
  defp next_level([a]), do: [Hash.sha256_sha256(a <> a)]
  defp next_level([a, b | rest]), do: [Hash.sha256_sha256(a <> b) | next_level(rest)]

  @doc """
  Climbs `siblings` from `txid` at `index`; returns the root as display hex.
  """
  @spec climb(String.t(), non_neg_integer(), [String.t()]) :: String.t()
  def climb(txid, index, siblings) do
    {root, _} =
      Enum.reduce(siblings, {internal(txid), index}, fn sibling, {acc, i} ->
        sib = internal(sibling)
        pair = if rem(i, 2) == 0, do: acc <> sib, else: sib <> acc
        {Hash.sha256_sha256(pair), div(i, 2)}
      end)

    display(root)
  end

  defp check_climb(txid, index, siblings, root) do
    if climb(txid, index, siblings) == root, do: :ok, else: {:error, :merkleroot_mismatch}
  end

  # --- gettxoutproof (serialized merkleblock) -------------------------------------

  defp from_merkleblock(hex, block, txid) do
    with {:ok, bin} <- Base.decode16(hex, case: :mixed),
         {:ok, header, n_tx, hashes, bits} <- parse_merkleblock(bin),
         :ok <- check_header(header, block),
         {:ok, nodes, matches} <- traverse(n_tx, hashes, bits),
         :ok <- check_tree_root(nodes, n_tx, header),
         [{index, _}] <- Enum.filter(matches, fn {_i, h} -> display(h) == txid end) do
      {:ok, index, tree_branch(nodes, n_tx, index), "gettxoutproof"}
    else
      {:error, :merkleroot_mismatch} = error -> error
      _ -> {:error, :merkleroot_mismatch}
    end
  end

  defp parse_merkleblock(<<header::binary-size(80), n_tx::little-32, rest::binary>>)
       when n_tx > 0 do
    with {:ok, n_hashes, rest} <- varint(rest),
         size = n_hashes * 32,
         <<hash_bytes::binary-size(size), rest::binary>> <- rest,
         {:ok, n_flags, rest} <- varint(rest),
         <<flags::binary-size(n_flags)>> <- rest do
      hashes = for <<h::binary-size(32) <- hash_bytes>>, do: h
      bits = for <<byte <- flags>>, i <- 0..7, do: Bitwise.band(Bitwise.bsr(byte, i), 1) == 1
      {:ok, header, n_tx, hashes, bits}
    else
      _ -> {:error, :merkleroot_mismatch}
    end
  end

  defp parse_merkleblock(_), do: {:error, :merkleroot_mismatch}

  defp varint(<<0xFD, n::little-16, rest::binary>>), do: {:ok, n, rest}
  defp varint(<<0xFE, n::little-32, rest::binary>>), do: {:ok, n, rest}
  defp varint(<<0xFF, n::little-64, rest::binary>>), do: {:ok, n, rest}
  defp varint(<<n, rest::binary>>), do: {:ok, n, rest}
  defp varint(_), do: :error

  # The blob's header must be our (PoW-verified) block: it hashes to the
  # block's hash and commits to the stored merkleroot.
  defp check_header(<<_::binary-size(36), root::binary-size(32), _::binary>> = header, block) do
    if display(Hash.sha256_sha256(header)) == String.downcase(block.hash) and
         display(root) == String.downcase(block.merkleroot) do
      :ok
    else
      {:error, :merkleroot_mismatch}
    end
  end

  defp check_tree_root(nodes, n_tx, <<_::binary-size(36), root::binary-size(32), _::binary>>) do
    if Map.get(nodes, {tree_height(n_tx), 0}) == root,
      do: :ok,
      else: {:error, :merkleroot_mismatch}
  end

  defp width(n_tx, height), do: Bitwise.bsr(n_tx + Bitwise.bsl(1, height) - 1, height)

  defp tree_height(n_tx), do: tree_height(n_tx, 0)
  defp tree_height(n_tx, h), do: if(width(n_tx, h) > 1, do: tree_height(n_tx, h + 1), else: h)

  # Bitcoin Core's TraverseAndExtract, depth first. Records every node it
  # knows, keyed {height, pos}, so the matched leaf's siblings can be read back.
  # Every hash and every flag byte must be consumed (bar padding), and a right
  # child equal to its left is refused (CVE-2012-2459).
  defp traverse(n_tx, hashes, bits) do
    state = %{hashes: hashes, bits: bits, nodes: %{}, matches: []}

    case walk(n_tx, tree_height(n_tx), 0, state) do
      {:ok, _hash, %{hashes: [], bits: rest} = st} ->
        if Enum.all?(rest, &(&1 == false)) and length(rest) < 8,
          do: {:ok, st.nodes, Enum.reverse(st.matches)},
          else: :error

      _ ->
        :error
    end
  end

  defp walk(_n_tx, _height, _pos, %{bits: []}), do: :error

  defp walk(n_tx, height, pos, %{bits: [flag | bits]} = st) do
    st = %{st | bits: bits}

    if height == 0 or not flag do
      case st.hashes do
        [hash | hashes] ->
          matches = if height == 0 and flag, do: [{pos, hash} | st.matches], else: st.matches

          {:ok, hash,
           %{st | hashes: hashes, matches: matches, nodes: Map.put(st.nodes, {height, pos}, hash)}}

        [] ->
          :error
      end
    else
      with {:ok, left, st} <- walk(n_tx, height - 1, pos * 2, st),
           {:ok, right, st} <- right_child(n_tx, height, pos, left, st) do
        hash = Hash.sha256_sha256(left <> right)
        {:ok, hash, %{st | nodes: Map.put(st.nodes, {height, pos}, hash)}}
      end
    end
  end

  defp right_child(n_tx, height, pos, left, st) do
    if pos * 2 + 1 < width(n_tx, height - 1) do
      case walk(n_tx, height - 1, pos * 2 + 1, st) do
        {:ok, ^left, _st} -> :error
        other -> other
      end
    else
      {:ok, left, st}
    end
  end

  defp tree_branch(nodes, n_tx, index) do
    for h <- 0..(tree_height(n_tx) - 1)//1 do
      pos = Bitwise.bsr(index, h)
      sibling = Bitwise.bxor(pos, 1)
      sibling = if sibling < width(n_tx, h), do: sibling, else: pos
      nodes |> Map.fetch!({h, sibling}) |> display()
    end
  end

  # --- bytes -------------------------------------------------------------------

  # Hashes are displayed big-endian; the tree works in internal order.
  defp internal(hex), do: hex |> Base.decode16!(case: :mixed) |> reverse()
  defp display(bin), do: bin |> reverse() |> Base.encode16(case: :lower)
  defp reverse(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()

  defp cli, do: Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)
end
