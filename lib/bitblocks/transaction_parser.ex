defmodule Bitblocks.TransactionParser do
  @moduledoc """
  Parses Bitcoin SV transactions and extracts meaningful data from scripts,
  particularly OP_RETURN outputs which contain data payloads.
  """

  @doc """
  Parses a transaction and extracts all OP_RETURN data and protocol information.
  """
  def parse_transaction(tx) when is_binary(tx) do
    case BSV.Tx.from_binary(tx, encoding: :hex) do
      {:ok, decoded_tx} ->
        parse_transaction(decoded_tx)

      error ->
        error
    end
  end

  def parse_transaction(%BSV.Tx{} = tx) do
    op_return_outputs = extract_op_returns(tx.outputs)

    %{
      version: tx.version,
      lock_time: tx.lock_time,
      input_count: length(tx.inputs),
      output_count: length(tx.outputs),
      op_returns: op_return_outputs,
      protocols: detect_protocols(op_return_outputs),
      is_coinbase: is_coinbase?(tx),
      total_output_satoshis: calculate_total_outputs(tx.outputs)
    }
  end

  @doc """
  Extracts all OP_RETURN outputs from a list of transaction outputs.
  """
  def extract_op_returns(outputs) do
    outputs
    |> Enum.with_index()
    |> Enum.filter(fn {output, _idx} -> is_op_return?(output) end)
    |> Enum.map(fn {output, idx} ->
      %{
        output_index: idx,
        satoshis: output.satoshis,
        data: parse_op_return_data(output.script),
        raw_script: BSV.Script.to_asm(output.script),
        hex_data: extract_hex_data(output.script)
      }
    end)
  end

  @doc """
  Checks if an output is an OP_RETURN output.
  """
  def is_op_return?(%BSV.TxOut{} = output) do
    # OP_RETURN is opcode 106 (0x6a)
    case output.script.chunks do
      [%{op: 106} | _rest] -> true
      _ -> false
    end
  end

  @doc """
  Parses OP_RETURN data into a structured format.
  """
  def parse_op_return_data(%BSV.Script{} = script) do
    case script.chunks do
      [%{op: 106} | data_chunks] ->
        data_chunks
        |> Enum.map(fn chunk ->
          case chunk do
            %{buf: buffer} when is_binary(buffer) ->
              %{
                type: :push_data,
                hex: Base.encode16(buffer, case: :lower),
                utf8: safe_utf8_decode(buffer),
                length: byte_size(buffer)
              }

            %{op: op} ->
              %{
                type: :opcode,
                opcode: op,
                name: opcode_name(op)
              }
          end
        end)

      _ ->
        []
    end
  end

  @doc """
  Extracts raw hex data from OP_RETURN script.
  """
  def extract_hex_data(%BSV.Script{} = script) do
    case script.chunks do
      [%{op: 106} | data_chunks] ->
        data_chunks
        |> Enum.filter(fn chunk -> Map.has_key?(chunk, :buf) end)
        |> Enum.map(fn %{buf: buffer} -> Base.encode16(buffer, case: :lower) end)

      _ ->
        []
    end
  end

  @doc """
  Detects known protocols in OP_RETURN data.

  First attempts to look up protocols in the Protocol Registry database.
  Falls back to hardcoded protocol detection for well-known protocols.

  Known protocols:
  - B:// (B protocol - files on chain)
  - 1SAT Ordinals
  - MAP (Magic Attribute Protocol)
  - AIP (Author Identity Protocol)
  - HAIP (Hash Author Identity Protocol)
  - Bitcom protocols
  - etc.
  """
  def detect_protocols(op_return_outputs) do
    op_return_outputs
    |> Enum.flat_map(fn op_return ->
      detect_protocol(op_return.data)
    end)
    |> Enum.uniq()
  end

  @doc """
  Detects protocols with full registry information.

  Returns a list of maps with protocol details for each detected protocol.
  Useful for displaying detailed protocol information in the UI.

  ## Examples

      iex> detect_protocols_with_info(op_return_outputs)
      [%{name: "B://", address: "19Hx...", category: :data_storage, ...}, ...]

  """
  def detect_protocols_with_info(op_return_outputs) do
    op_return_outputs
    |> Enum.flat_map(fn op_return ->
      detect_protocol_with_info(op_return.data, op_return[:output_index])
    end)
    |> Enum.uniq_by(fn p -> p.name end)
  end

  defp detect_protocol(data_chunks) when is_list(data_chunks) do
    # Check first chunk for protocol identifiers
    prefix_protocols =
      case List.first(data_chunks) do
        %{utf8: utf8} when is_binary(utf8) ->
          check_protocol_prefix(utf8)

        _ ->
          []
      end

    # Check for hex-based protocols
    hex_protocols = check_hex_protocols(data_chunks)

    # Check for vCard data
    vcard_protocols = check_vcard_protocol(data_chunks)

    prefix_protocols ++ hex_protocols ++ vcard_protocols
  end

  defp detect_protocol_with_info(data_chunks, output_index) when is_list(data_chunks) do
    first_chunk = List.first(data_chunks)
    address = extract_address_from_chunk(first_chunk)

    # Try registry lookup first
    registry_result =
      if address do
        case Bitblocks.ProtocolRegistry.identify_protocol(address) do
          {:ok, protocol} ->
            [
              %{
                name: protocol.name,
                address: protocol.address,
                category: protocol.category,
                verification_status: protocol.verification_status,
                has_covenant: protocol.has_covenant,
                output_index: output_index,
                source: :registry
              }
            ]

          {:error, _} ->
            []
        end
      else
        []
      end

    # Fall back to hardcoded detection if registry didn't match
    if Enum.empty?(registry_result) do
      fallback_names = detect_protocol(data_chunks)

      Enum.map(fallback_names, fn name ->
        %{
          name: name,
          address: nil,
          category: :other,
          verification_status: :unverified,
          has_covenant: false,
          output_index: output_index,
          source: :fallback
        }
      end)
    else
      registry_result
    end
  end

  defp extract_address_from_chunk(%{utf8: utf8}) when is_binary(utf8) do
    # Check if it looks like a Bitcoin address
    if Regex.match?(~r/^[13][a-km-zA-HJ-NP-Z1-9]{25,34}$/, utf8) do
      utf8
    else
      nil
    end
  end

  defp extract_address_from_chunk(_), do: nil

  defp check_protocol_prefix(utf8) do
    cond do
      String.starts_with?(utf8, "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut") ->
        ["B://"]

      String.starts_with?(utf8, "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5") ->
        ["MAP"]

      String.starts_with?(utf8, "15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva") ->
        ["AIP"]

      String.starts_with?(utf8, "1HA1P2exomAwCUycZHr8WeyFoy5vuQASE3") ->
        ["HAIP"]

      String.starts_with?(utf8, "ord") ->
        ["1SAT Ordinals"]

      String.contains?(utf8, "bitcom") ->
        ["Bitcom"]

      true ->
        []
    end
  end

  defp check_vcard_protocol(data_chunks) do
    text =
      data_chunks
      |> Enum.filter(fn
        %{type: :push_data, utf8: utf8} when is_binary(utf8) -> true
        _ -> false
      end)
      |> Enum.map(fn %{utf8: utf8} -> utf8 end)
      |> Enum.join("")

    if Bitblocks.VcardParser.is_vcard?(text), do: ["vCard"], else: []
  end

  defp check_hex_protocols(data_chunks) do
    protocols = []

    # Look for OP_RETURN patterns
    hex_data =
      Enum.map(data_chunks, fn
        %{hex: hex} -> hex
        _ -> ""
      end)
      |> Enum.join("")

    cond do
      # "ord" in hex
      String.contains?(hex_data, "6f7264") ->
        protocols ++ ["1SAT Ordinals"]

      true ->
        protocols
    end
  end

  @doc """
  Decodes a chunk of data based on detected format.
  """
  def decode_chunk(%{hex: hex, utf8: utf8}) do
    %{
      hex: hex,
      utf8: utf8,
      decimal: hex_to_decimal(hex),
      possible_formats: detect_formats(hex, utf8)
    }
  end

  defp detect_formats(hex, utf8) when is_binary(utf8) do
    formats = []

    # Check if it's a valid URL
    formats = if String.match?(utf8, ~r/^https?:\/\//), do: ["URL" | formats], else: formats

    # Check if it's a valid Bitcoin address
    formats =
      if String.match?(utf8, ~r/^[13][a-km-zA-HJ-NP-Z1-9]{25,34}$/),
        do: ["Bitcoin Address" | formats],
        else: formats

    # Check if it's JSON
    formats =
      case Jason.decode(utf8) do
        {:ok, _} -> ["JSON" | formats]
        _ -> formats
      end

    # Check if it's a hash (32 or 64 hex chars)
    formats = if String.length(hex) in [64, 128], do: ["Hash" | formats], else: formats

    formats
  end

  defp detect_formats(_hex, _utf8), do: []

  @doc """
  Checks if a transaction is a coinbase transaction.
  """
  def is_coinbase?(%BSV.Tx{} = tx) do
    case tx.inputs do
      [first_input | _] ->
        first_input.script.coinbase != nil

      _ ->
        false
    end
  end

  @doc """
  Calculates total satoshis in outputs.
  """
  def calculate_total_outputs(outputs) do
    Enum.reduce(outputs, 0, fn output, acc ->
      acc + output.satoshis
    end)
  end

  # Safely decodes UTF-8, returning nil if invalid.
  defp safe_utf8_decode(binary) when is_binary(binary) do
    case :unicode.characters_to_binary(binary, :utf8) do
      result when is_binary(result) ->
        if String.valid?(result) and String.printable?(result) do
          result
        else
          nil
        end

      _ ->
        nil
    end
  end

  # Converts hex string to decimal.
  defp hex_to_decimal(hex) when is_binary(hex) do
    case Integer.parse(hex, 16) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  # Returns the name of an opcode.
  defp opcode_name(op) do
    case op do
      0 -> "OP_0"
      76 -> "OP_PUSHDATA1"
      77 -> "OP_PUSHDATA2"
      78 -> "OP_PUSHDATA4"
      79 -> "OP_1NEGATE"
      81 -> "OP_1"
      82 -> "OP_2"
      83 -> "OP_3"
      106 -> "OP_RETURN"
      118 -> "OP_DUP"
      169 -> "OP_HASH160"
      170 -> "OP_HASH256"
      135 -> "OP_EQUAL"
      136 -> "OP_EQUALVERIFY"
      172 -> "OP_CHECKSIG"
      173 -> "OP_CHECKSIGVERIFY"
      _ -> "OP_#{op}"
    end
  end

  @doc """
  Analyzes all outputs and categorizes them.
  """
  def categorize_outputs(outputs) do
    outputs
    |> Enum.with_index()
    |> Enum.map(fn {output, idx} ->
      %{
        index: idx,
        satoshis: output.satoshis,
        type: determine_output_type(output),
        script_type: determine_script_type(output.script),
        data: if(is_op_return?(output), do: parse_op_return_data(output.script), else: nil)
      }
    end)
  end

  defp determine_output_type(output) do
    cond do
      is_op_return?(output) -> :op_return
      output.satoshis == 0 -> :data_carrier
      true -> :payment
    end
  end

  defp determine_script_type(script) do
    case script.chunks do
      [%{op: 106} | _] ->
        :op_return

      [%{op: 118}, %{op: 169}, %{buf: _}, %{op: 136}, %{op: 172}] ->
        # Pay to Public Key Hash
        :p2pkh

      [%{op: 169}, %{buf: _}, %{op: 135}] ->
        # Pay to Script Hash
        :p2sh

      [%{buf: pubkey}, %{op: 172}] when byte_size(pubkey) in [33, 65] ->
        # Pay to Public Key
        :p2pk

      _ ->
        :unknown
    end
  end

  @doc """
  Extracts all text content from OP_RETURN data.
  """
  def extract_text_content(op_return_data) when is_list(op_return_data) do
    op_return_data
    |> Enum.filter(fn chunk -> chunk.type == :push_data and chunk.utf8 != nil end)
    |> Enum.map(fn chunk -> chunk.utf8 end)
    |> Enum.join(" ")
  end

  @doc """
  Checks if transaction contains file data (B:// protocol or similar).
  """
  def contains_file_data?(protocols) when is_list(protocols) do
    "B://" in protocols or "1SAT Ordinals" in protocols
  end
end
