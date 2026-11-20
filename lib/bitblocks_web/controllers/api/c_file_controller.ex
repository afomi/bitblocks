defmodule BitblocksWeb.Api.CFileController do
  @moduledoc """
  `GET /api/v1/c/:sha256`: where a file with this C:// address (the sha256
  of its bytes) is stored on chain, from the `c_files` index
  (`Bitblocks.CFiles`, https://github.com/afomi/bitblocks/issues/147).

  `data` lists every stored file with those bytes, oldest block first, each
  with its `kind`: `"b"` for a B:// output, `"bcat"` for a BCat file
  assembled from its chunks (https://github.com/afomi/bitblocks/issues/155),
  at its head's txid, with `chunks` and `bcat_url`. `file_url` is
  `/c/:sha256`, which serves the bytes once they hash to the address. `meta` says how far the index reaches:
  `indexed_through_height` (null until a backfill covers the chain from
  block 0), `complete_through` and `bcat_unassembled` (BCat heads we know
  of that couldn't be assembled, so their addresses aren't indexed). An
  address the index doesn't hold is a
  404 with the same `meta`, since a miss below that line is only a miss in
  our index, never proof the file doesn't exist.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.CFiles

  def show(conn, %{"sha256" => raw}) do
    with {:ok, sha256} <- CFiles.parse_address(raw),
         [_ | _] = locations <- CFiles.locations(sha256) do
      hex = String.downcase(raw)

      json(conn, %{
        data: %{
          sha256: hex,
          c_url: "c://#{hex}",
          file_url: "/c/#{hex}",
          locations: Enum.map(locations, &CFiles.public/1)
        },
        meta: meta()
      })
    else
      :error ->
        conn
        |> put_status(400)
        |> json(%{
          error:
            "A C:// address is the sha256 of a file's bytes: 64 hex characters, as /api/v1/c/<sha256>."
        })

      [] ->
        conn |> put_status(404) |> json(not_indexed(String.downcase(raw)))
    end
  end

  @doc """
  The answer for an address the index doesn't hold, shared with `/c/:sha256`:
  what was asked, how far the index reaches, and what that means.
  """
  @spec not_indexed(String.t()) :: map()
  def not_indexed(hex) do
    meta = meta()

    %{
      error: "not_indexed",
      message: message(meta),
      sha256: hex,
      meta: meta
    }
  end

  defp meta do
    Map.merge(CFiles.coverage(), %{source: "c_files", version: CFiles.version()})
  end

  defp message(%{indexed_through_height: nil} = meta) do
    "No B:// or BCat file we have indexed hashes to this C:// address. " <>
      "The index holds the files in blocks synced since it shipped, and hasn't been backfilled from block 0 yet, " <>
      "so a file in an older block may be missing from it." <> unassembled(meta)
  end

  defp message(%{indexed_through_height: h, complete_through: c} = meta) do
    "No B:// or BCat file in blocks 0 to #{h} hashes to this C:// address. " <>
      "The sync is complete through block #{c}, and later blocks aren't stored yet." <>
      unassembled(meta)
  end

  defp unassembled(%{bcat_unassembled: 0}), do: ""

  defp unassembled(%{bcat_unassembled: 1}),
    do:
      " One BCat file we know of couldn't be assembled from its chunks, so its address isn't indexed."

  defp unassembled(%{bcat_unassembled: n}),
    do:
      " #{n} BCat files we know of couldn't be assembled from their chunks, so their addresses aren't indexed."
end
