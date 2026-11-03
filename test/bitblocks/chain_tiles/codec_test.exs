defmodule Bitblocks.ChainTiles.CodecTest do
  @moduledoc """
  The tile bytes and the rollup rules (#48): a gap survives encoding and
  rollup, the format is fixed-size, and unchanged input hashes the same.
  """
  use ExUnit.Case, async: true

  alias Bitblocks.ChainTiles.Codec

  defp leaf(num_tx, state, opts \\ []) do
    %{
      time: Keyword.get(opts, :time, 1_231_006_505),
      size: Keyword.get(opts, :size, 285),
      num_tx: num_tx,
      state: state
    }
  end

  @completed 6
  @header_only 2

  describe "leaf tiles" do
    test "encode a 32-byte header and 16 bytes per block, and round-trip" do
      leaves = [leaf(1, @completed), leaf(4_000_000, @header_only, size: 3.9e9), leaf(0, 0)]
      bytes = Codec.encode_leaf_tile(2048, leaves)

      assert byte_size(bytes) == 32 + 3 * 16
      assert {:ok, header, records} = Codec.decode(bytes)
      assert header == %{level: 0, record_bytes: 16, first_height: 2048, count: 3, span: 1}

      assert [%{num_tx: 1, state: 6}, %{num_tx: 4_000_000, state: 2, size: size}, %{state: 0}] =
               records

      # size is a float32: a 3.9 GB block keeps better than 0.01 % precision
      assert_in_delta size, 3.9e9, 3.9e9 * 1.0e-4
    end

    test "a full tile is 16,416 bytes" do
      bytes = Codec.encode_leaf_tile(0, List.duplicate(leaf(1, @completed), 1024))
      assert byte_size(bytes) == 16_416
    end

    test "a block whose sync_state isn't completed is flagged as a gap" do
      for state <- ~w(pending header_only header_synced txs_queued txs_syncing failed) do
        code = Codec.state_code(state)
        bytes = Codec.encode_leaf_tile(0, [leaf(10, code)])
        {:ok, _, [record]} = Codec.decode(bytes)
        assert Codec.gap?(record.state), "#{state} should be a gap"
      end

      {:ok, _, [record]} =
        Codec.decode(Codec.encode_leaf_tile(0, [leaf(10, Codec.state_code("completed"))]))

      refute Codec.gap?(record.state)
      assert Codec.gap?(Codec.state_code(nil)), "a missing row is a gap"
    end

    test "the same input encodes to the same bytes and hash; a change changes the hash" do
      a = Codec.encode_leaf_tile(0, [leaf(1, @completed), leaf(2, @completed)])
      b = Codec.encode_leaf_tile(0, [leaf(1, @completed), leaf(2, @completed)])
      c = Codec.encode_leaf_tile(0, [leaf(1, @completed), leaf(2, @header_only)])

      assert a == b
      assert Codec.content_hash(a) == Codec.content_hash(b)
      refute Codec.content_hash(a) == Codec.content_hash(c)
      assert String.length(Codec.content_hash(a)) == 16
    end

    test "decode rejects bad magic, versions and lengths" do
      assert {:error, :bad_magic} = Codec.decode("nope")
      assert {:error, {:unsupported_version, 9}} = Codec.decode("BBT1" <> <<9>> <> <<0::216>>)
      good = Codec.encode_leaf_tile(0, [leaf(1, @completed)])
      assert {:error, :bad_length} = Codec.decode(good <> <<1>>)
    end
  end

  describe "rollup" do
    test "a bucket says how many of its blocks are present and completed; gaps are not averaged away" do
      leaves =
        List.duplicate(leaf(100, @completed), 20) ++
          List.duplicate(leaf(50, @header_only), 7) ++
          List.duplicate(leaf(0, 0), 5)

      [bucket] = Codec.rollup_leaves(leaves)

      assert bucket.present == 27
      assert bucket.completed == 20
      # the 12 gaps: 7 known headers not completed + 5 missing rows
      assert Codec.span(1) - bucket.completed == 12
      assert bucket.tx_max == 100
      assert bucket.tx_sum == 20 * 100 + 7 * 50
    end

    test "max, sum, time range and the log10 histogram" do
      leaves = [
        leaf(1, @completed, time: 100, size: 200),
        leaf(9, @completed, time: 50, size: 100),
        leaf(1_000, @completed, time: 300, size: 10_000),
        leaf(4_000_000, @completed, time: 200, size: 4_000_000_000)
      ]

      [bucket] = Codec.rollup_leaves(leaves)

      assert bucket.time_min == 50
      assert bucket.time_max == 300
      assert bucket.tx_max == 4_000_000
      assert bucket.size_max == 4_000_000_000.0
      assert bucket.tx_sum == 4_001_010
      assert bucket.size_sum == 4_000_010_300.0
      # bins: 1 -> 0, 9 -> 0, 1_000 -> 3, 4_000_000 -> 6
      assert bucket.hist == [2, 0, 0, 1, 0, 0, 1, 0]
    end

    test "hist_bin clamps seven orders of magnitude into eight bins" do
      assert Codec.hist_bin(0) == nil
      assert Codec.hist_bin(1) == 0
      assert Codec.hist_bin(10) == 1
      assert Codec.hist_bin(999) == 2
      assert Codec.hist_bin(1_000_000) == 6
      assert Codec.hist_bin(99_999_999) == 7
      assert Codec.hist_bin(1_000_000_000) == 7
    end

    test "rolling buckets up a level merges counts, keeps the max and the gaps" do
      buckets =
        List.duplicate(Codec.rollup_leaves(List.duplicate(leaf(10, @completed), 32)) |> hd(), 31) ++
          [Codec.rollup_leaves(List.duplicate(leaf(1_000_000, @header_only), 32)) |> hd()]

      [merged] = Codec.rollup_buckets(buckets)

      assert merged.present == 1024
      assert merged.completed == 31 * 32
      assert Codec.span(2) - merged.completed == 32
      assert merged.tx_max == 1_000_000
      assert Enum.at(merged.hist, 1) == 31 * 32
      assert Enum.at(merged.hist, 6) == 32
    end

    test "bucket tiles are 64 bytes a record and round-trip" do
      buckets = Codec.rollup_leaves(List.duplicate(leaf(7, @completed), 64))
      bytes = Codec.encode_bucket_tile(1, 0, buckets)

      assert byte_size(bytes) == 32 + 2 * 64
      assert {:ok, %{level: 1, span: 32, count: 2}, decoded} = Codec.decode(bytes)
      assert decoded == buckets
    end
  end

  describe "geometry" do
    test "levels, spans, and tile indices" do
      assert Codec.span(0) == 1
      assert Codec.span(1) == 32
      assert Codec.span(2) == 1024
      assert Codec.span(3) == 32_768
      assert Codec.tile_blocks(0) == 1024
      assert Codec.tile_blocks(2) == 1_048_576
      assert Codec.tile_index(1023, 0) == 0
      assert Codec.tile_index(1024, 0) == 1
      assert Codec.tile_index(970_000, 0) == 947
      assert Codec.tile_index(970_000, 1) == 29
      assert Codec.tile_index(970_000, 2) == 0
      assert Codec.tile_count(0, 970_000) == 948
      assert Codec.tile_count(1, 970_000) == 30
      assert Codec.tile_count(2, 970_000) == 1
      assert Codec.tile_count(3, 970_000) == 1
      assert Codec.tile_count(0, -1) == 0
    end
  end
end
