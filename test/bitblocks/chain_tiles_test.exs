defmodule Bitblocks.ChainTilesTest do
  @moduledoc """
  Building chain-scrubber tiles from `blocks` (#48): one leaf tile per 1,024
  heights plus the pyramid above; unchanged input changes nothing; a block
  that changes anywhere in history changes its tile and that tile's
  ancestors; a block that isn't completed is a gap in its tile.
  """
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainTileFixtures

  alias Bitblocks.Chain.Block
  alias Bitblocks.ChainTiles
  alias Bitblocks.ChainTiles.{Cache, Codec, Tile}

  setup do
    Cache.clear()
    :ok
  end

  defp tile!(level, idx), do: Repo.get_by!(Tile, level: level, idx: idx)

  defp hashes do
    Repo.all(from(t in Tile, select: {{t.level, t.idx}, t.hash})) |> Map.new()
  end

  test "a full build writes one leaf tile per 1,024 heights and the pyramid above" do
    insert_blocks(0..2_500)

    assert {:ok, build} = ChainTiles.build(mode: :full)
    assert build.status == "ok"
    assert build.leaves_scanned == 3

    assert ChainTiles.tile_counts() == %{0 => 3, 1 => 1, 2 => 1, 3 => 1}
    assert build.tiles_written == 6

    assert %Tile{first_height: 0, count: 1024} = tile!(0, 0)
    assert %Tile{first_height: 2048, count: 453} = tile!(0, 2)
    assert byte_size(tile!(0, 0).bytes) == 16_416

    {:ok, _, leaves} = Codec.decode(tile!(0, 1).bytes)

    assert Enum.at(leaves, 0) == %{
             time: 1_231_006_505 + 1024 * 600,
             size: 285.0 + 1024,
             num_tx: 1025,
             state: 6
           }

    # level 1: 2,501 blocks in buckets of 32 -> 79 buckets
    assert %Tile{count: 79} = tile!(1, 0)
    {:ok, _, buckets} = Codec.decode(tile!(1, 0).bytes)
    assert hd(buckets).present == 32
    assert List.last(buckets).present == 2_501 - 78 * 32

    # level 2: buckets of 1,024 -> 3; level 3: 1
    assert %Tile{count: 3} = tile!(2, 0)
    {:ok, _, [b0, _b1, b2]} = Codec.decode(tile!(2, 0).bytes)
    assert b0.completed == 1024
    assert b2.completed == 453
    assert %Tile{count: 1} = tile!(3, 0)
    {:ok, _, [top]} = Codec.decode(tile!(3, 0).bytes)
    assert top.completed == 2_501
    assert top.tx_max == 2_501

    # every tile is in the cache too, and the manifest describes them
    assert length(Cache.all()) == 6
    manifest = Cache.manifest()
    assert manifest.tip_height == 2_500

    assert [%{level: 0, tiles: [_, _, _]}, %{level: 1}, %{level: 2}, %{level: 3}] =
             manifest.levels

    assert Enum.all?(hd(manifest.levels).tiles, &is_binary/1)
  end

  test "rebuilding unchanged input writes nothing" do
    insert_blocks(0..2_500)
    {:ok, _} = ChainTiles.build(mode: :full)
    before = hashes()

    assert {:ok, again} = ChainTiles.build(mode: :full)
    assert again.tiles_written == 0
    assert again.tiles_unchanged == 6
    assert hashes() == before
  end

  test "a new tip block changes only the tip tile and its ancestors" do
    insert_blocks(0..2_500)
    {:ok, _} = ChainTiles.build(mode: :full)
    before = hashes()

    insert_blocks([2_501], updated_at: NaiveDateTime.utc_now())
    assert {:ok, build} = ChainTiles.build(mode: :incremental)
    assert build.leaves_scanned == 1

    after_ = hashes()
    changed = for {key, hash} <- after_, Map.get(before, key) != hash, do: key
    assert Enum.sort(changed) == [{0, 2}, {1, 0}, {2, 0}, {3, 0}]
    assert after_[{0, 0}] == before[{0, 0}]
    assert after_[{0, 1}] == before[{0, 1}]
  end

  test "a historic block moving to completed during backfill changes its old tile and its ancestors" do
    insert_blocks(0..1_023)
    insert_blocks(1_024..2_047, state: "header_only")
    insert_blocks(2_048..2_500)
    {:ok, _} = ChainTiles.build(mode: :full)
    before = hashes()

    {:ok, _, leaves} = Codec.decode(tile!(0, 1).bytes)
    assert Enum.all?(leaves, &Codec.gap?(&1.state))

    # backfill completes block 1,500 (updated_at moves)
    Repo.update_all(from(b in Block, where: b.height == 1_500),
      set: [
        sync_state: "completed",
        updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      ]
    )

    assert {:ok, build} = ChainTiles.build(mode: :incremental)
    assert build.leaves_scanned == 1
    assert build.tiles_written == 4

    after_ = hashes()
    changed = for {key, hash} <- after_, Map.get(before, key) != hash, do: key
    assert Enum.sort(changed) == [{0, 1}, {1, 0}, {2, 0}, {3, 0}]

    {:ok, _, leaves} = Codec.decode(tile!(0, 1).bytes)
    assert Enum.count(leaves, &(not Codec.gap?(&1.state))) == 1
    refute Codec.gap?(Enum.at(leaves, 1_500 - 1_024).state)

    {:ok, _, [_, bucket, _]} = Codec.decode(tile!(2, 0).bytes)
    assert bucket.present == 1024
    assert bucket.completed == 1
  end

  test "a bulk sync_state change (orphan recovery at boot) reaches the incremental build" do
    insert_blocks(0..1_023)
    insert_blocks([1_024], state: "txs_syncing")
    {:ok, _} = ChainTiles.build(mode: :full)
    before = hashes()

    assert Bitblocks.Chain.recover_orphaned_blocks() == 1

    assert {:ok, build} = ChainTiles.build(mode: :incremental)
    assert build.leaves_scanned == 1
    assert hashes()[{0, 1}] != before[{0, 1}]
  end

  test "a block whose sync_state isn't completed is a gap in its tile, and a missing height too" do
    insert_blocks(0..9)
    insert_blocks([10], state: "txs_syncing")
    insert_blocks([11], state: "failed")
    # height 12 has no row; 13 is the tip
    insert_blocks([13])

    {:ok, _} = ChainTiles.build(mode: :full)
    {:ok, %{count: 14}, leaves} = Codec.decode(tile!(0, 0).bytes)

    refute Codec.gap?(Enum.at(leaves, 9).state)
    assert %{state: 5, num_tx: 11} = Enum.at(leaves, 10)
    assert Codec.gap?(Enum.at(leaves, 10).state)
    assert Codec.gap?(Enum.at(leaves, 11).state)
    assert %{state: 0, num_tx: 0, time: 0} = Enum.at(leaves, 12)
    assert Codec.gap?(Enum.at(leaves, 12).state)
    refute Codec.gap?(Enum.at(leaves, 13).state)

    {:ok, _, [bucket]} = Codec.decode(tile!(1, 0).bytes)
    assert bucket.present == 13
    assert bucket.completed == 11
  end

  test "an incremental build is a no-op without a full build, and when nothing changed" do
    insert_blocks(0..100)
    assert {:ok, :no_full_build} = ChainTiles.build(mode: :incremental)
    assert ChainTiles.tile_counts() == %{}

    {:ok, _} = ChainTiles.build(mode: :full)
    # the overlap window reaches 120 s back; the fixtures are a day old
    assert {:ok, :noop} = ChainTiles.build(mode: :incremental)
    assert length(ChainTiles.list_builds()) == 1
  end

  test "a build with no blocks is a no-op" do
    assert {:ok, :noop} = ChainTiles.build(mode: :full)
  end

  test "tiles past a shortened tip are pruned" do
    insert_blocks(0..2_500)
    {:ok, _} = ChainTiles.build(mode: :full)
    Repo.delete_all(from(b in Block, where: b.height >= 1_024))

    {:ok, _} = ChainTiles.build(mode: :full)
    assert ChainTiles.tile_counts() == %{0 => 1, 1 => 1, 2 => 1, 3 => 1}
    assert Cache.fetch(0, 2) == :miss
    assert Cache.manifest().tip_height == 1_023
  end

  test "the cache warms from the table" do
    insert_blocks(0..10)
    {:ok, _} = ChainTiles.build(mode: :full)
    Cache.clear()
    assert Cache.manifest() == nil

    assert {:ok, 4} = Cache.warm()
    assert {:ok, %Tile{idx: 0}} = Cache.fetch(0, 0)
  end

  test "another node's cache reconciles to the table: changed tiles reload, removed tiles drop" do
    insert_blocks(0..1_100)
    {:ok, _} = ChainTiles.build(mode: :full)
    # simulate a second node that cached the earlier state
    %Tile{} = stale_tile = Repo.get_by!(Tile, level: 0, idx: 1)
    Cache.clear()
    Cache.put(stale_tile)
    Cache.put(%{stale_tile | idx: 7, hash: "gone"})

    insert_blocks([1_101], updated_at: NaiveDateTime.utc_now())
    Phoenix.PubSub.subscribe(Bitblocks.PubSub, "chain_tiles")
    {:ok, _} = ChainTiles.build(mode: :incremental)
    assert_receive {:chain_tiles, :changed, _node}

    # this node's write-through already put the new tile; reset to the stale view
    Cache.clear()
    Cache.put(stale_tile)
    Cache.put(%{stale_tile | idx: 7, hash: "gone"})

    assert {:ok, 5} = Cache.reconcile()
    assert Cache.fetch(0, 7) == :miss
    assert {:ok, %Tile{count: 78}} = Cache.fetch(0, 1)
    assert length(Cache.all()) == 5
    assert {:ok, 0} = Cache.reconcile()
  end
end
