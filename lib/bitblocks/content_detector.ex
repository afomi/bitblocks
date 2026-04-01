defmodule Bitblocks.ContentDetector do
  @moduledoc """
  Detects file content (images, text, etc.) stored in Bitcoin SV transactions.

  Supports:
  - B:// protocol (19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut)
  - 1Sat Ordinals (ord inscriptions)
  - Raw OP_RETURN content with MIME type detection
  """

  @b_protocol_address "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"

  @image_mime_types ~w(image/png image/jpeg image/gif image/webp image/svg+xml image/bmp)
  @text_mime_types ~w(text/plain text/html text/markdown text/csv application/json)

  @type content_record :: %{
          txid: String.t(),
          block_height: integer(),
          content_type: String.t(),
          media_category: :image | :text | :other,
          protocol: String.t(),
          encoding: String.t() | nil,
          filename: String.t() | nil,
          size: integer()
        }

  @doc """
  Scans a list of transactions and returns detected file content records.

  Each transaction should be a map with at least `:txid`, `:block_height`, and `:outputs` fields.
  Outputs are string arrays (as stored in the Transaction schema).
  """
  def scan_transactions(transactions) do
    transactions
    |> Enum.flat_map(&detect_content/1)
  end

  @doc """
  Detects content in a single transaction's outputs.
  """
  def detect_content(%{txid: txid, block_height: height, outputs: outputs}) when is_list(outputs) do
    outputs
    |> Enum.with_index()
    |> Enum.flat_map(fn {output_str, idx} ->
      case detect_from_output(output_str) do
        nil -> []
        content -> [Map.merge(content, %{txid: txid, block_height: height, output_index: idx})]
      end
    end)
  end

  def detect_content(_), do: []

  @doc """
  Detects if an OP_RETURN output string contains B:// protocol data.
  """
  def detect_b_protocol(data_chunks) when is_list(data_chunks) do
    case data_chunks do
      [%{utf8: @b_protocol_address} | rest] ->
        parse_b_protocol_fields(rest)

      _ ->
        nil
    end
  end

  def detect_b_protocol(_), do: nil

  @doc """
  Detects if data chunks contain an ordinal inscription.
  """
  def detect_ordinal(data_chunks) when is_list(data_chunks) do
    text =
      data_chunks
      |> Enum.filter(fn
        %{utf8: utf8} when is_binary(utf8) -> true
        _ -> false
      end)
      |> Enum.map(& &1.utf8)
      |> Enum.join("")

    cond do
      String.contains?(text, "ord") ->
        # Simple ordinal detection — look for content type in subsequent chunks
        content_type = extract_ordinal_content_type(data_chunks)
        %{
          protocol: "1Sat Ordinals",
          content_type: content_type || "application/octet-stream",
          media_category: categorize_mime(content_type)
        }

      true ->
        nil
    end
  end

  def detect_ordinal(_), do: nil

  @doc """
  Categorizes a MIME type into a media category.
  """
  def categorize_mime(nil), do: :other
  def categorize_mime(mime) when mime in @image_mime_types, do: :image
  def categorize_mime(mime) when mime in @text_mime_types, do: :text
  def categorize_mime(_), do: :other

  @doc """
  Parses a b:// URI and returns the txid.

  ## Examples

      iex> Bitblocks.ContentDetector.parse_b_uri("b://abc123def456")
      {:ok, "abc123def456"}
  """
  def parse_b_uri("b://" <> txid) when byte_size(txid) > 0, do: {:ok, txid}
  def parse_b_uri("B://" <> txid) when byte_size(txid) > 0, do: {:ok, txid}
  def parse_b_uri(_), do: {:error, "Invalid b:// URI"}

  # Private helpers

  defp detect_from_output(output_str) when is_binary(output_str) do
    case Jason.decode(output_str) do
      {:ok, %{"data" => data}} when is_binary(data) ->
        detect_from_data_string(data)

      {:ok, %{"script" => script}} when is_binary(script) ->
        detect_from_script_hex(script)

      _ ->
        nil
    end
  end

  defp detect_from_output(_), do: nil

  defp detect_from_data_string(data) do
    cond do
      String.starts_with?(data, @b_protocol_address) ->
        %{
          protocol: "B://",
          content_type: "application/octet-stream",
          media_category: :other,
          encoding: nil,
          filename: nil,
          size: byte_size(data)
        }

      String.contains?(data, "ord") ->
        %{
          protocol: "1Sat Ordinals",
          content_type: "application/octet-stream",
          media_category: :other,
          encoding: nil,
          filename: nil,
          size: byte_size(data)
        }

      true ->
        nil
    end
  end

  defp detect_from_script_hex(_hex), do: nil

  defp parse_b_protocol_fields(chunks) do
    # B:// format: <data> <media_type> <encoding> <filename>
    content_type =
      case Enum.at(chunks, 1) do
        %{utf8: mime} when is_binary(mime) -> mime
        _ -> "application/octet-stream"
      end

    encoding =
      case Enum.at(chunks, 2) do
        %{utf8: enc} when is_binary(enc) and enc != "" -> enc
        _ -> nil
      end

    filename =
      case Enum.at(chunks, 3) do
        %{utf8: name} when is_binary(name) and name != "" -> name
        _ -> nil
      end

    data_chunk = Enum.at(chunks, 0)
    size = if data_chunk, do: data_chunk[:length] || 0, else: 0

    %{
      protocol: "B://",
      content_type: content_type,
      media_category: categorize_mime(content_type),
      encoding: encoding,
      filename: filename,
      size: size
    }
  end

  defp extract_ordinal_content_type(chunks) do
    # Look for a MIME type string in the chunks
    chunks
    |> Enum.find_value(fn
      %{utf8: utf8} when is_binary(utf8) ->
        if String.contains?(utf8, "/") and not String.starts_with?(utf8, "ord") do
          utf8
        end

      _ ->
        nil
    end)
  end
end
