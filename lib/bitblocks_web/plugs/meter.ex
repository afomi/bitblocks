defmodule BitblocksWeb.Plugs.Meter do
  @moduledoc """
  Meters each request for `Bitblocks.Usage`
  (https://github.com/afomi/bitblocks/issues/61): opens the request's
  accumulator and books it at `before_send`, after the rate limiter has named
  the caller. Before the rate limiter, so its refusals are counted too.
  Adds no query, and never fails a request.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    if Bitblocks.Usage.enabled?() do
      Bitblocks.Usage.begin_request()
      Plug.Conn.register_before_send(conn, &Bitblocks.Usage.finish_request/1)
    else
      conn
    end
  rescue
    _ -> conn
  end
end
