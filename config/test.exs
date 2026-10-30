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
config :bitblocks, BitblocksWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
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

# Disable request auto-ban in tests — the Wallaby browser hits many endpoints
# from 127.0.0.1 and would otherwise get blocked by the RequestLogger.
config :bitblocks, :invalid_request_threshold, 10_000

# Bypass admin basic auth so LiveView/controller/accessibility tests can reach
# the operator surface (/sync, /config, …) unauthenticated. The gate itself is
# covered by test/bitblocks_web/admin_gate_test.exs, which re-enables it.
config :bitblocks, :admin_auth, enabled: false

# Raise the per-IP rate limit in tests. Many controller tests share the
# 127.0.0.1 source IP, so the production-tight 20/min limit would otherwise
# turn assertions into flaky 429s depending on test order.
config :bitblocks, BitblocksWeb.Plugs.RateLimiter, max_requests: 100_000

# Wallaby configuration
config :wallaby,
  otp_app: :bitblocks,
  base_url: "http://localhost:4002",
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
