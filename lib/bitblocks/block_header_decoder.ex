defmodule Bitblocks.BlockHeaderDecoder do
  @moduledoc """
  Decodes Bitcoin block headers from raw hex (verbosity 0) format.

  Block header format (80 bytes):
  - Version (4 bytes)
  - Previous block hash (32 bytes)
  - Merkle root (32 bytes)
  - Timestamp (4 bytes)
  - Bits/difficulty target (4 bytes)
  - Nonce (4 bytes)

  After the header comes the transaction count as a variable-length integer,
  followed by all transactions.
  """

  @doc """
  Decodes a block header from hex string (verbosity 0 response).

  Returns a map with:
  - version
  - prevblockhash
  - merkleroot
  - time
  - bits
  - nonce
  - num_tx (extracted from var_int after header)
  - size (total block size in bytes)

  ## Example

      iex> hex = "01000000..." # 80-byte header + var_int + txs
      iex> BlockHeaderDecoder.decode(hex)
      %{
        version: 1,
        prevblockhash: "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f",
        merkleroot: "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b",
        time: 1231006505,
        bits: "1d00ffff",
        nonce: 2083236893,
        num_tx: 1,
        size: 285
      }
  """
  def decode(hex_string) when is_binary(hex_string) do
    # Remove any whitespace and convert to binary
    binary =
      hex_string
      |> String.replace(~r/\s/, "")
      |> Base.decode16!(case: :mixed)

    # Block header is first 80 bytes
    <<
      version::little-unsigned-32,
      prev_block::binary-size(32),
      merkle_root::binary-size(32),
      timestamp::little-unsigned-32,
      bits::little-unsigned-32,
      nonce::little-unsigned-32,
      rest::binary
    >> = binary

    # Read variable-length integer for transaction count
    {num_tx, _tx_data} = decode_var_int(rest)

    %{
      version: version,
      prevblockhash: prev_block |> reverse_bytes() |> Base.encode16(case: :lower),
      merkleroot: merkle_root |> reverse_bytes() |> Base.encode16(case: :lower),
      time: timestamp,
      bits: bits |> :binary.encode_unsigned(:little) |> Base.encode16(case: :lower),
      nonce: nonce,
      num_tx: num_tx,
      size: byte_size(binary)
    }
  end

  @doc """
  Extracts just the block hash from hex-encoded block data.

  The block hash is the double SHA256 of the 80-byte header.
  """
  def hash(hex_string) when is_binary(hex_string) do
    binary =
      hex_string
      |> String.replace(~r/\s/, "")
      |> Base.decode16!(case: :mixed)

    # Extract first 80 bytes (block header)
    <<header::binary-size(80), _rest::binary>> = binary

    # Double SHA256
    header
    |> sha256()
    |> sha256()
    |> reverse_bytes()
    |> Base.encode16(case: :lower)
  end

  # Private helpers

  # Bitcoin uses little-endian for hashes, so we reverse bytes for display
  defp reverse_bytes(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> :binary.list_to_bin()
  end

  defp sha256(data) do
    :crypto.hash(:sha256, data)
  end

  # Decode variable-length integer (CompactSize)
  # https://en.bitcoin.it/wiki/Protocol_documentation#Variable_length_integer
  defp decode_var_int(<<value, rest::binary>>) when value < 0xFD do
    {value, rest}
  end

  defp decode_var_int(<<0xFD, value::little-unsigned-16, rest::binary>>) do
    {value, rest}
  end

  defp decode_var_int(<<0xFE, value::little-unsigned-32, rest::binary>>) do
    {value, rest}
  end

  defp decode_var_int(<<0xFF, value::little-unsigned-64, rest::binary>>) do
    {value, rest}
  end
end
