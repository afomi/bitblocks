import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :bitblocks, Bitblocks.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "bitblocks_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# We don't run a server during test. If one is required,
# you can enable the server option below.
# TEST_PORT lets two suites run at once (qart's test server also takes 4002).
test_port = String.to_integer(System.get_env("TEST_PORT", "4002"))

config :bitblocks, BitblocksWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: test_port],
  secret_key_base: "5k/box4ZnbnVs2WVF1YUEGiNX+A6k0Wn26DvHH07BMMcTtyZX1E8wvAVBqkS79rX",
  server: true

# In test we don't send emails.
config :bitblocks, Bitblocks.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters.
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# ExVCR — record HTTP cassettes on first run, replay thereafter.
# Match on request body only so cassettes work regardless of which node URL is configured.
config :exvcr,
  vcr_cassette_library_dir: "test/fixtures/vcr_cassettes",
  custom_cassette_library_dir: "test/fixtures/vcr_cassettes",
  enable_global_settings: true,
  match_requests_on: [:request_body],
  filter_sensitive_data: [
    [
      pattern: System.get_env("BITCOIN_NODE_RPC_USERNAME") || "rpcuser",
      placeholder: "REDACTED_USER"
    ],
    [
      pattern: System.get_env("BITCOIN_NODE_RPC_PASSWORD") || "rpcpassword",
      placeholder: "REDACTED_PASS"
    ],
    # The node's address never goes in a recording: this repo is public.
    # Requests match on the body, so the host doesn't matter on replay.
    [
      pattern: ~S|https?://[^/\s"]+:8332|,
      placeholder: "http://bitcoin-node.invalid:8332"
    ]
  ]

# Disable ForkTracker polling in tests to avoid background RPC calls
config :bitblocks, fork_tracker_poll_interval: nil

# Route all Bitcoin RPC through the stub-backed mock (see test/support/RPC_TESTING.md).
# Unstubbed calls return {:error, {:no_stub, ...}} — the same shape as an
# unreachable node — so tests that don't stub keep their current behavior.
config :bitblocks, :bitcoinsv_cli, BitcoinsvCliMock

# Disable Oban queues in test (but keep the supervisor running)
config :bitblocks, Oban, testing: :manual, queues: false

# Projection webhooks post to a stub that messages the test process.
config :bitblocks, :projection_webhook_client, Bitblocks.WebhookClientStub

# WhatsOnChain fallback source answers from per-test fixtures.
config :bitblocks, :woc_client, Bitblocks.WocStub

# Raw tx bytes go to a local directory in tests (Bitblocks.TxStore).
config :bitblocks, Bitblocks.TxStore, adapter: Bitblocks.TxStore.Local, root: "tmp/tx_store_test"

# Chain-scrubber tiles: no boot-time warm (the sandbox owns the connection).
config :bitblocks, Bitblocks.ChainTiles, warm_on_boot: false

# Sync coordinator: no ticks or header sync in tests; tests call tick/1.
config :bitblocks, Bitblocks.Sync.Coordinator, auto: false, headers: false

# /syncing snapshot: no timers or boot load in tests; tests call refresh/0 and flush/0.
config :bitblocks, Bitblocks.SyncProgress, auto_refresh: false

# Rexxie catalog PNGs. Tests never read ~/workspace/rexxie-indexer/images.
config :bitblocks,
       :rexxie_images_dir,
       Path.expand("../tmp/rexxie_images_test", __DIR__)

# Disable request auto-ban in tests — the Wallaby browser hits many endpoints
# from 127.0.0.1 and would otherwise get blocked by the RequestLogger.
config :bitblocks, :invalid_request_threshold, 10_000

# Bypass the sign-in gates so LiveView/controller/accessibility tests can reach
# the operator surface (/sync, /config, …) unauthenticated. The gate itself is
# covered by test/bitblocks_web/admin_gate_test.exs, which re-enables it.
config :bitblocks, :admin_auth, enabled: false

# Raise the per-IP rate limit in tests. Many controller tests share the
# 127.0.0.1 source IP, so the production-tight 20/min limit would otherwise
# turn assertions into flaky 429s depending on test order.
config :bitblocks, BitblocksWeb.Plugs.RateLimiter, max_requests: 100_000

# Derived-data backfills (docs/DERIVED_DATA.md): no pause between pages.
config :bitblocks, :derivation_pause_ms, 0

# Tests refresh the /types counts themselves (Bitblocks.TxTypes.Counts.refresh/0).
config :bitblocks, :tx_type_counts_refresh, false

# Wallaby configuration
config :wallaby,
  otp_app: :bitblocks,
  base_url: "http://localhost:#{test_port}",
  driver: Wallaby.Chrome,
  chrome: [
    headless: System.get_env("HEADLESS", "true") == "true",
    capabilities: %{
      chromeOptions: %{
        args: [
          "--no-sandbox",
          "--disable-dev-shm-usage",
          "--disable-gpu",
          "--disable-software-rasterizer"
        ]
      }
    }
  ]
