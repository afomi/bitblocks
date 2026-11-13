defmodule BitblocksWeb.FlowTileController do
  @moduledoc """
  Serves `/tx-graph` flow tiles (`Bitblocks.FlowTiles`, #67) and their
  manifest from `Bitblocks.ChainTiles.Cache` (ETS), behind the
  `:admin_data` gate. No action here queries `transactions` or any table
  but the session's user row; `test/bitblocks_web/controllers/flow_tile_controller_test.exs`
  holds that.

      GET /chain-scrubber/flow-tiles/manifest
      GET /chain-scrubber/flow-tiles/:idx?v=<hash>

  A tile URL carries its content hash, so it is served immutable; a stale
  hash is a 404 and the client refetches the manifest.
  """

  use BitblocksWeb, :controller

  alias Bitblocks.ChainTiles.Cache
  alias Bitblocks.FlowTiles

  @immutable "private, max-age=31536000, immutable"

  def manifest(conn, _params) do
    case Cache.flow_manifest() do
      nil ->
        conn
        |> put_status(404)
        |> put_resp_header("cache-control", "private, no-store")
        |> json(%{error: "not_built", hint: "Bitblocks.Release.build_flow_tiles()"})

      manifest ->
        conn
        |> put_resp_header("cache-control", "private, no-cache")
        |> json(manifest)
    end
  end

  def tile(conn, %{"idx" => idx} = params) do
    with {idx, ""} <- Integer.parse(idx),
         {:ok, tile} <- Cache.fetch(FlowTiles.level(), idx),
         true <- params["v"] in [nil, tile.hash] do
      cache_control = if params["v"], do: @immutable, else: "private, no-cache"

      conn
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header("cache-control", cache_control)
      |> put_resp_header("etag", ~s("#{tile.hash}"))
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
