defmodule BitblocksWeb.Api.StatusController do
  @moduledoc """
  `GET /api/v1/status`: is Bitblocks healthy, and how current is it?
  Public and cheap: `Bitblocks.Ops.health/0` reads cached state only, and
  never includes the node's address.
  """
  use BitblocksWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=15")
    |> json(Bitblocks.Ops.health())
  end

  @doc "`GET /api/v1/status/coverage`: completeness per 10k blocks, rate and ETA."
  def coverage(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=60")
    |> json(Bitblocks.Ops.coverage())
  end
end
