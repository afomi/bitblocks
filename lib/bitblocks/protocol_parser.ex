defmodule Bitblocks.ProtocolParser do
  @moduledoc """
  Composes B://, MAP, and AIP segments from piped OP_RETURN data
  into structured, protocol-specific records.

  A piped OP_RETURN looks like:

      OP_RETURN | B_ADDR | content | mime | ... | "|" | MAP_ADDR | SET | k1 | v1 | ... | "|" | AIP_ADDR | algo | addr | sig

  This module splits the pipe, delegates to existing parsers (MapParser,
  ContentDetector), and assembles the results into a single map keyed
  by protocol name.
  """

  alias Bitblocks.MapParser

  @b_address "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"
  @map_address "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"
  @aip_address "15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva"

  @doc """
  Parses a stored transaction struct into structured protocol data.

  Requires the transaction to have a non-nil `raw` field.
  """
  @spec parse_transaction(%{raw: binary() | nil}, String.t()) ::
          {:ok, map()} | {:error, atom()}
  def parse_transaction(%{raw: nil}, _protocol), do: {:error, :no_raw_data}
  def parse_transaction(%{raw: raw}, protocol), do: parse_raw(raw, protocol)

  @doc """
  Parses a raw transaction hex string into structured protocol data.

  Decodes the full transaction, extracts OP_RETURN outputs, and parses
  the piped protocol segments.
  """
  @spec parse_raw(binary(), String.t()) :: {:ok, map()} | {:error, atom()}
  def parse_raw(raw_hex, protocol) when is_binary(raw_hex) do
    case Bitblocks.Chain.SafeTx.from_hex(raw_hex) do
      {:ok, tx} ->
        op_returns = Bitblocks.TransactionParser.extract_op_returns(tx.outputs)
        parse_op_returns(op_returns, protocol)

      {:error, _} ->
        {:error, :invalid_raw}
    end
  end

  @doc """
  Parses an OP_RETURN script hex string directly into structured protocol data.

  Useful for testing with raw script hex fixtures.
  """
  @spec parse_script(binary(), String.t()) :: {:ok, map()} | {:error, atom()}
  def parse_script(script_hex, protocol) when is_binary(script_hex) do
    # Decode script into push data chunks in the same format as
    # TransactionParser.parse_op_return_data/1
    chunks =
      decode_script_chunks(script_hex)
      |> Enum.map(fn text ->
        %{
          type: :push_data,
          utf8: (if String.printable?(text), do: text, else: nil),
          hex: Base.encode16(text, case: :lower),
          length: byte_size(text)
        }
      end)

    case build_protocol_data(chunks, protocol) do
      {:ok, _} = result -> result
      {:error, _} = err -> err
    end
  end

  # -- Private ----------------------------------------------------------------

  defp parse_op_returns([], _protocol), do: {:error, :no_op_return}

  defp parse_op_returns(op_returns, protocol) do
    # Try each OP_RETURN output until we find one with matching protocol data
    Enum.find_value(op_returns, {:error, :no_protocol_data}, fn op_return ->
      case build_protocol_data(op_return.data, protocol) do
        {:ok, data} -> {:ok, data}
        _ -> nil
      end
    end)
  end

  defp build_protocol_data(data_chunks, "Twetch") do
    # Twetch uses piped protocols: B:// | MAP | AIP
    utf8_chunks =
      data_chunks
      |> Enum.filter(&match?(%{type: :push_data, utf8: utf8} when is_binary(utf8), &1))
      |> Enum.map(& &1.utf8)

    segments = MapParser.extract_protocols(utf8_chunks)

    b_data = find_segment(segments, @b_address)
    map_data = find_segment(segments, @map_address)
    aip_data = find_segment(segments, @aip_address)

    # Twetch is identified by MAP app=twetch, not by its own Bitcom address
    case parse_map_set(map_data) do
      %{"app" => "twetch"} = map_keys ->
        {:ok,
         %{
           protocol: "Twetch",
           type: nullify(Map.get(map_keys, "type")),
           content: parse_b_content(b_data),
           content_type: parse_b_field(b_data, 1),
           encoding: parse_b_field(b_data, 2),
           filename: parse_b_field(b_data, 3),
           app: "twetch",
           user_id: nullify(Map.get(map_keys, "mb_user")),
           timestamp: parse_twetch_timestamp(Map.get(map_keys, "timestamp")),
           reply_to: nullify(Map.get(map_keys, "comment")),
           url: nullify(Map.get(map_keys, "url")),
           signing_algorithm: parse_aip_field(aip_data, 0),
           signing_address: parse_aip_field(aip_data, 1),
           signature: parse_aip_field(aip_data, 2)
         }}

      _ ->
        {:error, :not_twetch}
    end
  end

  defp build_protocol_data(data_chunks, "Metanet") do
    # Metanet uses raw OP_RETURN chunks (not piped):
    # "meta" <P_node> <TxID_parent> [<name>] [<content_type>] [<content>]
    Bitblocks.MetanetParser.parse(data_chunks)
  end

  defp build_protocol_data(data_chunks, "OrderBook") do
    # OrderBook uses raw OP_RETURN chunks (not piped):
    # "orderbook" <op> <fields...>
    Bitblocks.OrderBookParser.parse(data_chunks)
  end

  defp build_protocol_data(_data_chunks, _protocol), do: {:error, :unsupported_protocol}

  defp find_segment(segments, address) do
    Enum.find_value(segments, nil, fn
      {^address, data} -> data
      _ -> nil
    end)
  end

  # Parse MAP SET pairs into a key-value map
  defp parse_map_set(nil), do: %{}

  defp parse_map_set(["SET" | pairs]) do
    pairs
    |> Enum.chunk_every(2)
    |> Enum.reduce(%{}, fn
      [key, value], acc -> Map.put(acc, key, value)
      [key], acc -> Map.put(acc, key, nil)
    end)
  end

  defp parse_map_set(_), do: %{}

  # B:// segment: [content, content_type, encoding, filename]
  defp parse_b_content(nil), do: nil
  defp parse_b_content([content | _]), do: content
  defp parse_b_content(_), do: nil

  defp parse_b_field(nil, _index), do: nil
  defp parse_b_field(fields, index), do: Enum.at(fields, index)

  # AIP segment: [algorithm, address, signature]
  defp parse_aip_field(nil, _index), do: nil
  defp parse_aip_field(fields, index), do: Enum.at(fields, index)

  # Convert "null" strings to nil
  defp nullify("null"), do: nil
  defp nullify(value), do: value

  # Twetch timestamps are in an unusual high-precision format.
  # Return as-is (string) rather than guessing the epoch.
  defp parse_twetch_timestamp(nil), do: nil
  defp parse_twetch_timestamp("null"), do: nil
  defp parse_twetch_timestamp(ts), do: ts

  # Decode raw script hex into UTF-8 chunks for extract_protocols
  defp decode_script_chunks(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, data} -> do_decode_chunks(data, [])
      :error -> []
    end
  end

  defp do_decode_chunks(<<>>, acc), do: Enum.reverse(acc)
  defp do_decode_chunks(<<0x00, rest::binary>>, acc), do: do_decode_chunks(rest, acc)
  defp do_decode_chunks(<<0x6A, rest::binary>>, acc), do: do_decode_chunks(rest, acc)

  defp do_decode_chunks(<<len, rest::binary>>, acc) when len >= 1 and len <= 75 do
    case rest do
      <<chunk::binary-size(len), remaining::binary>> ->
        do_decode_chunks(remaining, [safe_utf8(chunk) | acc])

      _ ->
        Enum.reverse(acc)
    end
  end

  defp do_decode_chunks(<<0x4C, len, rest::binary>>, acc) do
    case rest do
      <<chunk::binary-size(len), remaining::binary>> ->
        do_decode_chunks(remaining, [safe_utf8(chunk) | acc])

      _ ->
        Enum.reverse(acc)
    end
  end

  defp do_decode_chunks(<<0x4D, len::little-16, rest::binary>>, acc) do
    case rest do
      <<chunk::binary-size(len), remaining::binary>> ->
        do_decode_chunks(remaining, [safe_utf8(chunk) | acc])

      _ ->
        Enum.reverse(acc)
    end
  end

  defp do_decode_chunks(<<_byte, rest::binary>>, acc), do: do_decode_chunks(rest, acc)

  defp safe_utf8(binary) do
    case :unicode.characters_to_binary(binary) do
      {:error, _, _} -> Base.encode16(binary, case: :lower)
      {:incomplete, _, _} -> Base.encode16(binary, case: :lower)
      text when is_binary(text) -> text
    end
  end
end
