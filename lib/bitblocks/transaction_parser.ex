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
  alias Bitblocks.Script.OpReturn

  # Bump when script classification or protocol detection logic changes.
  # Used by analyze/1 and the Release.analyze_transactions/1 backfill.
  # v5: adds output_script_hashes + output_template_hashes (script-first indexing).
  # v6: adds aip_signers (verified AIP signing addresses); "Bitcom" is detected
  # by a `$` command segment instead of the substring "bitcom".
  @script_analysis_version 6

  def script_analysis_version, do: @script_analysis_version

  @doc """
  Derives deterministic cached metadata from a raw transaction hex string.
  Pure function of `raw` — identical input always produces identical output.

  Returns `{:ok, map}` suitable for storing in the transactions table:
    - script_analysis_version
    - output_types           (%{"p2pkh" => 9, "op_return" => 1})
    - protocols              (["MAP", "AIP"])
    - coinbase               (bool)
    - output_script_hashes   (deduped Electrum scripthashes, one per distinct output script)
    - output_template_hashes (deduped opcode-skeleton hashes; see Bitblocks.Script)
    - aip_signers            (addresses of valid AIP signatures; see Bitblocks.Aip)
  """
  def analyze(raw) when is_binary(raw) do
    case SafeTx.from_hex(raw) do
      {:ok, tx} ->
        op_return_outputs = extract_op_returns(tx.outputs)
        # BSV-20/21 tokens are ordinal inscriptions in output *locking* scripts,
        # not OP_RETURN push-data, so they need a separate scan over all outputs.
        protocols = detect_protocols(op_return_outputs) ++ detect_token_protocol(tx.outputs)

        scripts = Enum.map(tx.outputs, & &1.script)

        output_types =
          scripts
          |> Enum.map(&Bitblocks.Script.classify/1)
          |> Enum.frequencies()
          |> Map.new(fn {type, count} -> {Atom.to_string(type), count} end)

        {:ok,
         %{
           script_analysis_version: @script_analysis_version,
           output_types: output_types,
           protocols: protocols,
           coinbase: is_coinbase?(tx),
           output_script_hashes:
             scripts |> Enum.map(&Bitblocks.Script.script_hash/1) |> Enum.uniq(),
           output_template_hashes:
             scripts |> Enum.map(&Bitblocks.Script.template_hash/1) |> Enum.uniq(),
           aip_signers: aip_signers(protocols, op_return_outputs, tx.outputs)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def analyze(_), do: {:error, :invalid_raw}

  # Signature checks are the costly part, so only AIP-tagged txs pay for them.
  defp aip_signers(protocols, op_return_outputs, outputs) do
    if "AIP" in protocols do
      Enum.flat_map(op_return_outputs, fn %{output_index: i} ->
        Bitblocks.Aip.verified_signers(Enum.at(outputs, i).script.chunks)
      end)
      |> Enum.uniq()
    else
      []
    end
  end

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
        Enum.flat_map(op_return_outputs, fn op_return ->
          OpReturn.utf8_chunks(op_return.data)
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
  defdelegate is_op_return?(output), to: OpReturn, as: :op_return?

  @doc """
  Parses OP_RETURN data into a structured format.
  """
  defdelegate parse_op_return_data(script), to: OpReturn, as: :parse_data

  @doc """
  Extracts raw hex data from OP_RETURN script.
  """
  defdelegate extract_hex_data(script), to: OpReturn, as: :hex_data

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

  # Flags "BSV20" when any output's locking script carries a BSV-20/21 token
  # inscription (`application/bsv-20`). Returns [] or ["BSV20"].
  defp detect_token_protocol(outputs) when is_list(outputs) do
    if Enum.any?(outputs, &Bitblocks.Bsv20Parser.token_inscription?(&1.script)) do
      ["BSV20"]
    else
      []
    end
  end

  defp detect_token_protocol(_), do: []

  # Detection is registry-driven: every protocol is a Bitblocks.Protocol.Handler
  # module registered (in detection order) in Bitblocks.Protocol.Handlers.
  # Adding a protocol no longer touches this module.
  defp detect_protocol(data_chunks) when is_list(data_chunks) do
    Bitblocks.Protocol.Handlers.detect_all(data_chunks)
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

  defdelegate determine_script_type(script), to: Bitblocks.Script, as: :classify

  @doc """
  Extracts semantic fields from a script based on its type.
  See `Bitblocks.Script.extract_fields/1`.
  """
  defdelegate extract_script_fields(script), to: Bitblocks.Script, as: :extract_fields

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
