defmodule Bitblocks.Script.OpReturn do
  @moduledoc """
  The OP_RETURN chunk toolkit: detection, structured chunk parsing, and the
  utf8/pipe-segment helpers that protocol detection and deep parsing share.

  Consolidates logic that was duplicated across `TransactionParser` and
  `ProtocolParser` — every protocol handler works from these primitives.
  """

  alias BSV.Script

  @pipe "|"

  @doc """
  True when an output's script is an OP_RETURN (bare or OP_FALSE-prefixed).
  """
  def op_return?(%BSV.TxOut{} = output), do: op_return_script?(output.script)

  @doc """
  True when a script is an OP_RETURN script (bare or OP_FALSE-prefixed).
  """
  def op_return_script?(%Script{chunks: [:OP_RETURN | _]}), do: true
  def op_return_script?(%Script{chunks: [:OP_FALSE, :OP_RETURN | _]}), do: true
  def op_return_script?(_), do: false

  @doc """
  The raw chunks following the OP_RETURN marker (binaries and opcode atoms).
  """
  def raw_chunks(%Script{chunks: [:OP_RETURN | rest]}), do: rest
  def raw_chunks(%Script{chunks: [:OP_FALSE, :OP_RETURN | rest]}), do: rest
  def raw_chunks(_), do: []

  @doc """
  Parses OP_RETURN data into structured chunk maps:

      %{type: :push_data, hex: ..., utf8: ..., length: ...}
      %{type: :opcode, opcode: ..., name: ...}
  """
  def parse_data(%Script{} = script) do
    script
    |> raw_chunks()
    |> Enum.map(fn chunk ->
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
  Extracts the lowercase-hex push-data chunks from an OP_RETURN script.
  """
  def hex_data(%Script{} = script) do
    script
    |> raw_chunks()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Base.encode16(&1, case: :lower))
  end

  @doc """
  The decoded utf8 strings from a list of parsed chunk maps (push-data chunks
  whose bytes were valid printable UTF-8).
  """
  def utf8_chunks(parsed_chunks) when is_list(parsed_chunks) do
    parsed_chunks
    |> Enum.filter(&match?(%{type: :push_data, utf8: utf8} when is_binary(utf8), &1))
    |> Enum.map(& &1.utf8)
  end

  @doc """
  Splits a flat utf8 chunk list on `"|"` separators into protocol segments —
  the piped OP_RETURN convention (`B:// | MAP | AIP`).
  """
  def pipe_segments(utf8_chunks) when is_list(utf8_chunks) do
    utf8_chunks
    |> Enum.chunk_by(&(&1 == @pipe))
    |> Enum.reject(&(&1 == [@pipe]))
  end

  @doc """
  Safely decodes a binary as printable UTF-8, returning nil if invalid.
  """
  def safe_utf8_decode(binary) when is_binary(binary) do
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
end
