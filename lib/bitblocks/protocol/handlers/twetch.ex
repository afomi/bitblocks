defmodule Bitblocks.Protocol.Handlers.Twetch do
  @moduledoc """
  Twetch — piped `B:// | MAP | AIP` posts.

  Detected either by Twetch's own Bitcom address as a segment prefix, or by a
  MAP segment carrying `app=twetch` (the common case — Twetch posts are
  identified by app metadata, not their own address).
  """

  use Bitblocks.Protocol.Handler,
    name: "Twetch",
    prefix: "19nknDdM3ueaAt7nFLFQ3aS3PVHVnJoMmU"

  alias Bitblocks.MapParser
  alias Bitblocks.Protocol.Context

  @b_address "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"
  @map_address "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"
  @aip_address "15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva"

  @impl true
  def detect(%Context{segments: segments}) do
    Enum.any?(segments, fn
      [@map_address | map_chunks] -> MapParser.parse_set(map_chunks)["app"] == "twetch"
      _ -> false
    end)
  end

  @impl true
  def parse(data_chunks) do
    utf8_chunks = Bitblocks.Script.OpReturn.utf8_chunks(data_chunks)
    segments = MapParser.extract_protocols(utf8_chunks)

    b_data = find_segment(segments, @b_address)
    map_data = find_segment(segments, @map_address)
    aip_data = find_segment(segments, @aip_address)

    case MapParser.parse_set(map_data) do
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

  defp find_segment(segments, address) do
    Enum.find_value(segments, nil, fn
      {^address, data} -> data
      _ -> nil
    end)
  end

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
end
