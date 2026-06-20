defmodule Bitblocks.TransactionParser do
  @moduledoc """
  Parses Bitcoin SV transactions and extracts meaningful data from scripts,
  particularly OP_RETURN outputs which contain data payloads.

  Raw hex arrives from the (untrusted) node, so every decode goes through
  `Bitblocks.Chain.SafeTx.from_hex/1` — a total, size-bounded wrapper — rather
  than `BSV.Tx.from_binary/2` directly, which raises on some malformed input
  (threat T5).
  """

  alias Bitblocks.Chain.SafeTx

  # Bump when script classification or protocol detection logic changes.
  # Used by analyze/1 and the Release.analyze_transactions/1 backfill.
  @script_analysis_version 4

  def script_analysis_version, do: @script_analysis_version

  @doc """
  Derives deterministic cached metadata from a raw transaction hex string.
  Pure function of `raw` — identical input always produces identical output.

  Returns `{:ok, map}` suitable for storing in the transactions table:
    - script_analysis_version
    - output_types  (%{"p2pkh" => 9, "op_return" => 1})
    - protocols     (["MAP", "AIP"])
    - coinbase      (bool)
  """
  def analyze(raw) when is_binary(raw) do
    case SafeTx.from_hex(raw) do
      {:ok, tx} ->
        op_return_outputs = extract_op_returns(tx.outputs)
        protocols = detect_protocols(op_return_outputs)

        output_types =
          tx.outputs
          |> Enum.map(&determine_script_type(&1.script))
          |> Enum.frequencies()
          |> Map.new(fn {type, count} -> {Atom.to_string(type), count} end)

        {:ok, %{
          script_analysis_version: @script_analysis_version,
          output_types: output_types,
          protocols: protocols,
          coinbase: is_coinbase?(tx)
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def analyze(_), do: {:error, :invalid_raw}

  @doc """
  Parses a transaction and extracts all OP_RETURN data and protocol information.
  """
  def parse_transaction(tx) when is_binary(tx) do
    case SafeTx.from_hex(tx) do
      {:ok, decoded_tx} ->
        parse_transaction(decoded_tx)

      error ->
        error
    end
  end

  def parse_transaction(%BSV.Tx{} = tx) do
    op_return_outputs = extract_op_returns(tx.outputs)
    protocols = detect_protocols(op_return_outputs)

    result = %{
      version: tx.version,
      lock_time: tx.lock_time,
      input_count: length(tx.inputs),
      output_count: length(tx.outputs),
      op_returns: op_return_outputs,
      protocols: protocols,
      is_coinbase: is_coinbase?(tx),
      total_output_satoshis: calculate_total_outputs(tx.outputs)
    }

    if "MAP" in protocols do
      map_chunks =
        op_return_outputs
        |> Enum.flat_map(fn op_return ->
          op_return.data
          |> Enum.filter(&match?(%{type: :push_data, utf8: utf8} when is_binary(utf8), &1))
          |> Enum.map(& &1.utf8)
        end)

      case Bitblocks.MapParser.parse(map_chunks) do
        {:ok, map_data} -> Map.put(result, :map, map_data)
        _ -> result
      end
    else
      result
    end
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
    case output.script.chunks do
      [:OP_RETURN | _] -> true
      [:OP_FALSE, :OP_RETURN | _] -> true
      _ -> false
    end
  end

  @doc """
  Parses OP_RETURN data into a structured format.
  """
  def parse_op_return_data(%BSV.Script{} = script) do
    data_chunks =
      case script.chunks do
        [:OP_RETURN | rest] -> rest
        [:OP_FALSE, :OP_RETURN | rest] -> rest
        _ -> []
      end

    Enum.map(data_chunks, fn chunk ->
      if is_binary(chunk) do
        %{
          type: :push_data,
          hex: Base.encode16(chunk, case: :lower),
          utf8: safe_utf8_decode(chunk),
          length: byte_size(chunk)
        }
      else
        %{
          type: :opcode,
          opcode: BSV.OpCode.to_integer(chunk),
          name: Atom.to_string(chunk)
        }
      end
    end)
  end

  @doc """
  Extracts raw hex data from OP_RETURN script.
  """
  def extract_hex_data(%BSV.Script{} = script) do
    data_chunks =
      case script.chunks do
        [:OP_RETURN | rest] -> rest
        [:OP_FALSE, :OP_RETURN | rest] -> rest
        _ -> []
      end

    data_chunks
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Base.encode16(&1, case: :lower))
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
    # Extract utf8 strings from parsed chunks
    utf8_chunks =
      data_chunks
      |> Enum.filter(&match?(%{type: :push_data, utf8: utf8} when is_binary(utf8), &1))
      |> Enum.map(& &1.utf8)

    # Split on pipe separators and check each segment's first chunk.
    # This detects all protocols in piped OP_RETURN data (B:// | MAP | AIP).
    piped_protocols =
      utf8_chunks
      |> Enum.chunk_by(&(&1 == "|"))
      |> Enum.reject(&(&1 == ["|"]))
      |> Enum.flat_map(fn segment ->
        case List.first(segment) do
          nil -> []
          addr -> check_protocol_prefix(addr)
        end
      end)

    # Detect protocols from MAP app field (e.g. app=twetch → "Twetch")
    map_app_protocols = detect_from_map_app(utf8_chunks)

    # Check for hex-based protocols
    hex_protocols = check_hex_protocols(data_chunks)

    # Check for vCard data
    vcard_protocols = check_vcard_protocol(data_chunks)

    (piped_protocols ++ map_app_protocols ++ hex_protocols ++ vcard_protocols)
    |> Enum.uniq()
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

  # Known Bitcom protocol addresses — prefix of first OP_RETURN push chunk.
  @protocol_prefixes [
    {"19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut", "B://"},
    {"1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5", "MAP"},
    {"15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva", "AIP"},
    {"1HA1P2exomAwCUycZHr8WeyFoy5vuQASE3", "HAIP"},
    {"19nknDdM3ueaAt7nFLFQ3aS3PVHVnJoMmU", "Twetch"},
    {"1LtyME6b5AnMopQrBPLk4FGN8UBuhxKqrn", "RelayX"},
    {"15DHFxWZJT58f9nhyCA3mREYYzkVDetm6A", "BCat"}
  ]

  # MAP app field values that map to a protocol name.
  # Used to detect protocols like Twetch that are identified by app metadata
  # rather than by their own Bitcom address in the OP_RETURN.
  @map_app_protocols %{
    "twetch" => "Twetch"
  }

  defp check_protocol_prefix(utf8) do
    address_match =
      Enum.find_value(@protocol_prefixes, fn {prefix, name} ->
        if String.starts_with?(utf8, prefix), do: [name]
      end)

    cond do
      address_match -> address_match
      utf8 == "meta" -> ["Metanet"]
      utf8 == "orderbook" -> ["OrderBook"]
      String.starts_with?(utf8, "ord") -> ["1SAT Ordinals"]
      String.contains?(utf8, "bitcom") -> ["Bitcom"]
      true -> []
    end
  end

  # Detect protocols from the MAP app field in piped OP_RETURN data.
  # E.g. when MAP SET contains app=twetch, we add "Twetch" to detected protocols.
  @map_address "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"

  defp detect_from_map_app(utf8_chunks) do
    segments =
      utf8_chunks
      |> Enum.chunk_by(&(&1 == "|"))
      |> Enum.reject(&(&1 == ["|"]))

    Enum.flat_map(segments, fn
      [@map_address, "SET" | pairs] ->
        pairs
        |> Enum.chunk_every(2)
        |> Enum.find_value([], fn
          ["app", app_name] -> List.wrap(Map.get(@map_app_protocols, app_name))
          _ -> nil
        end)

      _ ->
        []
    end)
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
    hex_data =
      Enum.map_join(data_chunks, fn
        %{hex: hex} -> hex
        _ -> ""
      end)

    []
    |> maybe_add("1SAT Ordinals", String.contains?(hex_data, "6f7264"))
    # Run: OP_0 OP_RETURN envelope starts with hex "72756e" ("run")
    |> maybe_add("Run", String.starts_with?(hex_data, "72756e"))
  end

  defp maybe_add(list, _name, false), do: list
  defp maybe_add(list, name, true), do: list ++ [name]

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
  Extracts parent txids from a list of JSON-encoded input strings.

  Used to populate the `input_txids` column for indexed spend lookups.
  Filters out coinbase inputs (all-zero txid).

  ## Examples

      iex> extract_input_txids([~s({"txid":"abc123","vout":0})])
      ["abc123"]

  """
  def extract_input_txids(inputs) when is_list(inputs) do
    inputs
    |> Enum.flat_map(fn input_str ->
      case Jason.decode(input_str) do
        {:ok, %{"txid" => txid}} when is_binary(txid) ->
          if String.match?(txid, ~r/^0+$/) or txid == "", do: [], else: [txid]

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  def extract_input_txids(_), do: []

  @doc """
  Extracts P2PKH/P2SH addresses from a list of JSON-encoded output strings.

  Used to populate the `output_addresses` column for indexed address lookups.
  Reads `scriptPubKey.addresses[0]` from each output's RPC JSON.

  ## Examples

      iex> extract_output_addresses([~s({"scriptPubKey":{"addresses":["1A1zP1..."]},"value":0.01})])
      ["1A1zP1..."]

  """
  def extract_output_addresses(outputs) when is_list(outputs) do
    outputs
    |> Enum.flat_map(fn output_str ->
      case Jason.decode(output_str) do
        {:ok, %{"scriptPubKey" => %{"addresses" => [address | _]}}} when is_binary(address) ->
          [address]

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  def extract_output_addresses(_), do: []

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
  Extracts the human-readable coinbase message from a decoded transaction.

  The coinbase scriptSig is arbitrary miner-chosen bytes (block height per BIP34,
  miner/pool tags, free-form text) — it is NOT a standard script and is not an
  OP_RETURN output, so the usual output decoders never see it. The genesis block's
  "The Times 03/Jan/2009 Chancellor on brink of second bailout for banks" lives
  here, in the coinbase input.

  Returns `{:ok, %{text: ..., hex: ...}}` for a coinbase tx whose scriptSig holds
  printable text, `:none` for a coinbase with no printable text, and `:not_coinbase`
  for an ordinary tx. The raw bytes are framed with length prefixes and binary
  height pushes, so we pull the printable ASCII/UTF-8 runs rather than decoding the
  whole blob as one string.
  """
  def coinbase_message(%BSV.Tx{inputs: [%{script: %{coinbase: bytes}} | _]})
      when is_binary(bytes) do
    case printable_runs(bytes) do
      "" -> :none
      text -> {:ok, %{text: text, hex: Base.encode16(bytes, case: :lower)}}
    end
  end

  def coinbase_message(%BSV.Tx{}), do: :not_coinbase

  # Pull printable text out of the raw coinbase bytes: split on non-printable
  # bytes and keep the substantial runs (>= 4 chars, dropping height/extranonce
  # framing noise). A push-length byte that happens to be printable can prefix a
  # run (e.g. the 0x45 = "E" before the genesis message) — that's the raw bytes,
  # left as-is.
  defp printable_runs(bytes) when is_binary(bytes) do
    bytes
    |> String.split(~r/[^[:print:]]+/, trim: true)
    |> Enum.filter(fn run -> String.valid?(run) and String.length(run) >= 4 end)
    |> Enum.join(" ")
    |> String.trim()
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

  def determine_script_type(script) do
    case script.chunks do
      [:OP_RETURN | _] -> :op_return
      [:OP_FALSE, :OP_RETURN | _] -> :op_return
      [:OP_DUP, :OP_HASH160, pkh, :OP_EQUALVERIFY, :OP_CHECKSIG] when is_binary(pkh) -> :p2pkh
      [:OP_HASH160, sh, :OP_EQUAL] when is_binary(sh) -> :p2sh
      [pk, :OP_CHECKSIG] when is_binary(pk) and byte_size(pk) in [33, 65] -> :p2pk
      chunks -> if is_multisig?(chunks), do: :multisig, else: :unknown
    end
  end

  @doc """
  Extracts semantic fields from a script based on its type.

  Returns a map with type-specific fields:
    - `:p2pkh`    — `%{type: :p2pkh, pubkey_hash: hex}`
    - `:p2sh`     — `%{type: :p2sh, script_hash: hex}`
    - `:p2pk`     — `%{type: :p2pk, pubkey: hex}`
    - `:multisig` — `%{type: :multisig, m: integer, n: integer, pubkeys: [hex]}`
    - `:op_return`— `%{type: :op_return, data: [chunk_map]}`
    - `:unknown`  — `%{type: :unknown, asm: string}`
  """
  def extract_script_fields(script) do
    case determine_script_type(script) do
      :p2pkh ->
        [:OP_DUP, :OP_HASH160, pkh | _] = script.chunks
        %{type: :p2pkh, pubkey_hash: Base.encode16(pkh, case: :lower)}

      :p2sh ->
        [:OP_HASH160, sh | _] = script.chunks
        %{type: :p2sh, script_hash: Base.encode16(sh, case: :lower)}

      :p2pk ->
        [pk | _] = script.chunks
        %{type: :p2pk, pubkey: Base.encode16(pk, case: :lower)}

      :multisig ->
        [m_op | rest] = script.chunks
        pubkeys = rest |> Enum.filter(&is_binary/1)
        n = length(pubkeys)
        m = op_to_small_int(m_op)
        %{type: :multisig, m: m, n: n, pubkeys: Enum.map(pubkeys, &Base.encode16(&1, case: :lower))}

      :op_return ->
        %{type: :op_return, data: parse_op_return_data(script)}

      :unknown ->
        %{type: :unknown, asm: BSV.Script.to_asm(script)}
    end
  end

  defp is_multisig?(chunks) do
    case chunks do
      [m | rest] when is_atom(m) ->
        case op_to_small_int(m) do
          nil -> false
          m_val when m_val in 1..16 ->
            case List.last(chunks) do
              :OP_CHECKMULTISIG ->
                pubkeys = rest |> Enum.drop(-2) |> Enum.filter(&is_binary/1)
                n_op = Enum.at(rest, length(rest) - 2)
                n_val = op_to_small_int(n_op)
                n_val != nil and length(pubkeys) == n_val and m_val <= n_val
              _ -> false
            end
        end
      _ -> false
    end
  end

  # Maps OP_TRUE/OP_1..OP_16 atoms to their integer values.
  defp op_to_small_int(:OP_TRUE), do: 1
  defp op_to_small_int(:OP_1), do: 1
  defp op_to_small_int(:OP_2), do: 2
  defp op_to_small_int(:OP_3), do: 3
  defp op_to_small_int(:OP_4), do: 4
  defp op_to_small_int(:OP_5), do: 5
  defp op_to_small_int(:OP_6), do: 6
  defp op_to_small_int(:OP_7), do: 7
  defp op_to_small_int(:OP_8), do: 8
  defp op_to_small_int(:OP_9), do: 9
  defp op_to_small_int(:OP_10), do: 10
  defp op_to_small_int(:OP_11), do: 11
  defp op_to_small_int(:OP_12), do: 12
  defp op_to_small_int(:OP_13), do: 13
  defp op_to_small_int(:OP_14), do: 14
  defp op_to_small_int(:OP_15), do: 15
  defp op_to_small_int(:OP_16), do: 16
  defp op_to_small_int(_), do: nil

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
