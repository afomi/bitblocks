# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :bitblocks,
  env: config_env(),
  ecto_repos: [Bitblocks.Repo],
  generators: [timestamp_type: :utc_datetime],
  bitcoin_url: System.get_env("BITCOIN_NODE_URL"),
  rpc_user: System.get_env("BITCOIN_NODE_RPC_USERNAME"),
  rpc_password: System.get_env("BITCOIN_NODE_RPC_PASSWORD"),
  rpc_url: System.get_env("BITCOIN_NODE_RPC_URL"),
  # Sync pipeline configuration
  # Number of parallel transaction fetchers
  # Higher values help with remote node latency
  # Note: For 1GB RAM, use 5-8. For 2GB+, can use 10-15
  transaction_fetcher_concurrency: 8,
  # Whether to fetch full tx details (heavy)
  fetch_full_transactions: false,
  # Limit tx fetching per block
  max_transactions_per_block: 1000,
  # Default RPC timeouts (overridden via env in runtime config)
  bitcoin_rpc_timeout_ms: 60_000,
  bitcoin_rpc_recv_timeout_ms: 60_000,
  bitcoin_rpc_batch_timeout_ms: 60_000,
  # Log threshold for slow RPC calls (milliseconds)
  slow_rpc_log_threshold_ms: 30_000,
  # Auto-ban configuration
  # Enable automatic IP banning for abusive requests
  auto_ban_enabled: true,
  # Number of invalid requests before auto-ban (404s, 400s, suspicious patterns)
  invalid_request_threshold: 10,
  # Time window for tracking invalid requests (seconds)
  tracking_window_seconds: 300,
  # Approximate location of OUR node, shown as the home marker on /peers.
  # The node is static, so this is a fixed, city-level point rather than a
  # runtime geo-IP lookup.
  node_location: %{
    lat: 37.77,
    lon: -122.42,
    city: "San Francisco",
    country: "United States"
  }

# Configure Txbox
config :txbox,
  repo: Bitblocks.Repo

# Configures the endpoint
config :bitblocks, BitblocksWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BitblocksWeb.ErrorHTML, json: BitblocksWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Bitblocks.PubSub,
  live_view: [signing_salt: "Q5YK8k16"]

# Bounds concurrent Server-Sent Events connections (THREAT-MODEL.md T2).
# SSE handlers hold a process open indefinitely; without a cap a client can
# exhaust acceptors/sockets/memory. Tune max_per_ip up for trusted internal use.
config :bitblocks, BitblocksWeb.SseLimiter,
  max_global: 500,
  max_per_ip: 5

# Hard ceiling on a single SSE connection's lifetime (THREAT-MODEL.md T2). The
# stream sends an `event: reconnect` and closes past this, so slots churn and an
# abandoned connection can't camp one forever. Clients (EventSource) reconnect.
config :bitblocks, BitblocksWeb.Api.StreamController, max_lifetime_ms: 30 * 60_000

# Upper bound on the hex length SafeTx will hand to the (untrusted) tx decoder
# before rejecting it (THREAT-MODEL.md T3/T5, CWE-770). 100 MB of hex covers any
# realistic single transaction with margin.
config :bitblocks, Bitblocks.Chain.SafeTx, max_hex_bytes: 100_000_000

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :bitblocks, Bitblocks.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  bitblocks: [
    args:
      ~w(js/app.js js/wall.js js/reward_wall.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.0",
  bitblocks: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure Oban for background job processing
config :bitblocks, Oban,
  repo: Bitblocks.Repo,
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Bitblocks.Workers.SyncHeadersWorker, args: %{"mode" => "tip"}},
       # Hourly self-healing backfill: exits immediately when nothing is
       # incomplete; otherwise resumes the sequential diff-and-fill from the
       # lowest incomplete block. This is what guarantees range-synced headers
       # (which don't auto-enqueue tx fetches) eventually get their
       # transactions even if a manual backfill run is interrupted.
       # Active-states uniqueness on the worker prevents pileup.
       {"0 * * * *", Bitblocks.Workers.BackfillTransactionsWorker}
     ]}
  ],
  queues: [
    default: 10,
    # Tip and backfill tx fetching run as separate concurrency-1 lanes so they
    # never share slots — one current + one past block fetch in parallel.
    transactions_tip: 1,
    transactions_backfill: 1,
    # Projection webhook deliveries (#29 step 4); off the tx lanes so a slow
    # tenant endpoint never delays sync.
    webhooks: 5,
    blocks: 3
  ]

# Mining proxy — COMPILE-TIME settings only (read via Application.compile_env in
# Bitblocks.MiningProxy). Runtime-toggled keys (enabled, coinbase_address,
# coinbase_message) are set from env in config/runtime.exs.
#   poll_interval_ms: how often to refresh the block template from the node.
#     10s is plenty: the chain tip moves every ~10+ min, so polling faster buys
#     nothing and just adds RPC load on the live node.
#   platform_share_pct: only used by the (currently dormant) hasher reward-split
#     path; ignored at launch (no-address => 100% to coinbase_address).
config :bitblocks, Bitblocks.MiningProxy,
  poll_interval_ms: 10_000,
  platform_share_pct: 10

# Admin basic auth on the operator surface (/sync, /config, /debug, /admin,
# /rpc_admin, /metrics, block/tx mutation pages, …). Enforced in EVERY env by
# default; test bypasses it (config/test.exs). Credentials come from
# ADMIN_USERNAME/ADMIN_PASSWORD (see BitblocksWeb.AdminAuth — prod fails
# closed on the defaults, dev logs a warning).
config :bitblocks, :admin_auth, enabled: true

# Sponsorship (Bitblocks.Support). The ask lives off-site (sponsor_url);
# bitblocks serves the live numbers at GET /api/v1/support for that page.
#   monthly_costs: [{"Bitcoin SV full node", 1000}, …]  # USD per month
#   sponsor_url: "https://…"  # footer "Sponsor" link; hidden while nil
#   bsv_address: "1…"  # donations; received total is read from the index
config :bitblocks, :support,
  monthly_costs: [{"Bitcoin SV full node", 1000}],
  sponsor_url: nil,
  bsv_address: nil

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
