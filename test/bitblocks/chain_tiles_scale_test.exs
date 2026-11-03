defmodule Bitblocks.ChainTilesScaleTest do
  @moduledoc """
  Holds the chain-tile budget on a synthetic ~1M-block input (#48).
  Excluded by default; run with `mix test --only scale`. Prints measured
  numbers; the assertions are the budget from docs/CHAIN_SCRUBBER.md.

  Two parts: the pure pipeline (encode 948 leaf tiles from 970,000 synthetic
  records, roll up three levels) with no database, then the database path on
  50,000 real rows to measure the per-leaf read cost that a full build pays
  ~950 times.
  """
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainTileFixtures

  alias Bitblocks.ChainTiles
  alias Bitblocks.ChainTiles.{Cache, Codec}

  @moduletag :scale
  @moduletag timeout: 600_000

  @blocks 970_000

  defp synthetic_leaf(height) do
    # tx counts over seven orders of magnitude, a gap every 97th block,
    # a missing row every 1,009th
    num_tx =
      cond do
        rem(height, 50_000) == 0 -> 4_000_000
        rem(height, 7_000) == 0 -> 250_000
        height < 100_000 -> 1 + rem(height, 9)
        true -> 10 + rem(height * 7, 3_000)
      end

    state =
      cond do
        rem(height, 1_009) == 0 -> 0
        rem(height, 97) == 0 -> 2
        true -> 6
      end

    %{time: 1_231_006_505 + height * 600, size: 285 + num_tx * 400, num_tx: num_tx, state: state}
  end

  test "the pure pipeline encodes 970,000 blocks into a pyramid within budget" do
    tip = @blocks - 1
    leaf_count = Codec.tile_count(0, tip)
    assert leaf_count == 948

    {encode_us, leaf_tiles} =
      :timer.tc(fn ->
        for idx <- 0..(leaf_count - 1) do
          first = idx * 1024
          leaves = for h <- first..min(first + 1023, tip), do: synthetic_leaf(h)
          Codec.encode_leaf_tile(first, leaves)
        end
      end)

    leaf_bytes = leaf_tiles |> Enum.map(&byte_size/1) |> Enum.sum()

    {rollup_us, {l1, l2, l3}} =
      :timer.tc(fn ->
        leaves =
          Enum.flat_map(leaf_tiles, fn t ->
            {:ok, _, r} = Codec.decode(t)
            r
          end)

        l1 = Codec.rollup_leaves(leaves)
        l2 = Codec.rollup_buckets(l1)
        l3 = Codec.rollup_buckets(l2)
        {l1, l2, l3}
      end)

    l1_tiles =
      l1
      |> Enum.chunk_every(1024)
      |> Enum.with_index()
      |> Enum.map(fn {b, i} -> Codec.encode_bucket_tile(1, i * 32_768, b) end)

    l2_tile = Codec.encode_bucket_tile(2, 0, l2)
    l3_tile = Codec.encode_bucket_tile(3, 0, l3)
    l1_bytes = l1_tiles |> Enum.map(&byte_size/1) |> Enum.sum()

    {hash_us, _} = :timer.tc(fn -> Enum.each(leaf_tiles, &Codec.content_hash/1) end)

    {:ok, %{count: 30}, l3_records} = Codec.decode(l3_tile)
    top = Enum.reduce(l3_records, Codec.empty_bucket(), &Codec.merge_bucket(&2, &1))

    IO.puts("""

    chain tiles scale (synthetic #{@blocks} blocks)
      leaf tiles: #{leaf_count} x #{byte_size(hd(leaf_tiles))} B = #{leaf_bytes} B (#{div(leaf_bytes, 1024)} KiB)
      level 1: #{length(l1_tiles)} tiles, #{l1_bytes} B; level 2: 1 tile, #{byte_size(l2_tile)} B; level 3: 1 tile, #{byte_size(l3_tile)} B
      first frame (level 2 tile): #{byte_size(l2_tile)} B
      encode leaves: #{div(encode_us, 1000)} ms; rollup 3 levels: #{div(rollup_us, 1000)} ms; hash leaves: #{div(hash_us, 1000)} ms
      top bucket: present #{top.present}, completed #{top.completed}, tx_max #{top.tx_max}, hist #{inspect(top.hist)}
    """)

    assert leaf_bytes < 16 * 1024 * 1024
    assert byte_size(l2_tile) < 64 * 1024
    assert encode_us + rollup_us < 60_000_000
    # gaps survive the rollup: 970,000 blocks minus the gaps and missing rows
    assert top.present == @blocks - Enum.count(0..tip, &(rem(&1, 1_009) == 0))
    assert top.completed < top.present
    assert top.tx_max == 4_000_000
  end

  test "the database path reads blocks in 1,024-row batches at a cost a full build can afford" do
    Cache.clear()
    insert_blocks(0..49_999)

    {build_us, {:ok, build}} = :timer.tc(fn -> ChainTiles.build(mode: :full) end)
    per_leaf_ms = build_us / 1000 / build.leaves_scanned

    {noop_us, result} = :timer.tc(fn -> ChainTiles.build(mode: :incremental) end)

    IO.puts("""

    chain tiles database path (50,000 real rows)
      full build: #{build.leaves_scanned} leaves, #{build.tiles_written} tiles, #{div(build_us, 1000)} ms (#{Float.round(per_leaf_ms, 2)} ms per leaf tile)
      projected full build for 948 leaves: #{round(per_leaf_ms * 948)} ms plus rollups
      incremental no-op: #{inspect(result)} in #{div(noop_us, 1000)} ms
    """)

    assert build.leaves_scanned == 49
    assert {:ok, :noop} = result
    assert per_leaf_ms < 200
  end
end
