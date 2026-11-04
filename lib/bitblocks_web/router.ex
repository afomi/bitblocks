defmodule BitblocksWeb.Router do
  use BitblocksWeb, :router

  import BitblocksWeb.UserAuth,
    only: [
      fetch_current_user: 2,
      require_user: 2,
      require_admin: 2,
      require_admin_data: 2
    ]

  alias BitblocksWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BitblocksWeb.Layouts, :root}
    plug BitblocksWeb.ReorgNotice
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :public_api do
    plug :accepts, ["json"]
    plug CORSPlug, origin: "*"
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
    get "/addresses/:address/tokens", AddressController, :tokens

    # Is this outpoint an ordinal/token? yes | no | unknown (fail-closed wallets)
    get "/outpoints/:txid/:vout", OutpointController, :show

    # UTXOs — outpoint ownership lookup (proxied to WhatsOnChain until local UTXO set exists)
    get "/utxo/:txid/:vout/owner", UtxoController, :owner

    # Transactions
    get "/txs/:txid/proof", ProofController, :show
    get "/txs/:txid", TransactionController, :show
    get "/txs", TransactionController, :index

    # WhatsOnChain-compatible alias layer — bare (un-enveloped) responses with
    # WoC field names, so WoC clients work with minimal changes. The native
    # endpoints above remain primary. See docs/EXTERNAL_APIS.md.
    get "/woc/chain/info", WocController, :chain_info
    get "/woc/tx/:txid/hex", WocController, :tx_hex
    post "/woc/tx/raw", WocController, :broadcast
    get "/woc/address/:address/unspent", WocController, :address_unspent
    get "/woc/address/:address/balance", WocController, :address_balance

    # Real-time
    get "/stream/blocks", StreamController, :blocks
    get "/stream/order-book", StreamController, :order_book
    get "/stream/tokens", StreamController, :tokens

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

    # Tokens (BSV-20 / BSV-21). :stats is declared before :id so it isn't
    # captured as an id.
    get "/tokens/stats", TokenController, :stats
    get "/tokens/:id/holders", TokenController, :holders
    get "/tokens/:id/transfers", TokenController, :transfers
    get "/tokens/:id", TokenController, :show
    get "/tokens", TokenController, :index

    # Scripts — script-addressed lookups for arbitrary (non-P2PKH) scripts.
    # scripthash = Electrum/WoC convention (sha256 of scriptPubKey, reversed hex).
    # /templates routes are declared before /:scripthash so "templates" isn't
    # captured as a scripthash.
    get "/script/templates/:template_hash/history", ScriptController, :template_history
    get "/script/templates/:template_hash", ScriptController, :show_template
    get "/script/templates", ScriptController, :list_templates
    post "/script/templates", ScriptController, :create_template
    post "/script/decode", ScriptController, :decode
    get "/script/:scripthash/history", ScriptController, :history
    get "/script/:scripthash/unspent", ScriptController, :unspent

    # Protocols
    get "/protocols", ProtocolController, :index
    get "/protocols/stats", ProtocolController, :stats_overview
    get "/protocols/search", ProtocolController, :search
    get "/protocols/:address/feed", ProtocolController, :feed
    get "/protocols/:address", ProtocolController, :show
    post "/protocols/identify", ProtocolController, :identify

    # Bitcom registry
    get "/bitcom", BitcomController, :index
    get "/bitcom/:address", BitcomController, :show
    get "/bit/:address/*path", BitcomController, :resolve
    post "/bitcom/compose", BitcomController, :compose

    # Managed projections (#29): hydrate a tenant's filter with a cursor
    get "/projections/:id/txs", ProjectionController, :txs
    get "/projections/:id/status", ProjectionController, :status
    get "/projections/:id", ProjectionController, :show

    # 1Sat ordinal collections (#30): proven membership, traced ownership
    post "/collections/:id/items/lookup", CollectionController, :lookup
    get "/collections/:id/items/:outpoint", CollectionController, :item
    get "/collections/:id/items", CollectionController, :items
    get "/collections/:id", CollectionController, :show
  end

  # Open to all origins — cached, lightweight, and intended for external
  # sites: price for qart, support for the sponsorship page (off-site).
  scope "/api/v1", BitblocksWeb.Api do
    pipe_through :public_api

    get "/status", StatusController, :show
    get "/price/bsv", PriceController, :show
    get "/support", SupportController, :show
  end

  # Own scope, no pipeline: the :browser pipeline only accepts html.
  scope "/", BitblocksWeb do
    get "/sitemap.xml", SitemapController, :index

    # Inscription bodies parsed from raw txs on the fly (1Sat /content convention).
    get "/content/:outpoint", ContentController, :show
  end

  # The Bitcom registry export, at a stable top-level path.
  scope "/", BitblocksWeb.Api do
    pipe_through :public_api

    get "/bitcom.json", BitcomController, :index
  end

  pipeline :metrics do
    plug :accepts, ["text"]
  end

  # Access model (BitblocksWeb.UserAuth): the explorer front is public;
  # block and transaction detail need a signed-in GitHub user; the operator
  # surface needs an admin, meaning a GitHub user with a verified email on
  # ADMIN_EMAILS OR valid HTTP basic auth. Either one admits you.
  #
  # The gate runs in EVERY env. Enforcement is a runtime toggle
  # (`config :bitblocks, :admin_auth, enabled: true|false`, default true):
  # prod keeps the T10 fail-closed behavior (basic auth on default creds is
  # refused), dev runs with logged dev-default creds, and test disables the
  # gate in config/test.exs so existing tests can hit /sync, /config, etc.
  #
  # Each LiveView route also sits in a live_session whose on_mount hook holds
  # the same line on the websocket, which these plugs never see.
  pipeline :admin do
    plug :browser
    plug :require_admin
  end

  pipeline :signed_in do
    plug :require_user
  end

  # Admin data the browser fetches by script: no :browser pipeline.
  # :browser runs ReorgNotice and loads the current user, both database
  # queries; chain-scrubber tiles must be served without a query (#48), so
  # this gate reads only the signed session cookie and basic auth.
  pipeline :admin_data do
    plug :require_admin_data
  end

  scope "/", BitblocksWeb do
    pipe_through :browser

    get "/sign-in", AuthController, :sign_in
    get "/auth/github", AuthController, :request
    get "/auth/github/callback", AuthController, :callback
    delete "/auth/logout", AuthController, :logout
  end

  scope "/", BitblocksWeb do
    pipe_through :browser

    live_session :public,
      on_mount: [{UserAuth, :mount_current_user}],
      session: {UserAuth, :live_session_data, []} do
      live "/search", SearchLive
      live "/protocols", ProtocolsLive
      live "/bitcom", BitcomLive
      live "/bitcom/compose", BitcomComposeLive
      live "/bitcom/:address", BitcomLive
      live "/order-book", OrderBookLive
      live "/tokens", TokenLive
      live "/tokens/:id", TokenLive
      live "/metanet", MetanetLive
      live "/collections", CollectionLive.Index
      live "/collections/:id", CollectionLive.Show
      live "/about", AboutLive
      live "/pricing", PricingLive
      live "/guide", GuideLive
      live "/reorgs", ReorgLive
      live "/syncing", SyncingLive
      live "/did", DIDLive

      # Public block index. Detail pages need sign-in; mutation pages are admin.
      live "/blocks", BlockLive.Index, :index
    end

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

  # Declared before the signed-in scope so /blocks/new and /transactions/new
  # aren't captured by /blocks/:id and /transactions/:id.
  scope "/", BitblocksWeb do
    # Operator surface: admins only (see the access model above).
    pipe_through :admin

    get "/config", PageController, :config
    get "/debug", PageController, :debug

    live_session :admin,
      on_mount: [{UserAuth, :require_admin}],
      session: {UserAuth, :live_session_data, []} do
      live "/admin", AdminLive

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
      live "/chain-scrubber", ChainScrubberLive

      # Block and transaction mutation pages
      live "/blocks/new", BlockLive.Index, :new
      live "/blocks/:id/edit", BlockLive.Index, :edit
      live "/blocks/:id/show/edit", BlockLive.Show, :edit
      live "/transactions/new", TransactionLive.Index, :new
      live "/transactions/:id/edit", TransactionLive.Index, :edit
      live "/transactions/:id/show/edit", TransactionLive.Show, :edit
    end
  end

  scope "/", BitblocksWeb do
    # Detail pages: any signed-in GitHub user, or an admin.
    pipe_through [:browser, :signed_in]

    live_session :signed_in,
      on_mount: [{UserAuth, :require_user}],
      session: {UserAuth, :live_session_data, []} do
      live "/blocks/:id", BlockLive.Show, :show
      live "/transactions", TransactionLive.Index, :index
      live "/transactions/:id", TransactionLive.Show, :show
    end
  end

  # Raw blocks exported from our node, pushed by scripts/push_blocks.
  scope "/admin", BitblocksWeb do
    pipe_through :admin_data

    post "/blocks/:height", BlockImportController, :create
  end

  scope "/chain-scrubber", BitblocksWeb do
    pipe_through :admin_data

    get "/tiles/manifest", ChainTileController, :manifest
    get "/tiles/:level/:idx", ChainTileController, :tile
  end

  scope "/" do
    # Metrics are operator data — always behind :admin (same enablement rules
    # as the scope above).
    pipe_through [:metrics, :admin]

    forward "/metrics", TelemetryMetricsPrometheus.Router, name: Bitblocks.TelemetryPrometheus
  end

  # Admin-only routes (protected by basic auth in production)
  if Application.compile_env(:bitblocks, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      # Only compiled when :dev_routes is set (dev), but gated like the rest
      # of the operator surface anyway.
      pipe_through :admin

      live_dashboard "/dashboard", metrics: BitblocksWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
