defmodule BitblocksWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :bitblocks

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_bitblocks_key",
    signing_salt: "+2ADwU4P",
    same_site: "Lax"
  ]

  # Health check for ALB — force_ssl excludes this path in prod.exs
  plug :healthz

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options], timeout: 45_000],
    longpoll: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :bitblocks,
    gzip: false,
    only: BitblocksWeb.static_paths()

  # Serve Rexxie NFT images from the rexxie-indexer repo
  plug Plug.Static,
    at: "/images/rexxies",
    from: Path.expand("~/workspace/rexxie-indexer/images"),
    gzip: false,
    cache_control_for_etags: "public, max-age=86400"

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :bitblocks
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug BitblocksWeb.Plugs.IpBlocker
  plug BitblocksWeb.Plugs.RateLimiter
  plug BitblocksWeb.Plugs.RequestLogger
  plug BitblocksWeb.Router

  defp healthz(%{request_path: "/healthz"} = conn, _opts) do
    conn
    |> Plug.Conn.send_resp(200, "ok")
    |> Plug.Conn.halt()
  end

  defp healthz(conn, _opts), do: conn
end
