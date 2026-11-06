defmodule BitblocksWeb.Plugs.RequireCaller do
  @moduledoc """
  Lets through only a caller we can name: an API key or a signed-in session (#12).

  `BitblocksWeb.Plugs.RateLimiter` has already verified the key or the session
  and set `:caller_tier`, so this adds no query. A bad key never reaches here;
  anything else is a 401. Follows the sign-in gates (`BitblocksWeb.AdminAuth`),
  which config/test.exs turns off for the suite.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if BitblocksWeb.AdminAuth.enabled?() and conn.assigns[:caller_tier] in [nil, :anonymous] do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        401,
        Jason.encode!(%{
          error: "Sign in at /sign-in, or send an API key as Authorization: Bearer <key>"
        })
      )
      |> halt()
    else
      conn
    end
  end
end
