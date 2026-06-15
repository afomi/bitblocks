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

  scope "/api/v1", BitblocksWeb.Api do
    pipe_through :api

    # Blocks
    get "/blocks/latest", BlockController, :latest
    get "/blocks/at_time", BlockController, :at_time
    get "/blocks/at_height", BlockController, :at_height
    get "/blocks/time_map", BlockController, :time_map
    get "/blocks/:id", BlockController, :show
    get "/blocks", BlockController, :index

    # Addresses (proxied to WhatsOnChain until we have our own UTXO index)
    get "/addresses/:address/utxos", AddressController, :utxos
    get "/addresses/:address/balance", AddressController, :balance

    # UTXOs — outpoint ownership lookup (proxied to WhatsOnChain until local UTXO set exists)
    get "/utxo/:txid/:vout/owner", UtxoController, :owner

    # Transactions
    get "/txs/:txid/proof", ProofController, :show
    get "/txs/:txid", TransactionController, :show
    get "/txs", TransactionController, :index

    # Real-time
    get "/stream/blocks", StreamController, :blocks
    get "/stream/order-book", StreamController, :order_book

    # Mining
    get "/mining/work", MiningController, :work
    get "/mining/status", MiningController, :status
    post "/mining/submit", MiningController, :submit

    # Metanet
    get "/metanet/roots", MetanetController, :roots
    get "/metanet/:txid/children", MetanetController, :children
    get "/metanet/:txid", MetanetController, :show

    # Order Book
    get "/order-book/listings", OrderBookController, :index
    get "/order-book/stats", OrderBookController, :stats
    get "/order-book/tokens/:token_id/market", OrderBookController, :token_market
    get "/order-book/tokens/:token_id/trades", OrderBookController, :token_trades
    get "/order-book/tokens/:token_id", OrderBookController, :token_listings
    get "/order-book/sellers/:address", OrderBookController, :seller_listings
    get "/order-book/listings/:txid", OrderBookController, :show

    # Protocols
    get "/protocols", ProtocolController, :index
    get "/protocols/stats", ProtocolController, :stats_overview
    get "/protocols/search", ProtocolController, :search
    get "/protocols/:address/feed", ProtocolController, :feed
    get "/protocols/:address", ProtocolController, :show
    post "/protocols/identify", ProtocolController, :identify
  end

  pipeline :metrics do
    plug :accepts, ["text"]
  end

  pipeline :admin do
    plug :browser
    plug :basic_auth
  end

  # T10: refuse to serve the admin surface with built-in default credentials in
  # production — a hard 503 beats a trivially-owned admin panel. The decision
  # lives in BitblocksWeb.AdminAuth (pure + tested).
  defp basic_auth(conn, _opts) do
    case BitblocksWeb.AdminAuth.decision() do
      {:ok, username, password} ->
        Plug.BasicAuth.basic_auth(conn, username: username, password: password)

      {:error, :default_credentials} ->
        require Logger
        Logger.error("Admin auth refused: ADMIN_USERNAME/ADMIN_PASSWORD not set in production")

        conn
        |> Plug.Conn.send_resp(503, "Admin interface not configured")
        |> Plug.Conn.halt()
    end
  end

  scope "/", BitblocksWeb do
    pipe_through :browser

    live "/search", SearchLive
    live "/protocols", ProtocolsLive
    live "/order-book", OrderBookLive
    live "/metanet", MetanetLive
    live "/collections/rexxies", RexxiesLive
    live "/about", AboutLive
    live "/pricing", PricingLive
    live "/guide", GuideLive
    live "/did", DIDLive

    get "/wall", WallController, :index
    get "/wall/blocks_data", WallController, :blocks_data
    get "/reward_wall", RewardWallController, :index
    get "/reward_wall/reward_data", RewardWallController, :reward_data
    get "/reward_wall/address_data", RewardWallController, :address_data

    get "/apps", PageController, :applications
    get "/resources", PageController, :resources
    get "/status", PageController, :status
    get "/", PageController, :home
  end

  scope "/", BitblocksWeb do
    # In dev, just use browser pipeline; in prod, require auth
    pipe_through if Mix.env() in [:dev, :test], do: :browser, else: :admin

    get "/config", PageController, :config
    get "/debug", PageController, :debug

    # Dev-only routes
live "/address_repo", AddressRepoLive
    live "/forks", ForkGraphLive
    live "/sync", SyncLive
    live "/reporting", ReportingLive
    live "/highlights", HighlightsLive
    live "/graph", GraphLive
    live "/block-graph", BlockGraphLive
    live "/rpc_admin", RpcAdminLive
    live "/peers", PeerMapLive
    live "/pulse", PulseLive
    live "/ecosystem", EcosystemLive
    live "/tx-graph", TxGraphLive
    live "/shape-layers", ShapeLayerLive

    # Block pages only for dev/admin (too many requests for public access)
    live "/blocks", BlockLive.Index, :index
    live "/blocks/new", BlockLive.Index, :new
    live "/blocks/:id/edit", BlockLive.Index, :edit
    live "/blocks/:id", BlockLive.Show, :show
    live "/blocks/:id/show/edit", BlockLive.Show, :edit

    # Transaction pages only for dev/admin (too many requests for public access)
    live "/transactions", TransactionLive.Index, :index
    live "/transactions/new", TransactionLive.Index, :new
    live "/transactions/:id", TransactionLive.Show, :show
    live "/transactions/:id/edit", TransactionLive.Index, :edit
    live "/transactions/:id/show/edit", TransactionLive.Show, :edit
  end

  scope "/" do
    pipe_through(if Mix.env() in [:dev, :test], do: [:metrics], else: [:metrics, :admin])

    forward "/metrics", TelemetryMetricsPrometheus.Router, name: Bitblocks.TelemetryPrometheus
  end

  # Admin-only routes (protected by basic auth in production)
  if Application.compile_env(:bitblocks, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      # In dev, just use browser pipeline; in prod, require auth
      pipe_through if Mix.env() in [:dev, :test], do: :browser, else: :admin

      live_dashboard "/dashboard", metrics: BitblocksWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
