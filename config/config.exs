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
  # Auto-bans lift after this many seconds.
  auto_ban_ttl_seconds: 900,
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

# S3, EC2 and instance-metadata calls go through Finch, not ExAws's default
# hackney, which we no longer ship (#65).
config :ex_aws, http_client: Bitblocks.HTTP.ExAwsClient

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
  # On SIGTERM (a deploy), give running jobs a minute to finish before the
  # node exits. .github/scripts/deploy.sh stops the container with a longer
  # timeout, so Docker doesn't SIGKILL inside this window.
  shutdown_grace_period: :timer.seconds(60),
  plugins: [
    Oban.Plugins.Pruner,
    # A job that outlives the grace period is left `executing` by its dead
    # node, and only Lifeline puts it back. 2026-11-04: a deploy mid-sync parked
    # two collection trace batches for the old 60 minutes. The longest real
    # batch seen ran over 13 minutes, so 30 keeps a margin.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       # Keeps Sync.Coordinator, which leads the sync (docs/SYNCING.md),
       # alive. Unique, so a tick while one is queued or running is a no-op.
       {"* * * * *", Bitblocks.Workers.SyncWorker},
       # Chain-scrubber tiles (#48): the incremental build is one index probe
       # when nothing changed, rebuilds only the tiles whose blocks moved
       # otherwise, and does nothing until a person has run a full build
       # (Release.build_chain_tiles/1). Never heavy work on deploy.
       {"*/5 * * * *", Bitblocks.Workers.ChainTilesWorker, args: %{"mode" => "incremental"}},
       # Health check: emails when the node is unreachable or the index stalls.
       {"*/5 * * * *", Bitblocks.Workers.OpsAlertWorker},
       # A new Bitcom registry snapshot, if the registry changed (#21).
       {"17 4 * * *", Bitblocks.Workers.BitcomSnapshotWorker}
     ]}
  ],
  queues: [
    default: 10,
    # The sync loop: the coordinator's keep-alive cron, and block jobs (one
    # block each, never two jobs on one block). Sync.Coordinator scales
    # sync_blocks to the chosen concurrency at runtime.
    sync: 1,
    sync_blocks: 1,
    # A completed block's older rows brought up to version (TxPipeline.CatchUp):
    # one at a time, so a block full of them never holds a sync slot.
    derived: 1,
    # Backfills run as a chain of jobs, one range at a time (BackfillChains).
    backfills: 1,
    # Projection webhook deliveries (#29 step 4); off the tx lanes so a slow
    # tenant endpoint never delays sync.
    webhooks: 5,
    # Collection syncs (#30): WhatsOnChain-paced, one job at a time.
    collections: 1,
    blocks: 3,
    # Chain-scrubber tile builds (#48): own lane so a full build never
    # contends with sync.
    chain_tiles: 1
  ]

# Blocks the sync loop works at once, cluster-wide, until an admin picks a
# number on /sync (persisted in sync_settings). Always clamped to
# Sync.concurrency_limit/0: CPU cores, pool_size minus :sync_pool_reserve
# (web requests, header sync, other queues) and :sync_rpc_limit (the node's
# RPC threads; bitcoind's default rpcthreads is 4).
config :bitblocks, :sync_workers, 1
config :bitblocks, :sync_pool_reserve, 5
config :bitblocks, :sync_rpc_limit, 4

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

# The admin gate on the operator surface (/sync, /config, /debug, /admin,
# /rpc_admin, /metrics, block/tx mutation pages, …): a GitHub user marked admin.
# Enforced in EVERY env by default; test bypasses it (config/test.exs).
config :bitblocks, :admin_auth, enabled: true

# GitHub sign-in (BitblocksWeb.AuthController). Ueberauth is run per request
# with runtime options, so no providers are listed here. The client id and
# secret come from GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET in
# config/runtime.exs; unset means the sign-in page says it isn't configured.
config :ueberauth, Ueberauth, base_path: "/auth"
config :ueberauth, Ueberauth.Strategy.Github.OAuth, client_id: nil, client_secret: nil

config :bitblocks, :github_oauth, []

# Sponsorship (Bitblocks.Support). The ask lives off-site (sponsor_url);
# bitblocks serves the live numbers at GET /api/v1/support for that page.
#   monthly_costs: [{"Bitcoin SV full node", 1000}, …]  # USD per month
#   sponsor_url: "https://…"  # footer "Sponsor" link; hidden while nil
#   bsv_address: "1…"  # donations; received total is read from the index
config :bitblocks, :support,
  monthly_costs: [{"Bitcoin SV full node and hosting", 1200}],
  sponsor_url: nil,
  bsv_address: "1Hs9u37fyWZNHKC9LCmup3m1TroNzKHGoT"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
