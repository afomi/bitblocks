defmodule Bitblocks.Chain.BeefTest do
  # #17: pinned to the example vectors in BRC-74 and BRC-62, then to real
  # blocks. RpcStub is one shared table, so not async.
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.{Beef, Block, MerkleProof, MerkleVerifier}
  alias Bitblocks.FirstSpendFixtures
  alias Bitblocks.Repo
  alias BitblocksWeb.RpcStub

  @fixtures Path.expand("../../support/fixtures/brc", __DIR__)

  # BRC-74's three client txids and the root its code computes.
  @brc74_root "57aab6e6fb1b697174ffb64e062c4728f2ffd33ddcfa02a43b64d8cd29b483b4"
  # The root in the header of block 814435, the block of BRC-62's example,
  # as a block explorer reports it.
  @brc62_root "bb6f640cc4ee56bf38eb5a1969ac0c16caa2d3d202b22bf3735d10eec0ca6e00"

  @hash_170 "00000000d1145790a8694403d4063f323d499e655c83426834d4ce2f8dd4a2ee"
  @root_170 "7dac2c5666815c17a3b36427de37bb9d2e2c5ccec3f8633eb91a4205cb4c10ff"
  @hash_9 "000000008d9dc510f23c2657fc4f67bea30078cc05a90eb89e84cc475c080805"

  defp vector(name) do
    @fixtures |> Path.join(name) |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
  end

  defp txid(bytes), do: Bitblocks.TxStore.txid(bytes)

  describe "BRC-74 example" do
    setup do
      bytes = vector("brc74_bump.hex")
      {:ok, bump, ""} = Beef.parse_bump(bytes)
      %{bytes: bytes, bump: bump}
    end

    test "parses to block 813706, tree height 12", %{bump: bump} do
      assert bump.height == 813_706
      assert length(bump.path) == 12
    end

    test "serializes back to the same bytes", %{bump: bump, bytes: bytes} do
      assert Beef.encode_bump(bump) == bytes
    end

    test "the spec's txids climb to its root", %{bump: bump} do
      txids =
        for %{hash: hash} when is_binary(hash) <- hd(bump.path) do
          hash
          |> :binary.bin_to_list()
          |> Enum.reverse()
          |> :binary.list_to_bin()
          |> Base.encode16(case: :lower)
        end

      for prefix <- ~w(304e737f d888711d 98c9c5dd) do
        assert Enum.any?(txids, &String.starts_with?(&1, prefix))
      end

      for txid <- txids, do: assert(Beef.root(bump, txid) == {:ok, @brc74_root})
    end

    test "a txid that isn't a leaf has no root", %{bump: bump} do
      assert Beef.root(bump, String.duplicate("ab", 32)) == {:error, :not_in_bump}
    end
  end

  describe "BRC-62 example" do
    setup do
      bytes = vector("brc62_beef.hex")
      {:ok, beef} = Beef.parse(bytes)
      %{bytes: bytes, beef: beef}
    end

    test "parses: one BUMP, the parent proven by it, the payment last with none", %{beef: beef} do
      assert [%{height: 814_435}] = beef.bumps
      assert [%{bump_index: 0}, %{bump_index: nil}] = beef.transactions
    end

    test "serializes back to the same bytes", %{beef: beef, bytes: bytes} do
      assert Beef.encode(
               beef.bumps,
               Enum.map(beef.transactions, &{&1.raw, &1.bump_index})
             ) == bytes
    end

    test "the parent climbs to the root in block 814435's real header", %{beef: beef} do
      [parent | _] = beef.transactions
      assert Beef.root(hd(beef.bumps), txid(parent.raw)) == {:ok, @brc62_root}
    end
  end

  describe "BUMPs from proofs" do
    # Five leaves: an odd count, so the last node pairs with itself at two levels.
    @txids for n <- 1..5, do: String.duplicate("0#{n}", 32)

    defp proof(txids, index, height \\ 7) do
      %{
        txid: Enum.at(txids, index),
        index: index,
        siblings: MerkleProof.branch(txids, index),
        block_height: height
      }
    end

    defp header_root(txids) do
      root = MerkleProof.climb(hd(txids), 0, MerkleProof.branch(txids, 0))
      assert MerkleVerifier.verify(txids, root) == :ok
      root
    end

    test "each leaf of an odd tree climbs to the block's root, through the binary form" do
      for index <- 0..4 do
        {:ok, bump, ""} =
          @txids |> proof(index) |> Beef.from_proof() |> Beef.encode_bump() |> Beef.parse_bump()

        assert Beef.root(bump, Enum.at(@txids, index)) == {:ok, header_root(@txids)}
      end
    end

    test "the last leaf's lone sibling is a duplicate flag, not a hash" do
      bump = @txids |> proof(4) |> Beef.from_proof()

      assert [%{offset: 4, txid: true}, %{offset: 5, duplicate: true, hash: nil}] = hd(bump.path)
    end

    test "a one-transaction block: the txid is the root" do
      [txid | _] = @txids
      bump = Beef.from_proof(%{txid: txid, index: 0, siblings: [], block_height: 9})

      assert [[%{offset: 0, txid: true}]] = bump.path
      assert Beef.root(bump, txid) == {:ok, txid}
    end

    test "merging one block's proofs keeps every root and drops what it can compute" do
      bumps = for index <- 0..4, do: @txids |> proof(index) |> Beef.from_proof()
      assert [merged] = Beef.merge(bumps)

      for txid <- @txids, do: assert(Beef.root(merged, txid) == {:ok, header_root(@txids)})
      assert length(Enum.at(merged.path, 0)) == 6
      assert Enum.all?(tl(merged.path), &(length(&1) <= 1))

      {:ok, again, ""} = merged |> Beef.encode_bump() |> Beef.parse_bump()
      assert Beef.root(again, hd(@txids)) == {:ok, header_root(@txids)}
    end

    test "two proofs from one block mark both txids as clients" do
      [merged] =
        Beef.merge([Beef.from_proof(proof(@txids, 0)), Beef.from_proof(proof(@txids, 1))])

      assert [%{offset: 0, txid: true}, %{offset: 1, txid: true}] = hd(merged.path)
    end

    test "different blocks stay separate, first seen first" do
      first = Beef.from_proof(proof(@txids, 0, 20))
      second = Beef.from_proof(proof(@txids, 1, 10))

      assert [%{height: 20}, %{height: 10}] = Beef.merge([first, second])
    end
  end

  describe "block 814435, a real 106-transaction block" do
    setup do
      txids =
        @fixtures
        |> Path.join("block_814435_txids.txt")
        |> File.read!()
        |> String.split("\n", trim: true)

      %{txids: txids}
    end

    test "merged proofs across an uneven tree reach its real root", %{txids: txids} do
      proofs =
        for index <- [0, 1, 50, 104, 105] do
          %{
            txid: Enum.at(txids, index),
            index: index,
            siblings: MerkleProof.branch(txids, index),
            block_height: 814_435
          }
        end

      for proof <- proofs do
        assert proof |> Beef.from_proof() |> Beef.root(proof.txid) == {:ok, @brc62_root}
      end

      [merged] = proofs |> Enum.map(&Beef.from_proof/1) |> Beef.merge()
      {:ok, parsed, ""} = merged |> Beef.encode_bump() |> Beef.parse_bump()

      for proof <- proofs, do: assert(Beef.root(parsed, proof.txid) == {:ok, @brc62_root})
    end
  end

  describe "build/1 on real blocks" do
    setup do
      RpcStub.setup()
      FirstSpendFixtures.insert_first_spend()

      for {height, hash, root} <- [
            {170, @hash_170, @root_170},
            {9, @hash_9, FirstSpendFixtures.coinbase_9()}
          ] do
        fixture_hash = height |> Integer.to_string() |> String.pad_leading(64, "b")

        Repo.update_all(
          Ecto.Query.from(t in "transactions", where: t.block_hash == ^fixture_hash),
          set: [block_hash: hash]
        )

        Repo.get_by!(Block, height: height)
        |> Ecto.Changeset.change(%{hash: hash, merkleroot: root, nextblockhash: nil})
        |> Repo.update!()
      end

      :ok
    end

    test "the first spend: parent with its BUMP, then the tx with its own" do
      assert {:ok, built} = Beef.build(FirstSpendFixtures.first_spend())

      assert built.complete
      assert built.parents_included == [FirstSpendFixtures.coinbase_9()]

      assert built.transactions == [
               FirstSpendFixtures.coinbase_9(),
               FirstSpendFixtures.first_spend()
             ]

      {:ok, parsed} = built.beef |> Base.decode16!(case: :lower) |> Beef.parse()

      assert [%{height: 9}, %{height: 170}] = parsed.bumps
      assert [%{bump_index: 0} = parent, %{bump_index: 1} = tx] = parsed.transactions

      assert txid(parent.raw) == FirstSpendFixtures.coinbase_9()
      assert txid(tx.raw) == FirstSpendFixtures.first_spend()

      assert Beef.root(Enum.at(parsed.bumps, 1), FirstSpendFixtures.first_spend()) ==
               {:ok, @root_170}
    end

    test "a coinbase has no parents, and is complete" do
      assert {:ok, %{complete: true, parents_included: []}} =
               Beef.build(FirstSpendFixtures.coinbase_9())
    end

    test "a parent we can't prove is named, and the BEEF still stands" do
      Repo.get_by!(Block, height: 9) |> Repo.delete!()

      assert {:ok, built} = Beef.build(FirstSpendFixtures.first_spend())

      refute built.complete
      assert built.parents_missing == [FirstSpendFixtures.coinbase_9()]
      assert built.transactions == [FirstSpendFixtures.first_spend()]
    end

    test "a tx in a replaced block gets none" do
      Repo.get_by!(Block, height: 170) |> Repo.delete!()

      assert {:error, :not_canonical} = Beef.build(FirstSpendFixtures.first_spend())
    end
  end

  test "an unknown tx is not found" do
    block_fixture()
    assert {:error, :not_found} = Beef.build(String.duplicate("ab", 32))
  end

  test "parse refuses other formats and trailing bytes" do
    assert {:error, _} = Beef.parse(<<1, 0, 0, 0>>)

    {:ok, _} = Beef.parse(vector("brc62_beef.hex"))
    assert {:error, _} = Beef.parse(vector("brc62_beef.hex") <> <<0>>)
  end
end
