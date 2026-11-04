defmodule BitblocksWeb.Plugs.RequireJsonBody do
  @moduledoc """
  Refuses a POST, PUT or PATCH whose body isn't `application/json` (415).

  This is the CSRF guard for admin JSON writes that a browser authenticates
  on its own (the session cookie, or cached basic-auth credentials): a
  cross-site form can only send urlencoded, multipart or text/plain bodies,
  and a cross-site `fetch` with a JSON body needs a CORS preflight that these
  routes never grant. A DELETE carries no body, and no form can send one.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: method} = conn, _opts) when method in ["POST", "PUT", "PATCH"] do
    case get_req_header(conn, "content-type") do
      ["application/json" <> _ | _] ->
        conn

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(415, ~s({"error":"Send the body as application/json"}))
        |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
