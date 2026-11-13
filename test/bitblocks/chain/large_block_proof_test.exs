defmodule Bitblocks.Chain.LargeBlockProofTest do
  # #68: proofs on the shapes of the real large blocks.
  #
  #   * 971,506: 143.7 MB, 616,080 txs. Over the 10,000-txid threshold, so its
  #     list isn't stored and `/proof` reads the node's `gettxoutproof`.
  #   * 971,525: 145,950,168 bytes, 367 txs, the largest 43,391,410 bytes. Its
  #     list is stored, so `/proof` climbs from it, and its BEEF carries a tx
  #     larger than the BEEF reader's 16 MB limit for input from anyone.
  #
  # A merkleblock for 616,080 txs is built here the way a node builds one
  # (Bitcoin Core's TraverseAndBuild) but in O(log n): a subtree off the
  # matched leaf's path is one opaque hash in a merkleblock, so it can be any
  # hash. Where every leaf is given, the tree is real and the two paths
  # (stored list and node blob) must give the same siblings.
  #
  # RpcStub is one shared table, so not async.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures
  import Bitwise

  alias Bitblocks.Chain.{Beef, Block, MerkleProof, MerkleVerifier}
  alias Bitblocks.Repo
  alias BitblocksWeb.RpcStub

  @n_971_506 616_080
  @n_971_525 367

  setup do
    RpcStub.setup()
    :ok
  end

  describe "a 616,080-tx block (971,506's count): the node's gettxoutproof" do
    test "the last tx: odd levels pair it with itself, and it climbs to the root" do
      index = @n_971_506 - 1
      %{txid: txid, root: root} = node_proof_block(@n_971_506, index)

      assert {:ok, proof} = MerkleProof.build(txid)
      assert proof.source == "gettxoutproof"
      assert proof.index == index
      assert proof.merkleroot == root
      # bit_length(616,079): the tree is 20 levels high.
      assert length(proof.siblings) == 20
      assert MerkleProof.climb(txid, index, proof.siblings) == root

      # The levels where the last node stands alone: an odd width. The last
      # tx's ancestor is that lone node, so its sibling is its own hash.
      lone_levels = lone_ancestor_levels(@n_971_506, index)
      assert lone_levels == [4, 5, 6, 8, 11, 12, 15, 17, 18]
      assert self_paired_levels(txid, index, proof.siblings) == lone_levels
    end

    test "the coinbase and a middle tx climb to the same kind of root" do
      for index <- [0, 1, div(@n_971_506, 2), @n_971_506 - 2] do
        %{txid: txid, root: root} = node_proof_block(@n_971_506, index)

        assert {:ok, %{source: "gettxoutproof", index: ^index, siblings: siblings}} =
                 MerkleProof.build(txid)

        assert length(siblings) == 20
        assert MerkleProof.climb(txid, index, siblings) == root

        assert self_paired_levels(txid, index, siblings) ==
                 lone_ancestor_levels(@n_971_506, index)
      end
    end

    test "its BUMP has the block's tree height and climbs to the root through the binary form" do
      index = @n_971_506 - 1
      %{txid: txid, root: root, height: height} = node_proof_block(@n_971_506, index)
      {:ok, proof} = MerkleProof.build(txid)

      {:ok, bump, ""} = proof |> Beef.from_proof() |> Beef.encode_bump() |> Beef.parse_bump()

      # BeefVerifier holds a BUMP to bit_length(num_tx - 1) levels.
      assert length(bump.path) == bit_length(@n_971_506 - 1)
      assert bump.height == height
      assert Beef.root(bump, txid) == {:ok, root}

      duplicates = bump.path |> List.flatten() |> Enum.count(& &1.duplicate)
      assert duplicates == 9
    end

    test "a blob whose tx count disagrees with its tree is not a proof" do
      index = @n_971_506 - 1
      %{txid: txid, block: block} = node_proof_block(@n_971_506, index)

      # The same hashes and flags, read as a tree one tx wider: the walk no
      # longer consumes them as built, so nothing climbs to the root.
      bad =
        merkleblock_hex(
          block_header(block),
          @n_971_506 + 1,
          node_tree(@n_971_506, index, leaf(txid))
        )

      RpcStub.stub_gettxoutproof([txid], block.hash, bad)

      assert {:error, :merkleroot_mismatch} = MerkleProof.build(txid)
    end
  end

  describe "the stored list and the node's blob agree on real trees" do
    test "every leaf of uneven trees gets the same siblings from either path" do
      for n <- [1, 2, 3, 5, 7, 12, 13, 31, 33], index <- 0..(n - 1) do
        txids = txids(n)
        root = root_of(txids)
        txid = Enum.at(txids, index)

        stored = MerkleProof.branch(txids, index)
        assert MerkleProof.climb(txid, index, stored) == root, "n=#{n} index=#{index}"

        %{txid: ^txid} = node_proof_block(n, index, txids)
        assert {:ok, %{source: "gettxoutproof", siblings: ^stored}} = MerkleProof.build(txid)
      end
    end
  end

  describe "a 367-tx block (971,525's count): its stored txid list" do
    setup do
      txids = txids(@n_971_525)
      root = root_of(txids)
      height = unique_block_height()

      block =
        block_fixture(%{
          height: height,
          hash: hex32("block-971525-#{height}"),
          merkleroot: root,
          num_tx: @n_971_525,
          tx: txids,
          nextblockhash: nil
        })

      %{txids: txids, root: root, block: block}
    end

    test "the last tx, the coinbase and one between climb from the stored list", %{
      txids: txids,
      root: root,
      block: block
    } do
      for index <- [0, 200, @n_971_525 - 1] do
        txid = Enum.at(txids, index)
        tx_row(txid, block)

        assert {:ok, proof} = MerkleProof.build(txid)
        assert proof.source == "block_txids"
        assert proof.index == index
        # bit_length(366)
        assert length(proof.siblings) == 9
        assert MerkleProof.climb(txid, index, proof.siblings) == root
      end
    end
  end

  describe "BEEF for a tx larger than the BEEF reader's limit" do
    # 971,525's largest tx is 43,391,410 bytes; 17 MB is enough to pass the
    # reader's 16 MB limit and keeps the test light.
    @big_tx_bytes 17_000_000

    test "is built and checked, not refused as a root mismatch" do
      # Served BEEF is capped at the reader's limit (Beef.max_bytes/0); raised
      # here, so the read-back of our own BEEF is still tested past it.
      Application.put_env(:bitblocks, :beef_serve_max_bytes, 64_000_000)
      on_exit(fn -> Application.delete_env(:bitblocks, :beef_serve_max_bytes) end)

      raw = big_coinbase(@big_tx_bytes)
      assert byte_size(raw) > Bitblocks.Chain.Beef.Reader.limits().max_bytes
      txid = display(sha256d(raw))
      height = unique_block_height()

      # One tx: its txid is the root.
      block =
        block_fixture(%{
          height: height,
          hash: hex32("block-big-#{height}"),
          merkleroot: txid,
          num_tx: 1,
          tx: [txid],
          nextblockhash: nil
        })

      tx_row(txid, block)

      Repo.update_all(
        Ecto.Query.from(t in "transactions", where: t.txid == ^txid),
        set: [raw: Base.encode16(raw, case: :lower)]
      )

      assert {:ok, built} = Beef.build(txid)
      assert built.complete
      assert built.transactions == [txid]

      beef = Base.decode16!(built.beef, case: :lower)
      assert byte_size(beef) > byte_size(raw)

      {:ok, parsed} = Bitblocks.Chain.Beef.Reader.parse(beef, max_bytes: byte_size(beef))
      assert [%{txid: ^txid, raw: ^raw}] = parsed.transactions
      assert Beef.root(hd(parsed.bumps), txid) == {:ok, txid}

      # Input from anyone is still held to the limit.
      assert {:error, :too_large} = Beef.parse(beef)
    end

    test "over the served cap it is too_large" do
      raw = big_coinbase(@big_tx_bytes)
      txid = display(sha256d(raw))
      height = unique_block_height()

      block =
        block_fixture(%{
          height: height,
          hash: hex32("block-cap-#{height}"),
          merkleroot: txid,
          num_tx: 1,
          tx: [txid],
          nextblockhash: nil
        })

      tx_row(txid, block)

      Repo.update_all(
        Ecto.Query.from(t in "transactions", where: t.txid == ^txid),
        set: [raw: Base.encode16(raw, case: :lower)]
      )

      assert {:error, :too_large} = Beef.build(txid)
    end
  end

  # --- blocks and rows ---------------------------------------------------------

  # A block whose txid list isn't stored, a tx row at `index`, and the node's
  # merkleblock for it. With `txids` the tree is real; without, the leaf is
  # synthetic and every subtree off its path is opaque.
  defp node_proof_block(n_tx, index, txids \\ nil) do
    txid = if txids, do: Enum.at(txids, index), else: hex32("leaf-#{n_tx}-#{index}")
    tree = node_tree(n_tx, index, leaf(txid), txids && List.to_tuple(Enum.map(txids, &leaf/1)))
    height = unique_block_height()

    header =
      <<1::little-32, sha256d("prev-#{height}")::binary, tree.root::binary,
        1_700_000_000::little-32, 0x1D00FFFF::little-32, height::little-32>>

    block =
      block_fixture(%{
        height: height,
        hash: display(sha256d(header)),
        merkleroot: display(tree.root),
        num_tx: n_tx,
        tx: [],
        nextblockhash: nil
      })

    tx_row(txid, block)
    RpcStub.stub_gettxoutproof([txid], block.hash, merkleblock_hex(header, n_tx, tree))

    %{txid: txid, root: display(tree.root), block: block, height: height}
  end

  defp block_header(%Block{height: height, merkleroot: root}) do
    <<1::little-32, sha256d("prev-#{height}")::binary, leaf(root)::binary,
      1_700_000_000::little-32, 0x1D00FFFF::little-32, height::little-32>>
  end

  defp tx_row(txid, block) do
    transaction_fixture(%{txid: txid, block_hash: block.hash, block_height: block.height})
  end

  # --- a merkleblock, as a node builds it --------------------------------------

  # Bitcoin Core's TraverseAndBuild for one matched leaf: a flag per visited
  # node (does its subtree hold the match?), and a hash for each node not
  # descended into. Depth-first, left before right; a right child past the
  # level's width is skipped (its parent pairs the left with itself).
  defp node_tree(n_tx, index, leaf, leaves \\ nil) do
    ctx = %{n: n_tx, index: index, leaf: leaf, leaves: leaves}
    top = tree_height(n_tx)
    {flags, hashes} = build(ctx, top, 0, {[], []})
    %{root: node_hash(ctx, top, 0), flags: Enum.reverse(flags), hashes: Enum.reverse(hashes)}
  end

  defp build(ctx, h, pos, {flags, hashes}) do
    on_path = ctx.index >>> h == pos
    flags = [on_path | flags]

    if h == 0 or not on_path do
      {flags, [node_hash(ctx, h, pos) | hashes]}
    else
      acc = build(ctx, h - 1, pos * 2, {flags, hashes})
      if pos * 2 + 1 < width(ctx.n, h - 1), do: build(ctx, h - 1, pos * 2 + 1, acc), else: acc
    end
  end

  defp node_hash(%{index: index, leaf: leaf}, 0, pos) when pos == index, do: leaf
  defp node_hash(%{leaves: leaves}, 0, pos) when is_tuple(leaves), do: elem(leaves, pos)

  defp node_hash(ctx, h, pos) do
    if ctx.index >>> h == pos or is_tuple(ctx.leaves) do
      left = node_hash(ctx, h - 1, pos * 2)

      right =
        if pos * 2 + 1 < width(ctx.n, h - 1), do: node_hash(ctx, h - 1, pos * 2 + 1), else: left

      sha256d(left <> right)
    else
      # Off the matched path: one opaque hash in the merkleblock.
      sha256d(<<h::32, pos::32>>)
    end
  end

  defp merkleblock_hex(header, n_tx, %{flags: flags, hashes: hashes}) do
    flag_bytes =
      flags
      |> Enum.chunk_every(8, 8, Stream.cycle([false]))
      |> Enum.map(fn bits ->
        bits
        |> Enum.with_index()
        |> Enum.reduce(0, fn {b, i}, acc -> if b, do: acc ||| 1 <<< i, else: acc end)
      end)

    (header <>
       <<n_tx::little-32>> <>
       varint(length(hashes)) <>
       Enum.join(hashes) <> varint(length(flag_bytes)) <> :binary.list_to_bin(flag_bytes))
    |> Base.encode16(case: :lower)
  end

  defp width(n, h), do: (n + (1 <<< h) - 1) >>> h
  defp tree_height(n), do: tree_height(n, 0)
  defp tree_height(n, h), do: if(width(n, h) > 1, do: tree_height(n, h + 1), else: h)

  defp bit_length(0), do: 0
  defp bit_length(n), do: 1 + bit_length(n >>> 1)

  # --- trees from whole lists ----------------------------------------------------

  defp txids(n), do: for(i <- 1..n, do: hex32("tx-#{n}-#{i}"))

  defp root_of(txids) do
    root = MerkleProof.climb(hd(txids), 0, MerkleProof.branch(txids, 0))
    assert MerkleVerifier.verify(txids, root) == :ok
    root
  end

  # The levels where `index`'s ancestor is the last node of an odd-width level.
  defp lone_ancestor_levels(n, index) do
    for h <- 0..(tree_height(n) - 1)//1,
        rem(width(n, h), 2) == 1,
        index >>> h == width(n, h) - 1,
        do: h
  end

  # The levels where the sibling is the running hash itself.
  defp self_paired_levels(txid, index, siblings) do
    {levels, _} =
      siblings
      |> Enum.with_index()
      |> Enum.reduce({[], leaf(txid)}, fn {sib_hex, h}, {acc, running} ->
        sib = leaf(sib_hex)
        acc = if sib == running, do: [h | acc], else: acc
        pair = if band(index >>> h, 1) == 0, do: running <> sib, else: sib <> running
        {acc, sha256d(pair)}
      end)

    Enum.reverse(levels)
  end

  # --- a tx larger than the reader's limit ---------------------------------------

  # A coinbase-shaped tx (no parents to look up) with one OP_FALSE OP_RETURN
  # output carrying `size` bytes.
  defp big_coinbase(size) do
    script = <<0x00, 0x6A>> <> :binary.copy(<<0xAB>>, size)

    <<1::little-32, 1, 0::256, 0xFFFFFFFF::little-32, 3, "big", 0xFFFFFFFF::little-32, 1,
      0::little-64>> <> varint(byte_size(script)) <> script <> <<0::little-32>>
  end

  # --- bytes -------------------------------------------------------------------

  defp varint(n) when n < 0xFD, do: <<n>>
  defp varint(n) when n <= 0xFFFF, do: <<0xFD, n::little-16>>
  defp varint(n) when n <= 0xFFFFFFFF, do: <<0xFE, n::little-32>>

  defp hex32(seed), do: display(:crypto.hash(:sha256, seed))
  defp leaf(hex), do: hex |> Base.decode16!(case: :mixed) |> reverse()
  defp display(bin), do: bin |> reverse() |> Base.encode16(case: :lower)
  defp reverse(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
  defp sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))
end
