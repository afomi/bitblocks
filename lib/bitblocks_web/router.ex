defmodule BitblocksWeb.Router do
  use BitblocksWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BitblocksWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :admin do
    plug :browser
    plug :basic_auth
  end

  defp basic_auth(conn, _opts) do
    username = System.get_env("ADMIN_USERNAME") || "admin"
    password = System.get_env("ADMIN_PASSWORD") || "secret"

    Plug.BasicAuth.basic_auth(conn, username: username, password: password)
  end

  scope "/", BitblocksWeb do
    pipe_through :browser

    live "/blocks", BlockLive.Index, :index
    live "/blocks/new", BlockLive.Index, :new
    live "/blocks/:id/edit", BlockLive.Index, :edit

    live "/blocks/:id", BlockLive.Show, :show
    live "/blocks/:id/show/edit", BlockLive.Show, :edit

    # Transactions are only accessible by direct txid lookup (no public list)
    live "/transactions/:id", TransactionLive.Show, :show
    live "/transactions/:id/show/edit", TransactionLive.Show, :edit

    live "/search", SearchLive
    live "/protocols", ProtocolsLive

    get "/wall", WallController, :index
    get "/wall/blocks_data", WallController, :blocks_data

    get "/apps", PageController, :applications
    get "/resources", PageController, :resources
    get "/status", PageController, :status
    get "/", PageController, :home
  end

  scope "/", BitblocksWeb do
    # In dev, just use browser pipeline; in prod, require auth
    pipe_through if Mix.env() == :dev, do: :browser, else: :admin

    get "/config", PageController, :config
    get "/debug", PageController, :debug

    # Dev-only routes
    live "/builder", BuilderLive
    live "/sync", SyncLive
    live "/reporting", ReportingLive
    live "/highlights", HighlightsLive
    live "/graph", GraphLive

    # Transaction list only for dev/admin (too many transactions for public browsing)
    live "/transactions", TransactionLive.Index, :index
    live "/transactions/new", TransactionLive.Index, :new
    live "/transactions/:id/edit", TransactionLive.Index, :edit
  end

  # Admin-only routes (protected by basic auth in production)
  if Application.compile_env(:bitblocks, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      # In dev, just use browser pipeline; in prod, require auth
      pipe_through if Mix.env() == :dev, do: :browser, else: :admin

      live_dashboard "/dashboard", metrics: BitblocksWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
