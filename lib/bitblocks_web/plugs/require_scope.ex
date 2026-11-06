defmodule BitblocksWeb.Plugs.RequireScope do
  @moduledoc """
  Lets through only a request whose API key holds a scope (#50).

      plug BitblocksWeb.Plugs.RequireScope, "ops_read"

  `BitblocksWeb.Plugs.RateLimiter` has already verified the key and refused a
  bad one. No key is a 401, and a key without the scope is a 403; a signed-in
  session doesn't count, because these routes are for keys alone.
  """

  import Plug.Conn

  def init(scope) when is_binary(scope), do: scope

  def call(conn, scope) do
    case conn.assigns[:api_key] do
      nil ->
        refuse(conn, 401, "An API key is required")

      key ->
        if Bitblocks.ApiKeys.scope?(key, scope) do
          conn
        else
          refuse(conn, 403, "This API key does not have the #{scope} scope")
        end
    end
  end

  defp refuse(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end
