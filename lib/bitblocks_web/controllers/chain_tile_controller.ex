defmodule BitblocksWeb.ChainTileController do
  @moduledoc """
  Serves chain-scrubber tiles and their manifest from
  `Bitblocks.ChainTiles.Cache` (ETS). No action here touches the database:
  the route runs through the `:admin_data` pipeline, which is the session and
  its user's row, and `test/bitblocks_web/controllers/chain_tile_controller_test.exs`
  asserts that is the only table read.

  A tile URL carries its content hash (`?v=`), so it is served immutable;
  a stale hash is a 404 and the client refetches the manifest.
  """

  use BitblocksWeb, :controller

  alias Bitblocks.ChainTiles.Cache

  @immutable "private, max-age=31536000, immutable"

  def manifest(conn, _params) do
    case Cache.manifest() do
      nil ->
        conn
        |> put_status(404)
        |> put_resp_header("cache-control", "private, no-store")
        |> json(%{error: "not_built", hint: "Bitblocks.Release.build_chain_tiles()"})

      manifest ->
        conn
        |> put_resp_header("cache-control", "private, no-cache")
        |> json(manifest)
    end
  end

  def tile(conn, %{"level" => level, "idx" => idx} = params) do
    with {level, ""} <- Integer.parse(level),
         {idx, ""} <- Integer.parse(idx),
         {:ok, tile} <- Cache.fetch(level, idx),
         true <- params["v"] in [nil, tile.hash] do
      cache_control = if params["v"], do: @immutable, else: "private, no-cache"

      conn
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header("cache-control", cache_control)
      |> put_resp_header("etag", ~s("#{tile.hash}"))
      |> put_resp_header("x-tile-hash", tile.hash)
      |> send_resp(200, tile.bytes)
    else
      _ ->
        conn
        |> put_status(404)
        |> put_resp_header("cache-control", "private, no-store")
        |> json(%{error: "no_such_tile"})
    end
  end
end
