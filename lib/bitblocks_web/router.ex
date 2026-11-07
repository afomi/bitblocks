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
    plug BitblocksWeb.IndexNotice
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  # The API takes an API key or a signed-in session (#12). The :open_api routes
  # are the only exceptions.
  pipeline :api do
    plug :accepts, ["json"]
    plug BitblocksWeb.Plugs.RequireCaller
  end

  pipeline :public_api do
    plug :accepts, ["json"]
    plug CORSPlug, origin: "*"
    plug BitblocksWeb.Plugs.RequireCaller
  end

  # No key: these are read from browsers on other sites, where a key can't be
  # kept, and by the deploy check.
  pipeline :open_api do
    plug :accepts, ["json"]
    plug CORSPlug, origin: "*"
  end

  # Declared before the :api scope so "snapshots" isn't captured as an address.
  # Open: a registry meant to be checked without trusting us shouldn't need our key.
  scope "/api/v1", BitblocksWeb.Api do
    pipe_through :open_api

    get "/bitcom/snapshots", BitcomController, :snapshots
    get "/bitcom/snapshots/:version", BitcomController, :snapshot

    # Public data a light client checks merkle roots against, from a browser (#60).
    get "/headers/:height", HeaderController, :show
    get "/headers", HeaderController, :index
  end

  # Operator tools, for an API key with the ops_read scope (#50). Read-only,
  # and no CORS: these are for sessions and scripts, not pages.
  pipeline :ops_api do
    plug :accepts, ["json"]
    plug BitblocksWeb.Plugs.RequireScope, "ops_read"
  end

  scope "/api/v1/ops", BitblocksWeb.Api do
    pipe_through :ops_api

    get "/sync", OpsController, :sync
    get "/blocks/:height", OpsController, :block
    get "/node", OpsController, :node_report
    get "/errors", OpsController, :errors

    post "/mcp", OpsMcpController, :rpc
    get "/mcp", OpsMcpController, :no_stream
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

    # BAP identities (#32): read-only, public chain data
    get "/bap", BapController, :index
    get "/bap/:bap_id/attestations", BapController, :attestations
    get "/bap/:bap_id", BapController, :show

    # Is this outpoint an ordinal/token? yes | no | unknown (fail-closed wallets)
    get "/outpoints/:txid/:vout", OutpointController, :show

    # UTXOs — outpoint ownership lookup (proxied to WhatsOnChain until local UTXO set exists)
    get "/utxo/:txid/:vout/owner", UtxoController, :owner

    # Transactions
    get "/txs/:txid/proof", ProofController, :show
    get "/txs/:txid/beef", ProofController, :beef
    get "/txs/:txid", TransactionController, :show
    get "/txs", TransactionController, :index

    # BEEF from anyone, checked against the headers we hold
    post "/beef/verify", BeefController, :verify

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

  # Cached and lightweight: price for other sites, support for the sponsorship
  # page (off-site), and the release and health a deploy is checked against.
  scope "/api/v1", BitblocksWeb.Api do
    pipe_through :open_api

    get "/status", StatusController, :show
    get "/price/bsv", PriceController, :show
    get "/support", SupportController, :show
  end

  # Open to all origins, for a caller with a key.
  scope "/api/v1", BitblocksWeb.Api do
    pipe_through :public_api

    get "/status/coverage", StatusController, :coverage
    get "/status/derivations", StatusController, :derivations

    # Transaction types (#49): definitions for other tools to link to.
    get "/types/:id", TypeController, :show
    get "/types", TypeController, :index
  end

  pipeline :raw_api do
    plug BitblocksWeb.Plugs.RequireCaller
  end

  # A tx's raw bytes, the CDN's origin (docs/TX_STORAGE.md). Not :api, which
  # only accepts json: this answers application/octet-stream.
  scope "/api/v1", BitblocksWeb.Api do
    pipe_through :raw_api

    get "/txs/:txid/raw", RawTxController, :show
  end

  # Own scope, no pipeline: the :browser pipeline only accepts html.
  scope "/", BitblocksWeb do
    get "/sitemap.xml", SitemapController, :index

    # Inscription bodies parsed from raw txs on the fly (1Sat /content convention).
    get "/content/:outpoint", ContentController, :show

    # A B:// file parsed from its tx the same way (#22).
    get "/b/:txid", ContentController, :b
    # A BCat file reassembled from its head tx (#15).
    get "/content/bcat/:txid", ContentController, :bcat
  end

  # The Bitcom registry export, at a stable top-level path.
  scope "/", BitblocksWeb.Api do
    pipe_through :open_api

    get "/bitcom.json", BitcomController, :index
  end

  # The interoperability vectors: static, cached and open, because a test kit
  # that needs our key isn't neutral (docs/INTEROP_KIT.md).
  scope "/", BitblocksWeb do
    pipe_through :open_api

    get "/interop/vectors/v1.json", InteropController, :vectors
  end

  # Own scope, no pipeline: :open_api only accepts json.
  scope "/", BitblocksWeb do
    get "/interop/vectors/LICENSE.txt", InteropController, :license
  end

  pipeline :metrics do
    plug :accepts, ["text"]
  end

  # Access model (BitblocksWeb.UserAuth): the explorer front is public;
  # block and transaction detail need a signed-in GitHub user; the operator
  # surface needs an admin, meaning a GitHub user whose row is marked admin
  # (Release.set_admin/2).
  #
  # The gate runs in EVERY env. Enforcement is a runtime toggle
  # (`config :bitblocks, :admin_auth, enabled: true|false`, default true):
  # test disables the gate in config/test.exs so existing tests can hit
  # /sync, /config, etc.
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
  # this gate reads only the signed session cookie and that user's row.
  pipeline :admin_data do
    plug :require_admin_data
  end

  # Admin JSON writes: the admin_data gate, plus JSON-only bodies as the
  # CSRF guard (BitblocksWeb.Plugs.RequireJsonBody).
  pipeline :admin_json do
    plug :accepts, ["json"]
    plug :require_admin_data
    plug BitblocksWeb.Plugs.RequireJsonBody
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

    get "/protocols", PageController, :protocols

    live_session :public,
      on_mount: [{UserAuth, :mount_current_user}] do
      live "/search", SearchLive

      # Builder onboarding (docs/DEMOS_CAMPAIGN.md).
      live "/start", StartLive.Index
      live "/start/api", StartLive.Api
      live "/start/guidance", StartLive.Guidance
      live "/start/interop", StartLive.Interop

      live "/bitcom", BitcomLive
      live "/bitcom/compose", BitcomComposeLive
      live "/bitcom/:address", BitcomLive
      live "/order-book", OrderBookLive
      live "/tokens", TokenLive
      live "/tokens/:id", TokenLive
      live "/metanet", MetanetLive
      live "/collections", CollectionLive.Index
      live "/collections/:id", CollectionLive.Show
      live "/types", TypeLive.Index
      live "/types/:id", TypeLive.Show
      live "/about", AboutLive
      live "/pricing", PricingLive
      live "/guide", GuideLive
      live "/reorgs", ReorgLive
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
    get "/", PageController, :home
  end

  # Declared before the signed-in scope so /transactions/new isn't captured by
  # /transactions/:id.
  scope "/", BitblocksWeb do
    # Operator surface: admins only (see the access model above).
    pipe_through :admin

    get "/config", PageController, :config
    get "/debug", PageController, :debug

    live_session :admin,
      on_mount: [{UserAuth, :require_admin}] do
      live "/admin", AdminLive

      live "/address_repo", AddressRepoLive
      live "/forks", ForkGraphLive
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
      live "/annotations", AnnotationLive

      # A browse list over the whole table; detail pages cover a shared link.
      live "/transactions", TransactionLive.Index, :index

      # Transaction mutation pages
      live "/transactions/new", TransactionLive.Index, :new
      live "/transactions/:id/edit", TransactionLive.Index, :edit
      live "/transactions/:id/show/edit", TransactionLive.Show, :edit
    end
  end

  scope "/", BitblocksWeb do
    # Operations pages: any signed-in GitHub user, or an admin.
    pipe_through [:browser, :signed_in]

    get "/status", PageController, :status
    get "/sync", PageController, :sync

    live_session :signed_in,
      on_mount: [{UserAuth, :require_user}] do
      live "/syncing", SyncingLive
    end
  end

  scope "/", BitblocksWeb do
    # Read-only detail, so a link someone was sent simply opens (#38). After the
    # admin scope, so /transactions/new matches first.
    pipe_through :browser

    live_session :public_detail,
      on_mount: [{UserAuth, :mount_current_user}] do
      live "/blocks/:id", BlockLive.Show, :show
      live "/transactions/:id", TransactionLive.Show, :show
    end
  end

  # Chain annotations (forks, upgrades, mintings, world events): admin CRUD.
  scope "/api/v1", BitblocksWeb.Api do
    pipe_through :admin_json

    resources "/annotations", AnnotationController, except: [:new, :edit]
  end

  scope "/chain-scrubber", BitblocksWeb do
    pipe_through :admin_data

    get "/tiles/manifest", ChainTileController, :manifest
    get "/tiles/:level/:idx", ChainTileController, :tile
    get "/flow", ChainFlowController, :show
  end

  scope "/" do
    # Metrics are operator data — always behind :admin (same enablement rules
    # as the scope above).
    pipe_through [:metrics, :admin]

    forward "/metrics", TelemetryMetricsPrometheus.Router, name: Bitblocks.TelemetryPrometheus
  end

  # Dev-only operator tools.
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
