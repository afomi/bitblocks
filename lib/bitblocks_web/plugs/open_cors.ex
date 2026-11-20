defmodule BitblocksWeb.Plugs.OpenCors do
  @moduledoc """
  CORS for the routes any site may call from a browser: one behaviour for all
  of them (https://github.com/afomi/bitblocks/issues/121).

  A route is covered when the router pipes it through one of
  `cors_pipelines/0` (`:open_api`, `:public_api`, `:public_csv`); the router
  stays the one list of which routes those are. Everything else gets no CORS
  headers, as before.

  On a covered path:

    * `OPTIONS` (a preflight) is answered here with a 204 naming the allowed
      origin, the path's methods, the request headers we read and a max age.
      It is halted before `BitblocksWeb.Plugs.RateLimiter`, so a preflight
      costs no budget: it carries no work and no caller, and the request it
      precedes is counted as usual.
    * Any other method gets `access-control-allow-origin: *` and
      `access-control-expose-headers` before the rate limiter runs, so its
      429, 402 and 401 carry them too, and a page can read `Retry-After` and
      the `x-ratelimit-*` headers.

  Never `access-control-allow-credentials`: these routes take no cookies from
  other sites (a key goes in a header), and browsers refuse `*` with
  credentials anyway.

  Sits in the endpoint after `IpBlocker`, so a blocked address is still
  refused, and before the rate limiter.
  """

  import Plug.Conn

  @cors_pipelines [:open_api, :public_api, :public_csv]
  @allow_headers "accept, authorization, content-type, x-api-key"
  @expose_headers "retry-after, x-ratelimit-limit, x-ratelimit-remaining, content-disposition"
  @max_age "86400"

  @doc "The router pipelines whose routes are open to every origin."
  def cors_pipelines, do: @cors_pipelines

  def init(opts), do: opts

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    case allowed_methods(conn) do
      [] ->
        conn

      methods ->
        conn
        |> put_resp_header("access-control-allow-origin", "*")
        |> put_resp_header(
          "access-control-allow-methods",
          Enum.join(methods ++ ["OPTIONS"], ", ")
        )
        |> put_resp_header("access-control-allow-headers", @allow_headers)
        |> put_resp_header("access-control-max-age", @max_age)
        |> put_resp_header("allow", Enum.join(methods ++ ["OPTIONS"], ", "))
        |> send_resp(204, "")
        |> halt()
    end
  end

  def call(conn, _opts) do
    if open?(conn, conn.method) do
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-expose-headers", @expose_headers)
    else
      conn
    end
  end

  # The methods this path answers on a covered route; HEAD is answered as GET.
  defp allowed_methods(conn) do
    Enum.filter(["GET", "POST"], &open?(conn, &1))
  end

  defp open?(conn, method) do
    method = if method == "HEAD", do: "GET", else: method

    case Phoenix.Router.route_info(BitblocksWeb.Router, method, conn.path_info, conn.host) do
      %{pipe_through: pipes} -> Enum.any?(pipes, &(&1 in @cors_pipelines))
      _ -> false
    end
  end
end
