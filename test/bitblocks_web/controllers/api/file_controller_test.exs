defmodule BitblocksWeb.Api.FileControllerTest do
  # GET /api/v1/files (https://github.com/afomi/bitblocks/issues/175): find a
  # file in the C:// index by name, type or address.
  use BitblocksWeb.ConnCase, async: true

  alias Bitblocks.CFiles

  defp put(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    row = %{
      sha256: :crypto.hash(:sha256, attrs.filename),
      txid: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      vout: 0,
      block_height: Map.get(attrs, :block_height, 640_000),
      kind: "b",
      chunks: nil,
      media_type: Map.get(attrs, :media_type, "text/plain"),
      encoding: nil,
      filename: attrs.filename,
      size: 5,
      version: CFiles.version(),
      inserted_at: now,
      updated_at: now
    }

    CFiles.write([row])
    row
  end

  test "finds files by name and type, with their links and the index's reach", %{conn: conn} do
    cat = put(%{filename: "cat.png", media_type: "image/png"})
    put(%{filename: "cat.txt"})
    sha = Base.encode16(cat.sha256, case: :lower)

    body = conn |> get(~p"/api/v1/files?q=CAT&type=image") |> json_response(200)

    assert %{
             "data" => [
               %{
                 "sha256" => ^sha,
                 "kind" => "b",
                 "filename" => "cat.png",
                 "media_type" => "image/png",
                 "block_height" => 640_000,
                 "b_url" => b_url,
                 "c_url" => c_url,
                 "file_url" => file_url
               }
             ],
             "meta" => %{
               "q" => "CAT",
               "type" => "image",
               "next_cursor" => nil,
               "indexed_through_height" => nil,
               "earliest_indexed_height" => 640_000,
               "bcat_unassembled" => 0,
               "source" => "c_files"
             }
           } = body

    assert b_url == "/b/" <> cat.txid
    assert c_url == "c://" <> sha
    assert file_url == "/c/" <> sha
  end

  test "a 64-hex q matches that address; the cursor pages", %{conn: conn} do
    rows = for h <- 1..3, do: put(%{filename: "f#{h}", block_height: h})
    sha = rows |> hd() |> Map.fetch!(:sha256) |> Base.encode16(case: :lower)

    assert [%{"filename" => "f1"}] =
             conn |> get(~p"/api/v1/files?q=#{sha}") |> json_response(200) |> Map.get("data")

    %{"data" => [_, _ | _] = all, "meta" => %{"next_cursor" => nil}} =
      conn |> get(~p"/api/v1/files") |> json_response(200)

    assert Enum.map(all, & &1["filename"]) == ["f3", "f2", "f1"]
  end

  test "a bad type or cursor is a 400 naming the accepted shape", %{conn: conn} do
    assert %{"error" => "type is one of image, text, json, html, other" <> _} =
             conn |> get(~p"/api/v1/files?type=pdf") |> json_response(400)

    assert %{"error" => "cursor is the next_cursor" <> _} =
             conn |> get(~p"/api/v1/files?cursor=nope") |> json_response(400)
  end
end
