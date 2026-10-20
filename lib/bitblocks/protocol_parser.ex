defmodule Bitblocks.ProtocolParser do
  @moduledoc """
  Composes B://, MAP, and AIP segments from piped OP_RETURN data
  into structured, protocol-specific records.

  A piped OP_RETURN looks like:

      OP_RETURN | B_ADDR | content | mime | ... | "|" | MAP_ADDR | SET | k1 | v1 | ... | "|" | AIP_ADDR | algo | addr | sig

  Deep parsing dispatches by protocol name to the handler registry
  (`Bitblocks.Protocol.Handlers`); this module owns the tx-level plumbing —
  decoding raw hex, walking OP_RETURN outputs, and the BSV-20 locking-script
  special case.
  """

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
  def parse_raw(raw_hex, "BSV20") when is_binary(raw_hex) do
    # BSV-20/21 tokens are inscriptions in output *locking* scripts, not
    # OP_RETURN data — parse per output and return the first token found, with
    # its outpoint (vout) so the caller can stamp a token_id.
    case Bitblocks.Chain.SafeTx.from_hex(raw_hex) do
      {:ok, tx} -> parse_token_outputs(tx.outputs)
      {:error, _} -> {:error, :invalid_raw}
    end
  end

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
          utf8: if(String.printable?(text), do: text, else: nil),
          hex: Base.encode16(text, case: :lower),
          length: byte_size(text)
        }
      end)

    case build_protocol_data(chunks, protocol) do
      {:ok, _} = result -> result
      {:error, _} = err -> err
    end
  end

  @doc """
  Extracts every BSV-20/21 token inscription from a raw transaction's outputs.

  Returns `{:ok, [%{vout: n, token: token_map}, ...]}` (empty list if none), or
  `{:error, :invalid_raw}`. Used by the ingest hook (`Bitblocks.Chain`) to index
  each token output; `token_map` is a `Bitblocks.Bsv20Parser` result.
  """
  @spec token_outputs(binary()) :: {:ok, list(map())} | {:error, atom()}
  def token_outputs(raw_hex) when is_binary(raw_hex) do
    case Bitblocks.Chain.SafeTx.from_hex(raw_hex) do
      {:ok, tx} -> {:ok, collect_token_outputs(tx.outputs)}
      {:error, _} -> {:error, :invalid_raw}
    end
  end

  # -- Private ----------------------------------------------------------------

  defp collect_token_outputs(outputs) do
    outputs
    |> Enum.with_index()
    |> Enum.flat_map(fn {output, vout} ->
      case Bitblocks.Bsv20Parser.parse(output.script) do
        {:ok, token} -> [%{vout: vout, token: token}]
        _ -> []
      end
    end)
  end

  # First token output only (for the single-result parse_raw/2 contract).
  defp parse_token_outputs(outputs) do
    case collect_token_outputs(outputs) do
      [%{vout: vout, token: token} | _] -> {:ok, Map.put(token, :vout, vout)}
      [] -> {:error, :no_token}
    end
  end

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

  # Deep-parse dispatch is registry-driven: each protocol's parser lives in its
  # Bitblocks.Protocol.Handler module (Twetch/Metanet/OrderBook today).
  # BSV20 never reaches here — it's handled by parse_raw/2 on the raw tx,
  # because token inscriptions live in locking scripts, not OP_RETURN chunks.
  defp build_protocol_data(data_chunks, protocol) do
    Bitblocks.Protocol.Handlers.parse(data_chunks, protocol)
  end

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
