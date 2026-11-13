defmodule Bitblocks.FlowTiles.Codec do
  @moduledoc """
  The binary flow tile format for the `/tx-graph` far view (#67).

  Pure: no database. `Bitblocks.FlowTiles` reads the tallies and calls in here.

  A tile holds up to 1,024 records, one per block, little-endian, after a
  32-byte header. Tile `t` covers heights `[t * 1024, (t + 1) * 1024)`.

  Header: magic `BBF1`, version u8, age bins u8, record bytes u16, first
  height u32, count u32, 16 reserved bytes.

  Record (96 bytes): time u32, num_tx u32 (the header's count), stored u32
  (txs we hold), n_in u32 (inputs of the non-coinbase txs), n_out u32,
  unknown u32 (inputs with no stored source, so no age), sats_out f64 (-1
  when a tx in the block has no stored tally), then 16 x u32: inputs by the
  age of the coins they spend, in blocks. Bin 0 is age 0 (spent in the block
  that made it); bin `b` is `2^(b-1) <= age < 2^b`; bin 15 is `age >= 2^14`.

  A record of all zeros is a block not built yet.
  """

  @magic "BBF1"
  @version 1
  @tile_records 1024
  @record_bytes 96
  @header_bytes 32
  @age_bins 16

  @type record :: %{
          time: non_neg_integer(),
          num_tx: non_neg_integer(),
          stored: non_neg_integer(),
          n_in: non_neg_integer(),
          n_out: non_neg_integer(),
          unknown: non_neg_integer(),
          sats_out: number(),
          hist: [non_neg_integer()]
        }

  def tile_records, do: @tile_records
  def record_bytes, do: @record_bytes
  def header_bytes, do: @header_bytes
  def age_bins, do: @age_bins

  @doc "The tile index that covers `height`."
  def tile_index(height) when height >= 0, do: div(height, @tile_records)

  @doc "The first height of tile `idx`."
  def first_height(idx), do: idx * @tile_records

  @doc "The age bin for coins `age` blocks old."
  @spec age_bin(non_neg_integer()) :: 0..15
  def age_bin(age) when age <= 0, do: 0

  def age_bin(age) do
    # floor(log2(age)) + 1, without float error at powers of two.
    bits = age |> Integer.digits(2) |> length()
    min(bits, @age_bins - 1)
  end

  @doc "A record for a block not built yet."
  @spec empty() :: record()
  def empty do
    %{
      time: 0,
      num_tx: 0,
      stored: 0,
      n_in: 0,
      n_out: 0,
      unknown: 0,
      sats_out: 0,
      hist: List.duplicate(0, @age_bins)
    }
  end

  @doc "Encodes a tile from `records`, one per height from `first_height`."
  @spec encode(non_neg_integer(), [record()]) :: binary()
  def encode(first_height, records) when length(records) <= @tile_records do
    body = for r <- records, into: <<>>, do: encode_record(r)

    <<@magic::binary, @version::8, @age_bins::8, @record_bytes::little-16,
      first_height::little-32, length(records)::little-32, 0::128>> <> body
  end

  defp encode_record(r) do
    hist = for n <- r.hist, into: <<>>, do: <<clamp(n)::little-unsigned-32>>

    <<clamp(r.time)::little-unsigned-32, clamp(r.num_tx)::little-unsigned-32,
      clamp(r.stored)::little-unsigned-32, clamp(r.n_in)::little-unsigned-32,
      clamp(r.n_out)::little-unsigned-32, clamp(r.unknown)::little-unsigned-32,
      r.sats_out * 1.0::little-float-64, hist::binary>>
  end

  defp clamp(n) when is_integer(n), do: n |> max(0) |> min(0xFFFFFFFF)
  defp clamp(_), do: 0

  @doc "Decodes a tile into its header and records."
  @spec decode(binary()) :: {:ok, map(), [record()]} | {:error, :bad_tile}
  def decode(
        <<@magic::binary, @version::8, @age_bins::8, @record_bytes::little-16,
          first_height::little-32, count::little-32, _reserved::binary-size(16), body::binary>>
      )
      when byte_size(body) == count * @record_bytes do
    records = for <<rec::binary-size(@record_bytes) <- body>>, do: decode_record(rec)
    {:ok, %{first_height: first_height, count: count}, records}
  end

  def decode(_), do: {:error, :bad_tile}

  defp decode_record(
         <<time::little-unsigned-32, num_tx::little-unsigned-32, stored::little-unsigned-32,
           n_in::little-unsigned-32, n_out::little-unsigned-32, unknown::little-unsigned-32,
           sats_out::little-float-64, hist::binary-size(64)>>
       ) do
    %{
      time: time,
      num_tx: num_tx,
      stored: stored,
      n_in: n_in,
      n_out: n_out,
      unknown: unknown,
      sats_out: if(sats_out < 0, do: -1, else: trunc(sats_out)),
      hist: for(<<n::little-unsigned-32 <- hist>>, do: n)
    }
  end

  @doc "The content hash a tile URL carries: the first 16 hex chars of its sha256."
  def content_hash(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) |> binary_part(0, 16)
end
