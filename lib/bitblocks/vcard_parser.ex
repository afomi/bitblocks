defmodule Bitblocks.VcardParser do
  @moduledoc """
  Parses vCard-format data from on-chain OP_RETURN payloads.

  Supports vCard 3.0 and 4.0 formats.
  A vCard stored on-chain typically appears as UTF-8 text in an OP_RETURN output,
  either as a single push data or split across multiple push data chunks.

  ## vCard format

      BEGIN:VCARD
      VERSION:4.0
      FN:Ryan Wold
      ORG:Bitblocks
      EMAIL:ryan@example.com
      END:VCARD
  """

  @type vcard :: %{
          version: String.t(),
          fields: list(map()),
          raw: String.t()
        }

  @doc """
  Checks if text content looks like a vCard.
  """
  def is_vcard?(text) when is_binary(text) do
    normalized = String.trim(text)
    String.starts_with?(normalized, "BEGIN:VCARD") and String.contains?(normalized, "END:VCARD")
  end

  def is_vcard?(_), do: false

  @doc """
  Parses vCard text into a structured map.

  ## Examples

      iex> text = "BEGIN:VCARD\\nVERSION:4.0\\nFN:Ryan Wold\\nEND:VCARD"
      iex> {:ok, vcard} = Bitblocks.VcardParser.parse(text)
      iex> vcard.version
      "4.0"
  """
  def parse(text) when is_binary(text) do
    if is_vcard?(text) do
      lines =
        text
        |> String.replace("\r\n", "\n")
        |> String.replace("\r", "\n")
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      version = extract_field_value(lines, "VERSION") || "3.0"
      fields = parse_fields(lines)

      {:ok,
       %{
         version: version,
         fields: fields,
         raw: text
       }}
    else
      {:error, "Not a valid vCard"}
    end
  end

  def parse(_), do: {:error, "Input must be a string"}

  @doc """
  Extracts a specific field value from a parsed vCard.

  ## Examples

      iex> {:ok, vcard} = Bitblocks.VcardParser.parse("BEGIN:VCARD\\nVERSION:4.0\\nFN:Ryan\\nEND:VCARD")
      iex> Bitblocks.VcardParser.get_field(vcard, "FN")
      "Ryan"
  """
  def get_field(%{fields: fields}, name) do
    case Enum.find(fields, fn f -> f.name == name end) do
      %{value: value} -> value
      nil -> nil
    end
  end

  @doc """
  Gets all values for a field that may appear multiple times (e.g., TEL, EMAIL).
  """
  def get_fields(%{fields: fields}, name) do
    fields
    |> Enum.filter(fn f -> f.name == name end)
    |> Enum.map(& &1.value)
  end

  @doc """
  Extracts a vCard from OP_RETURN data chunks (as returned by TransactionParser).

  Data chunks are the `%{type: :push_data, utf8: ..., hex: ...}` maps.
  """
  def from_op_return_chunks(chunks) when is_list(chunks) do
    text =
      chunks
      |> Enum.filter(fn
        %{type: :push_data, utf8: utf8} when is_binary(utf8) -> true
        _ -> false
      end)
      |> Enum.map(fn %{utf8: utf8} -> utf8 end)
      |> Enum.join("")

    if is_vcard?(text) do
      parse(text)
    else
      {:error, "No vCard found in OP_RETURN data"}
    end
  end

  def from_op_return_chunks(_), do: {:error, "Invalid chunks"}

  # Private helpers

  defp parse_fields(lines) do
    lines
    |> Enum.reject(fn line ->
      line in ["BEGIN:VCARD", "END:VCARD"] or String.starts_with?(line, "VERSION:")
    end)
    |> Enum.map(&parse_field_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_field_line(line) do
    case String.split(line, ":", parts: 2) do
      [name_with_params, value] ->
        {name, params} = parse_field_name(name_with_params)

        %{
          name: name,
          params: params,
          value: value
        }

      _ ->
        nil
    end
  end

  defp parse_field_name(name_with_params) do
    case String.split(name_with_params, ";", parts: 2) do
      [name, params_str] ->
        params =
          params_str
          |> String.split(";")
          |> Enum.map(fn param ->
            case String.split(param, "=", parts: 2) do
              [key, val] -> {key, val}
              [key] -> {key, ""}
            end
          end)
          |> Map.new()

        {String.upcase(name), params}

      [name] ->
        {String.upcase(name), %{}}
    end
  end

  defp extract_field_value(lines, field_name) do
    prefix = field_name <> ":"

    case Enum.find(lines, fn line -> String.starts_with?(line, prefix) end) do
      nil -> nil
      line -> String.trim_leading(line, prefix)
    end
  end
end
