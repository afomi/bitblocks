defmodule BitblocksWeb.Api.FileController do
  @moduledoc """
  `GET /api/v1/files?q=&type=&cursor=`: find a file in the C:// index of B://
  and BCat files (`Bitblocks.CFiles.Search`,
  https://github.com/afomi/bitblocks/issues/175), the twin of the search on
  `/files`.

  `data` is the matching files, newest block first, each as
  `/api/v1/c/:sha256` shows a location plus `c_url` and `file_url`. `meta`
  has `next_cursor` (null on the last page) and how far the index reaches
  (`indexed_through_height`, null until a backfill covers block 0;
  `earliest_indexed_height`; `complete_through`; `bcat_unassembled`). An
  empty `data` is only a miss in our index, never proof a file doesn't
  exist.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.CFiles
  alias Bitblocks.CFiles.Search

  def index(conn, params) do
    q = Search.normalize_query(params["q"])
    type = params["type"]

    case Search.search(q: q, type: type, cursor: params["cursor"]) do
      {:ok, page} ->
        json(conn, %{
          data: Enum.map(page.files, &file/1),
          meta:
            Map.merge(Search.coverage(), %{
              q: q,
              type: if(type in [nil, ""], do: nil, else: type),
              next_cursor: page.next_cursor,
              source: "c_files",
              version: CFiles.version()
            })
        })

      {:error, :invalid_type} ->
        conn
        |> put_status(400)
        |> json(%{error: "type is one of #{Enum.join(Search.types(), ", ")}, or left out."})

      {:error, :invalid_cursor} ->
        conn
        |> put_status(400)
        |> json(%{error: "cursor is the next_cursor of the page before: <height>:<id>."})

      {:error, _reason} ->
        conn
        |> put_status(503)
        |> put_resp_header("retry-after", "30")
        |> json(%{
          error: "unavailable",
          message: "The search couldn't finish just now. Try again in a minute, or narrow it."
        })
    end
  end

  defp file(row) do
    public = CFiles.public(row)
    Map.merge(public, %{c_url: "c://" <> public.sha256, file_url: "/c/" <> public.sha256})
  end
end
