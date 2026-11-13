defmodule Bitblocks.Chain.Beef do
  @moduledoc """
  BEEF (BRC-62) and BUMP (BRC-74): a transaction with the merkle evidence that
  lets someone else check it, in the standard binary forms (#17).

  `build/1` answers `GET /api/v1/txs/:txid/beef`: the tx's stored parents, each
  with a BUMP, then the tx with its own BUMP, last as BRC-62 requires. Every
  branch comes from `Chain.MerkleProof`, which also decides what is canonical,
  so a tx in a replaced block gets no BEEF. Proofs from one block share one
  BUMP.

  A proof-bearing tx is valid on its own, so a parent we can't prove (not
  stored, or its proof unavailable) leaves the BEEF valid and is named in
  `parents_missing`, with `complete: false`. Only the tx's own proof is
  required. `@max_parents` bounds the proofs one public request can ask of the
  node; parents past it are listed as missing too.

  The bytes are parsed back before they are returned, by the same strict reader
  that takes BEEF from anyone (`Bitblocks.Chain.Beef.Reader`): each tx's bytes
  must hash to its txid, and each BUMP must climb to the root in the header we
  verified.

  `build(txid, format: :atomic)` gives Atomic BEEF (BRC-95). Its ancestry stops
  at the first tx with a BUMP, and our tx always has one, so Atomic BEEF here is
  that tx and its BUMP alone: a parent would be unrelated data, which the
  reference SDK refuses. The subject is written in internal byte order, as that
  SDK writes it; BRC-95 doesn't say which.

  ## BUMP byte order

  Hashes are stored in internal order in the binary form. Here a leaf is
  `%{offset:, hash: <<32 bytes>> | nil, txid: boolean, duplicate: boolean}`
  with `hash` in that same internal order, and a BUMP is
  `%{height:, path: [[leaf]]}`, `path` indexed by tree level.

  A block of one transaction has the single leaf at level 0 and no higher
  level; its txid is its root.
  """

  import Bitwise

  alias Bitblocks.Chain.{MerkleProof, RawTx}
  alias Bitblocks.Chain.Beef.Reader
  alias Bitblocks.TxStore

  @version <<0x01, 0x00, 0xBE, 0xEF>>
  @atomic_prefix <<0x01, 0x01, 0x01, 0x01>>
  @max_parents 25

  @flag_data 0
  @flag_duplicate 1
  @flag_txid 2

  @trust "each BUMP climbs to the merkle root in a block header bitblocks stored only after " <>
           "checking its proof of work. Check those roots against your own headers."

  # --- building --------------------------------------------------------------

  @doc """
  The BEEF for a stored tx: `{:ok, %{txid, beef (hex), transactions,
  parents_included, parents_missing, complete, block_hash, block_height,
  trust}}`, or the errors of `MerkleProof.build/1`, or `:raw_unavailable`
  when the tx's bytes can't be read. `format: :atomic` gives Atomic BEEF in
  `beef`; `format` in the answer says which it is.
  """
  @spec build(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def build(txid, opts \\ []) when is_binary(txid) do
    format = Keyword.get(opts, :format, :beef)

    with {:ok, proof} <- MerkleProof.build(txid),
         {:ok, raw} <- raw(txid) do
      parents = if format == :atomic, do: [], else: parents(raw)
      {tried, skipped} = Enum.split(parents, @max_parents)
      # Chain order then block order, so a parent that spends another comes after it.
      proven =
        tried
        |> Enum.flat_map(&proven_parent/1)
        |> Enum.sort_by(fn {p, _raw} -> {p.block_height, p.index} end)

      included = Enum.map(proven, fn {parent_proof, _raw} -> parent_proof.txid end)
      missing = (tried -- included) ++ skipped

      entries = proven ++ [{proof, raw}]
      bumps = entries |> Enum.map(fn {p, _} -> from_proof(p) end) |> merge()

      beef =
        bumps
        |> encode(
          Enum.map(entries, fn {p, bytes} -> {bytes, bump_index(bumps, p.block_height)} end)
        )
        |> wrap(format, txid)

      with :ok <- check(beef, entries, txid) do
        {:ok,
         %{
           txid: txid,
           format: format,
           beef: Base.encode16(beef, case: :lower),
           transactions: Enum.map(entries, fn {p, _} -> p.txid end),
           parents_included: included,
           parents_missing: missing,
           complete: missing == [],
           block_hash: proof.block_hash,
           block_height: proof.block_height,
           trust: @trust
         }}
      end
    end
  end

  defp proven_parent(txid) do
    with {:ok, proof} <- MerkleProof.build(txid),
         {:ok, raw} <- raw(txid) do
      [{proof, raw}]
    else
      _ -> []
    end
  end

  defp raw(txid) do
    with {:ok, bytes} <- TxStore.raw(txid),
         ^txid <- TxStore.txid(bytes) do
      {:ok, bytes}
    else
      _ -> {:error, :raw_unavailable}
    end
  end

  defp parents(raw) do
    case RawTx.flows(Base.encode16(raw, case: :lower)) do
      {:ok, %{inputs: inputs}} ->
        inputs |> Enum.flat_map(&prev_txid/1) |> Enum.uniq()

      {:error, _} ->
        []
    end
  end

  defp prev_txid({txid, _vout}), do: [txid]
  defp prev_txid(:coinbase), do: []

  defp bump_index(bumps, height), do: Enum.find_index(bumps, &(&1.height == height))

  defp wrap(beef, :beef, _txid), do: beef
  defp wrap(beef, :atomic, txid), do: atomic(beef, txid)

  @doc """
  Atomic BEEF (BRC-95) around a BEEF: the prefix, then the subject in internal
  byte order, then the BEEF.
  """
  @spec atomic(binary(), String.t()) :: binary()
  def atomic(beef, txid), do: <<@atomic_prefix, internal(txid)::binary, beef::binary>>

  # The whole answer read back: nothing goes out that doesn't check.
  #
  # The reader's byte limit guards the verifier against BEEF from anyone. This
  # BEEF is our own, built from stored bytes already hashed to their txids, so
  # it is held to its own size: a single tx can be larger than that limit
  # (block 971,525 holds one of 43,391,410 bytes, #68), and read back under it
  # the check would fail as if the tree didn't rebuild the root.
  defp check(beef, entries, txid) do
    roots = Map.new(entries, fn {p, _} -> {p.txid, p.merkleroot} end)

    with {:ok, %{bumps: bumps, transactions: txs, subject: ^txid}} <-
           Reader.parse(beef, max_bytes: byte_size(beef)),
         true <- length(txs) == length(entries),
         true <- Enum.all?(txs, &tx_checks?(&1, bumps, roots)) do
      :ok
    else
      _ -> {:error, :merkleroot_mismatch}
    end
  end

  defp tx_checks?(%{txid: txid, bump_index: index}, bumps, roots) when is_integer(index) do
    root(Enum.at(bumps, index), txid) == {:ok, Map.get(roots, txid)}
  end

  defp tx_checks?(_tx, _bumps, _roots), do: false

  # --- BUMP from a proof -------------------------------------------------------

  @doc """
  The BUMP for one `MerkleProof` proof: `txid`, `index`, `siblings` (display
  hex, leaf to root; a level's lone last node is its own sibling) and
  `block_height`.
  """
  @spec from_proof(map()) :: map()
  def from_proof(%{txid: txid, index: index, siblings: siblings, block_height: height}) do
    leaf_hash = internal(txid)

    {levels, _hash} =
      siblings
      |> Enum.with_index()
      |> Enum.map_reduce(leaf_hash, fn {sibling, level}, running ->
        offset = index >>> level
        sibling = internal(sibling)
        duplicate? = sibling == running and band(offset, 1) == 0

        leaf =
          if duplicate? do
            %{offset: bxor(offset, 1), hash: nil, txid: false, duplicate: true}
          else
            %{offset: bxor(offset, 1), hash: sibling, txid: false, duplicate: false}
          end

        pair = if band(offset, 1) == 0, do: running <> sibling, else: sibling <> running
        {leaf, sha256d(pair)}
      end)

    client = %{offset: index, hash: leaf_hash, txid: true, duplicate: false}

    path =
      case levels do
        [] -> [[client]]
        [first | rest] -> [sort([client, first]) | Enum.map(rest, &[&1])]
      end

    %{height: height, path: path}
  end

  @doc """
  Combines BUMPs of one block into one, keeping one per height and order of
  first appearance. A node that the leaves below it can compute is dropped, and
  a leaf that is a client txid in either stays one.
  """
  @spec merge([map()]) :: [map()]
  def merge(bumps) do
    bumps
    |> Enum.group_by(& &1.height)
    |> Enum.map(fn {height, group} -> {first_position(bumps, height), merge_block(group)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp first_position(bumps, height), do: Enum.find_index(bumps, &(&1.height == height))

  defp merge_block([bump]), do: bump

  defp merge_block([%{height: height} | _] = group) do
    depth = group |> Enum.map(&length(&1.path)) |> Enum.max()

    levels =
      for level <- 0..(depth - 1) do
        group
        |> Enum.flat_map(&Enum.at(&1.path, level, []))
        |> Enum.group_by(& &1.offset)
        |> Enum.map(fn {_offset, leaves} ->
          Enum.find(leaves, hd(leaves), & &1.txid)
        end)
      end

    %{height: height, path: trim(levels)}
  end

  # Walks up: a pair known at one level makes its parent known at the next, and
  # a stored leaf for a known parent is redundant.
  defp trim(levels) do
    {path, _known} =
      Enum.map_reduce(levels, MapSet.new(), fn leaves, computed ->
        kept = Enum.reject(leaves, &MapSet.member?(computed, &1.offset))
        {sort(kept), parents_known(kept, computed)}
      end)

    path
  end

  defp parents_known(leaves, computed) do
    offsets = leaves |> Enum.map(& &1.offset) |> MapSet.new() |> MapSet.union(computed)

    for offset <- offsets,
        band(offset, 1) == 0,
        MapSet.member?(offsets, offset + 1),
        into: MapSet.new(),
        do: offset >>> 1
  end

  defp sort(leaves), do: Enum.sort_by(leaves, & &1.offset)

  # --- the root ---------------------------------------------------------------

  @doc """
  Climbs a BUMP from `txid` (display hex) to its merkle root (display hex).
  `{:error, :not_in_bump}` when the txid isn't a leaf at level 0, and
  `{:error, :incomplete}` when a node it needs is missing.
  """
  @spec root(map(), String.t()) :: {:ok, String.t()} | {:error, :not_in_bump | :incomplete}
  def root(bump, txid) do
    with {:ok, root, _offset} <- Reader.root(bump, txid), do: {:ok, root}
  end

  # --- binary ------------------------------------------------------------------

  @doc "Serializes a BUMP (BRC-74)."
  @spec encode_bump(map()) :: binary()
  def encode_bump(%{height: height, path: path}) do
    levels =
      for leaves <- path do
        [varint(length(leaves)) | Enum.map(leaves, &encode_leaf/1)]
      end

    IO.iodata_to_binary([varint(height), length(path), levels])
  end

  defp encode_leaf(%{offset: offset, duplicate: true}),
    do: [varint(offset), @flag_duplicate]

  defp encode_leaf(%{offset: offset, txid: true, hash: hash}),
    do: [varint(offset), @flag_txid, hash]

  defp encode_leaf(%{offset: offset, hash: hash}),
    do: [varint(offset), @flag_data, hash]

  @doc "Reads one BUMP, strictly: `Bitblocks.Chain.Beef.Reader.parse_bump/1`."
  defdelegate parse_bump(binary), to: Reader

  @doc """
  Serializes a BEEF: `bumps`, then `transactions` as `{raw_bytes, bump_index}`
  (`bump_index` nil for a tx with no BUMP of its own), parents first.
  """
  @spec encode([map()], [{binary(), non_neg_integer() | nil}]) :: binary()
  def encode(bumps, transactions) do
    IO.iodata_to_binary([
      @version,
      varint(length(bumps)),
      Enum.map(bumps, &encode_bump/1),
      varint(length(transactions)),
      Enum.map(transactions, fn
        {raw, nil} -> [raw, 0]
        {raw, index} -> [raw, 1, varint(index)]
      end)
    ])
  end

  @doc "Reads a BEEF from anyone, strictly: `Bitblocks.Chain.Beef.Reader.parse/2`."
  defdelegate parse(binary), to: Reader

  defp varint(n) when n < 0xFD, do: <<n>>
  defp varint(n) when n <= 0xFFFF, do: <<0xFD, n::little-16>>
  defp varint(n) when n <= 0xFFFFFFFF, do: <<0xFE, n::little-32>>
  defp varint(n), do: <<0xFF, n::little-64>>

  defp sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))

  defp internal(hex) do
    hex |> Base.decode16!(case: :mixed) |> reverse()
  end

  defp reverse(bytes),
    do: bytes |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
end
