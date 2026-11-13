defmodule Bitblocks.FlowTilesTest do
  use Bitblocks.DataCase, async: false

  import Bitblocks.FirstSpendFixtures
  import Bitblocks.ChainTileFixtures

  alias Bitblocks.ChainTiles.Cache
  alias Bitblocks.FlowTiles
  alias Bitblocks.FlowTiles.Codec
  alias Bitblocks.Chain.Transaction
  alias Bitblocks.Repo

  setup do
    Cache.clear()
    on_exit(fn -> Cache.clear() end)
    :ok
  end

  # The first spend with the columns the tally reads: its one input and two
  # outputs, and each tx's sats out.
  defp first_spend_with_tallies do
    insert_first_spend()

    Repo.update_all(
      from(t in Transaction, where: t.txid == ^first_spend()),
      set: [
        inputs: [~s({"txid":"#{coinbase_9()}","vout":0})],
        input_txids: [coinbase_9()],
        outputs: ["{}", "{}"],
        total_output_satoshis: 5_000_000_000
      ]
    )

    Repo.update_all(
      from(t in Transaction, where: t.txid in ^[coinbase_9(), coinbase_170()]),
      set: [
        inputs: [~s({"coinbase":"04ffff001d"})],
        outputs: ["{}"],
        total_output_satoshis: 5_000_000_000
      ]
    )
  end

  defp records do
    level = FlowTiles.level()
    {:ok, tile} = Cache.fetch(level, 0)
    {:ok, header, records} = Codec.decode(tile.bytes)
    {header, records}
  end

  describe "codec" do
    test "age bins double: 0, 1, 2-3, 4-7, ... and clamp at 2^14" do
      assert Enum.map([0, 1, 2, 3, 4, 7, 8, 161, 16_383, 16_384, 900_000], &Codec.age_bin/1) ==
               [0, 1, 2, 2, 3, 3, 4, 8, 14, 15, 15]
    end

    test "a tile round-trips, 96 bytes a record after a 32-byte header" do
      rec = %{Codec.empty() | time: 7, num_tx: 3, stored: 3, n_in: 2, sats_out: -1}
      rec = %{rec | hist: List.replace_at(rec.hist, 8, 2)}
      bytes = Codec.encode(1024, [Codec.empty(), rec])
      assert byte_size(bytes) == 32 + 2 * 96
      assert {:ok, %{first_height: 1024, count: 2}, [_, ^rec]} = Codec.decode(bytes)
    end
  end

  test "the first spend: block 170 spends coins 161 blocks old" do
    first_spend_with_tallies()

    assert {:ok, %{from: 0, through: 200, behind: false, tiles_written: 1}} =
             FlowTiles.build(from: 0, through: 200)

    {%{first_height: 0, count: 201}, records} = records()

    b9 = Enum.at(records, 9)
    assert %{num_tx: 1, stored: 1, n_in: 0, n_out: 1, sats_out: 5_000_000_000} = b9
    assert Enum.sum(b9.hist) == 0

    b170 = Enum.at(records, 170)
    assert %{time: 1_231_731_025, num_tx: 2, stored: 2, n_in: 1, n_out: 3, unknown: 0} = b170
    assert b170.sats_out == 10_000_000_000
    assert Enum.at(b170.hist, Codec.age_bin(161)) == 1
    assert Enum.sum(b170.hist) == 1

    # A height with no block is a record of zeros.
    assert Enum.at(records, 10) == Codec.empty()
  end

  test "an input whose source we don't hold counts as unknown, with no age" do
    first_spend_with_tallies()
    Repo.delete_all(from(t in Transaction, where: t.txid == ^coinbase_9()))

    {:ok, _} = FlowTiles.build(from: 0, through: 200)
    {_, records} = records()
    assert %{n_in: 1, unknown: 1} = Enum.at(records, 170)
    assert Enum.sum(Enum.at(records, 170).hist) == 0
  end

  test "does nothing before a first build, then resumes after the highest height built" do
    first_spend_with_tallies()

    assert FlowTiles.build(through: 200) == {:ok, :not_started}
    assert FlowTiles.built_through() == nil

    {:ok, %{through: 100}} = FlowTiles.build(from: 0, through: 100)
    assert FlowTiles.built_through() == 100
    assert FlowTiles.build(through: 100) == {:ok, :noop}

    {:ok, %{from: 101, through: 200}} = FlowTiles.build(through: 200)
    {%{count: 201}, records} = records()
    assert Enum.at(records, 9).stored == 1
    assert Enum.at(records, 170).n_in == 1
  end

  test "a run stops at its budget between tiles and says it is behind" do
    insert_blocks(0..1_100, num_tx: 1)

    assert {:ok, %{through: 1_023, behind: true}} =
             FlowTiles.build(from: 0, through: 1_100, budget_ms: 0)

    assert {:ok, %{from: 1_024, through: 1_100, behind: false}} = FlowTiles.build(through: 1_100)
    assert FlowTiles.built_through() == 1_100
    assert %{tiles: 2, built_through: 1_100} = FlowTiles.status()
  end

  test "the flow manifest names the built height and each tile's hash; chain tiles ignore them" do
    insert_blocks(0..1_100, num_tx: 1)
    {:ok, _} = FlowTiles.build(from: 0, through: 1_100)

    manifest = Cache.flow_manifest()
    assert %{built_through: 1_100, tile_records: 1024, record_bytes: 96, age_bins: 16} = manifest
    assert [h0, h1] = manifest.tiles
    assert is_binary(h0) and is_binary(h1)

    # The chain scrubber's manifest is built from its own levels only.
    assert Cache.manifest() == nil
  end
end
