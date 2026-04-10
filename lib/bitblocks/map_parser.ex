defmodule Bitblocks.MapParser do
  @moduledoc """
  Parses MAP (Magic Attribute Protocol) data from OP_RETURN scripts.

  MAP uses Bitcom address `1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5` and supports
  two actions:

  - `SET` — key-value pairs in alternating push data chunks
  - `DELETE` — list of keys to remove

  In a piped transaction, MAP appears after a `|` separator:

      OP_RETURN | B_ADDR | content | mime | ... | "|" | MAP_ADDR | SET | k1 | v1 | ...

  In a standalone MAP transaction:

      OP_RETURN | MAP_ADDR | SET | k1 | v1 | k2 | v2 | ...
  """

  @map_address "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"
  @pipe "|"

  @type map_record :: %{
          action: :set | :delete,
          keys: %{String.t() => String.t()},
          app: String.t() | nil
        }

  @doc """
  Parses MAP data from a list of OP_RETURN push data chunks.

  Chunks are expected as a list of binaries (already decoded from the script).
  Returns `{:ok, map_record}` or `{:error, reason}`.

  ## Examples

      iex> chunks = ["1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", "SET", "app", "qart", "type", "listing"]
      iex> Bitblocks.MapParser.parse(chunks)
      {:ok, %{action: :set, keys: %{"app" => "qart", "type" => "listing"}, app: "qart"}}
  """
  @spec parse(list(binary())) :: {:ok, map_record()} | {:error, atom()}
  def parse(chunks) when is_list(chunks) do
    chunks
    |> split_protocols()
    |> find_map_segment()
    |> parse_map_segment()
  end

  @doc """
  Parses MAP data from a raw OP_RETURN script hex string.

  Decodes the script into push data chunks, then parses the MAP segment.
  """
  @spec parse_script(binary()) :: {:ok, map_record()} | {:error, atom()}
  def parse_script(script_hex) when is_binary(script_hex) do
    case decode_script(script_hex) do
      {:ok, chunks} -> parse(chunks)
      error -> error
    end
  end

  @doc """
  Extracts all protocol segments from a piped OP_RETURN.

  Returns a list of `{protocol_address, chunks}` tuples.
  """
  @spec extract_protocols(list(binary())) :: [{binary(), list(binary())}]
  def extract_protocols(chunks) when is_list(chunks) do
    chunks
    |> split_protocols()
    |> Enum.map(fn segment ->
      case segment do
        [addr | rest] -> {addr, rest}
        [] -> {nil, []}
      end
    end)
  end

  # Split chunks on pipe separator into protocol segments
  defp split_protocols(chunks) do
    chunks
    |> Enum.chunk_by(&(&1 == @pipe))
    |> Enum.reject(&(&1 == [@pipe]))
  end

  # Find the segment starting with the MAP address
  defp find_map_segment(segments) do
    Enum.find(segments, fn
      [@map_address | _] -> true
      _ -> false
    end)
  end

  # Parse MAP segment into structured data
  defp parse_map_segment(nil), do: {:error, :no_map_segment}

  defp parse_map_segment([@map_address, "SET" | pairs]) do
    keys = pairs_to_map(pairs)
    {:ok, %{action: :set, keys: keys, app: Map.get(keys, "app")}}
  end

  defp parse_map_segment([@map_address, "DELETE" | key_names]) do
    {:ok, %{action: :delete, keys: Map.new(key_names, &{&1, nil}), app: nil}}
  end

  defp parse_map_segment([@map_address | _]) do
    {:error, :unknown_map_action}
  end

  defp parse_map_segment(_), do: {:error, :invalid_map_segment}

  # Convert alternating key-value list to map
  defp pairs_to_map(pairs) do
    pairs
    |> Enum.chunk_every(2)
    |> Enum.reduce(%{}, fn
      [key, value], acc -> Map.put(acc, key, value)
      [key], acc -> Map.put(acc, key, nil)
    end)
  end

  # Decode raw script hex into push data chunks (as UTF-8 strings)
  defp decode_script(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, data} -> {:ok, decode_chunks(data)}
      :error -> {:error, :invalid_hex}
    end
  end

  defp decode_chunks(data), do: decode_chunks(data, [])

  defp decode_chunks(<<>>, acc), do: Enum.reverse(acc)

  # OP_FALSE (0x00) — skip
  defp decode_chunks(<<0x00, rest::binary>>, acc), do: decode_chunks(rest, acc)

  # OP_RETURN (0x6a) — skip
  defp decode_chunks(<<0x6A, rest::binary>>, acc), do: decode_chunks(rest, acc)

  # Direct push (1-75 bytes)
  defp decode_chunks(<<len, rest::binary>>, acc) when len >= 1 and len <= 75 do
    case rest do
      <<chunk::binary-size(len), remaining::binary>> ->
        decode_chunks(remaining, [safe_utf8(chunk) | acc])

      _ ->
        Enum.reverse(acc)
    end
  end

  # OP_PUSHDATA1 (0x4c)
  defp decode_chunks(<<0x4C, len, rest::binary>>, acc) do
    case rest do
      <<chunk::binary-size(len), remaining::binary>> ->
        decode_chunks(remaining, [safe_utf8(chunk) | acc])

      _ ->
        Enum.reverse(acc)
    end
  end

  # OP_PUSHDATA2 (0x4d)
  defp decode_chunks(<<0x4D, len::little-16, rest::binary>>, acc) do
    case rest do
      <<chunk::binary-size(len), remaining::binary>> ->
        decode_chunks(remaining, [safe_utf8(chunk) | acc])

      _ ->
        Enum.reverse(acc)
    end
  end

  # Unknown opcode — skip
  defp decode_chunks(<<_byte, rest::binary>>, acc), do: decode_chunks(rest, acc)

  defp safe_utf8(binary) do
    case :unicode.characters_to_binary(binary) do
      {:error, _, _} -> Base.encode16(binary, case: :lower)
      {:incomplete, _, _} -> Base.encode16(binary, case: :lower)
      text when is_binary(text) -> text
    end
  end
end
