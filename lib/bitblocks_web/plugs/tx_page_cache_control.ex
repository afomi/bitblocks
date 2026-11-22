defmodule BitblocksWeb.Plugs.TxPageCacheControl do
  @moduledoc """
  Lets a browser keep a deep-confirmed transaction page for a while.

  When `TransactionLive.Show` served `GET /transactions/:txid` from, or into,
  `TransactionLive.PageCache` (the tx is buried at least 100 blocks), a
  signed-out 200 is sent with `Cache-Control: private, max-age=<the
  cache's ttl>` in place of Phoenix's `max-age=0, private,
  must-revalidate`. A signed-in page, which carries the viewer's name and
  role, keeps the default.

  `private`, not `public`: the HTML carries the viewer's CSRF token and
  LiveView session, and the response sets the session cookie. A shared
  cache would hand one viewer's token to another, and their LiveView
  would fail to connect and reload. A shared cache in front of these
  pages needs that HTML made cookie-free first.
  """

  @behaviour Plug

  import Plug.Conn

  alias BitblocksWeb.TransactionLive.PageCache

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method, path_info: ["transactions", _id]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    # A keep-alive connection runs its requests in one process: start clean.
    PageCache.clear_cacheable()
    register_before_send(conn, &cache_control/1)
  end

  def call(conn, _opts), do: conn

  defp cache_control(%Plug.Conn{status: 200} = conn) do
    if PageCache.cacheable?() and is_nil(get_session(conn, "user_id")) do
      put_resp_header(conn, "cache-control", "private, max-age=#{PageCache.ttl_s()}")
    else
      conn
    end
  end

  defp cache_control(conn), do: conn
end
