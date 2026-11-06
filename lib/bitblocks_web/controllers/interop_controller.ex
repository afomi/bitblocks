defmodule BitblocksWeb.InteropController do
  @moduledoc """
  `GET /interop/vectors/v1.json`: the published test vectors, open to anyone
  with no key, since a kit that needs our key isn't neutral. The bytes are held
  in the module (`Bitblocks.Interop.Vectors`), so this reads no database.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Interop.Vectors

  @doc "GET /interop/vectors/LICENSE.txt, the licence the file's notice names."
  def license(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=86400")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("text/plain")
    |> send_resp(200, Vectors.license())
  end

  @doc "GET /interop/vectors/v1.json"
  def vectors(conn, _params) do
    etag = ~s("#{Vectors.sha256()}")

    conn =
      conn
      |> put_resp_header("cache-control", "public, max-age=3600")
      |> put_resp_header("etag", etag)
      |> put_resp_header("x-content-type-options", "nosniff")

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Vectors.body())
    end
  end
end
