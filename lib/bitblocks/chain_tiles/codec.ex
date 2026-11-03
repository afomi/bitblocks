defmodule Bitblocks.ChainTiles.Codec do
  @moduledoc """
  The binary tile format for the chain scrubber (#48), and the rollup rules.

  Pure: no database. `Bitblocks.ChainTiles` reads `blocks` and calls in here.

  A tile holds up to 1,024 records, little-endian, after a 32-byte header.
  Level 0 records are one block each (16 bytes); level `L >= 1` records are
  buckets of `32^L` blocks (64 bytes). Level `L`, tile `t` covers heights
  `[t * 1024 * 32^L, (t + 1) * 1024 * 32^L)`. See `docs/CHAIN_SCRUBBER.md`.

  Rollup keeps what a mean would hide: a bucket says how many of its blocks
  are present and how many are `completed` (the rest are gaps), the largest
  block by size and by tx count, the sums, and an eight-bin log10 histogram
  of tx counts. Nothing is averaged away.
  """

  @magic "BBT1"
  @version 1
  @tile_records 1024
  @fan_out 32
  @max_level 3
  @leaf_record_bytes 16
  @bucket_record_bytes 64
  @header_bytes 32
  @hist_bins 8

  @states ~w(missing pending header_only header_synced txs_queued txs_syncing completed failed)
  @completed_code 6

  @type leaf :: %{time: non_neg_integer(), size: number(), num_tx: non_neg_integer(), state: 0..7}
  @type bucket :: %{
          present: non_neg_integer(),
          completed: non_neg_integer(),
          time_min: non_neg_integer(),
          time_max: non_neg_integer(),
          size_sum: number(),
          tx_sum: number(),
          size_max: number(),
          tx_max: non_neg_integer(),
          hist: [non_neg_integer()]
        }
  @type header :: %{
          level: 0..3,
          record_bytes: 16 | 64,
          first_height: non_neg_integer(),
          count: non_neg_integer(),
          span: pos_integer()
        }

  def tile_records, do: @tile_records
  def fan_out, do: @fan_out
  def max_level, do: @max_level
  def header_bytes, do: @header_bytes
  def completed_code, do: @completed_code
  def states, do: @states

  @doc "Blocks per record at `level`: `32^level`."
  @spec span(0..3) :: pos_integer()
  def span(level) when level in 0..@max_level, do: Integer.pow(@fan_out, level)

  @doc "Blocks per tile at `level`."
  @spec tile_blocks(0..3) :: pos_integer()
  def tile_blocks(level), do: @tile_records * span(level)

  @doc "The tile index at `level` that covers `height`."
  @spec tile_index(non_neg_integer(), 0..3) :: non_neg_integer()
  def tile_index(height, level) when height >= 0, do: div(height, tile_blocks(level))

  @doc "The first height of tile `idx` at `level`."
  @spec first_height(0..3, non_neg_integer()) :: non_neg_integer()
  def first_height(level, idx), do: idx * tile_blocks(level)

  @doc "How many tiles `level` needs to cover heights `0..tip`."
  @spec tile_count(0..3, integer()) :: non_neg_integer()
  def tile_count(_level, tip) when tip < 0, do: 0
  def tile_count(level, tip), do: div(tip, tile_blocks(level)) + 1

  @doc "The numeric state code for a `blocks.sync_state`; `nil` (no row) is `missing`."
  @spec state_code(String.t() | nil) :: 0..7
  def state_code(nil), do: 0

  def state_code(sync_state) when is_binary(sync_state) do
    Enum.find_index(@states, &(&1 == sync_state)) || 0
  end

  @doc "A block that is not `completed` draws as a gap."
  @spec gap?(0..7) :: boolean()
  def gap?(state), do: state != @completed_code

  @doc "The log10 histogram bin for a tx count, or `nil` for zero."
  @spec hist_bin(non_neg_integer()) :: nil | 0..7
  def hist_bin(0), do: nil

  def hist_bin(num_tx) when num_tx > 0,
    do: num_tx |> :math.log10() |> floor() |> min(@hist_bins - 1)

  # -- Encoding ----------------------------------------------------------------

  @doc """
  Encodes a level-0 tile from `leaves`, one per height from `first_height`,
  in order. Returns the tile bytes.
  """
  @spec encode_leaf_tile(non_neg_integer(), [leaf()]) :: binary()
  def encode_leaf_tile(first_height, leaves) when length(leaves) <= @tile_records do
    body =
      for %{time: time, size: size, num_tx: num_tx, state: state} <- leaves, into: <<>> do
        <<time::little-unsigned-32, size * 1.0::little-float-32, num_tx::little-unsigned-32,
          state::unsigned-8, 0::24>>
      end

    header(0, @leaf_record_bytes, first_height, length(leaves)) <> body
  end

  @doc "Encodes a bucket tile (level `>= 1`)."
  @spec encode_bucket_tile(1..3, non_neg_integer(), [bucket()]) :: binary()
  def encode_bucket_tile(level, first_height, buckets)
      when level in 1..@max_level and length(buckets) <= @tile_records do
    body = for bucket <- buckets, into: <<>>, do: encode_bucket(bucket)
    header(level, @bucket_record_bytes, first_height, length(buckets)) <> body
  end

  defp encode_bucket(bucket) do
    hist = for n <- bucket.hist, into: <<>>, do: <<min(n, 65_535)::little-unsigned-16>>

    <<bucket.present::little-unsigned-32, bucket.completed::little-unsigned-32,
      bucket.time_min::little-unsigned-32, bucket.time_max::little-unsigned-32,
      bucket.size_sum * 1.0::little-float-64, bucket.tx_sum * 1.0::little-float-64,
      bucket.size_max * 1.0::little-float-32, bucket.tx_max::little-unsigned-32>> <>
      hist <> <<0::64>>
  end

  # Bytes 20..31 are reserved (zero). The build time lives in the manifest and
  # the row, not the bytes, so unchanged input encodes to identical bytes and
  # the same content hash: that is what makes rebuilds change nothing.
  defp header(level, record_bytes, first_height, count) do
    <<@magic, @version::unsigned-8, level::unsigned-8, record_bytes::little-unsigned-16,
      first_height::little-unsigned-32, count::little-unsigned-32,
      span(level)::little-unsigned-32, 0::96>>
  end

  # -- Decoding ----------------------------------------------------------------

  @doc "Decodes a tile into its header and records."
  @spec decode(binary()) :: {:ok, header(), [leaf()] | [bucket()]} | {:error, term()}
  def decode(
        <<@magic, @version::unsigned-8, level::unsigned-8, record_bytes::little-unsigned-16,
          first_height::little-unsigned-32, count::little-unsigned-32, span::little-unsigned-32,
          _reserved::96, body::binary>>
      ) do
    header = %{
      level: level,
      record_bytes: record_bytes,
      first_height: first_height,
      count: count,
      span: span
    }

    cond do
      byte_size(body) != count * record_bytes ->
        {:error, :bad_length}

      level == 0 and record_bytes == @leaf_record_bytes ->
        {:ok, header, decode_leaves(body, [])}

      level > 0 and record_bytes == @bucket_record_bytes ->
        {:ok, header, decode_buckets(body, [])}

      true ->
        {:error, :bad_record_size}
    end
  end

  def decode(<<@magic, version::unsigned-8, _::binary>>) when version != @version,
    do: {:error, {:unsupported_version, version}}

  def decode(_), do: {:error, :bad_magic}

  defp decode_leaves(<<>>, acc), do: Enum.reverse(acc)

  defp decode_leaves(
         <<time::little-unsigned-32, size::little-float-32, num_tx::little-unsigned-32,
           state::unsigned-8, _::24, rest::binary>>,
         acc
       ) do
    decode_leaves(rest, [%{time: time, size: size, num_tx: num_tx, state: state} | acc])
  end

  defp decode_buckets(<<>>, acc), do: Enum.reverse(acc)

  defp decode_buckets(
         <<present::little-unsigned-32, completed::little-unsigned-32,
           time_min::little-unsigned-32, time_max::little-unsigned-32, size_sum::little-float-64,
           tx_sum::little-float-64, size_max::little-float-32, tx_max::little-unsigned-32,
           hist::binary-size(16), _::64, rest::binary>>,
         acc
       ) do
    bucket = %{
      present: present,
      completed: completed,
      time_min: time_min,
      time_max: time_max,
      size_sum: size_sum,
      tx_sum: tx_sum,
      size_max: size_max,
      tx_max: tx_max,
      hist: for(<<n::little-unsigned-16 <- hist>>, do: n)
    }

    decode_buckets(rest, [bucket | acc])
  end

  # -- Rollup ------------------------------------------------------------------

  @doc "An empty bucket: nothing present, nothing completed."
  @spec empty_bucket() :: bucket()
  def empty_bucket do
    %{
      present: 0,
      completed: 0,
      time_min: 0,
      time_max: 0,
      size_sum: 0.0,
      tx_sum: 0.0,
      size_max: 0.0,
      tx_max: 0,
      hist: List.duplicate(0, @hist_bins)
    }
  end

  @doc """
  Rolls `leaves` (level-0 records, in height order) up into buckets of
  `fan_out` blocks. A missing block (`state` 0) is counted in neither
  `present` nor `completed`; a present but not `completed` block counts in
  `present` only, so `span - completed` is the bucket's gap count.
  """
  @spec rollup_leaves([leaf()]) :: [bucket()]
  def rollup_leaves(leaves) do
    leaves
    |> Enum.chunk_every(@fan_out)
    |> Enum.map(fn chunk -> Enum.reduce(chunk, empty_bucket(), &add_leaf(&2, &1)) end)
  end

  @doc "Rolls buckets up one level: `fan_out` buckets become one."
  @spec rollup_buckets([bucket()]) :: [bucket()]
  def rollup_buckets(buckets) do
    buckets
    |> Enum.chunk_every(@fan_out)
    |> Enum.map(fn chunk -> Enum.reduce(chunk, empty_bucket(), &merge_bucket(&2, &1)) end)
  end

  @doc false
  def add_leaf(bucket, %{state: 0}), do: bucket

  def add_leaf(bucket, %{time: time, size: size, num_tx: num_tx, state: state}) do
    hist =
      case hist_bin(num_tx) do
        nil -> bucket.hist
        bin -> List.update_at(bucket.hist, bin, &(&1 + 1))
      end

    %{
      present: bucket.present + 1,
      completed: bucket.completed + if(state == @completed_code, do: 1, else: 0),
      time_min: if(bucket.present == 0, do: time, else: min(bucket.time_min, time)),
      time_max: max(bucket.time_max, time),
      size_sum: bucket.size_sum + size,
      tx_sum: bucket.tx_sum + num_tx,
      size_max: max(bucket.size_max, size * 1.0),
      tx_max: max(bucket.tx_max, num_tx),
      hist: hist
    }
  end

  @doc false
  def merge_bucket(acc, %{present: 0}), do: acc

  def merge_bucket(%{present: 0}, bucket), do: bucket

  def merge_bucket(acc, bucket) do
    %{
      present: acc.present + bucket.present,
      completed: acc.completed + bucket.completed,
      time_min: min(acc.time_min, bucket.time_min),
      time_max: max(acc.time_max, bucket.time_max),
      size_sum: acc.size_sum + bucket.size_sum,
      tx_sum: acc.tx_sum + bucket.tx_sum,
      size_max: max(acc.size_max, bucket.size_max),
      tx_max: max(acc.tx_max, bucket.tx_max),
      hist: Enum.zip_with(acc.hist, bucket.hist, &(&1 + &2))
    }
  end

  @doc "The content hash a tile is addressed by: the first 8 bytes of its sha256, hex."
  @spec content_hash(binary()) :: String.t()
  def content_hash(bytes) do
    :crypto.hash(:sha256, bytes) |> binary_part(0, 8) |> Base.encode16(case: :lower)
  end
end
