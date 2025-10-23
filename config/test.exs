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
  pool_size: System.schedulers_online() * 2

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

# Bitcoin RPC configuration for tests
config :bitblocks,
  bitcoinsv_cli: BitcoinsvCliMock,
  bitcoin_url: System.get_env("BITCOIN_NODE_URL"),
  rpc_user: System.get_env("BITCOIN_NODE_RPC_USERNAME"),
  rpc_password: System.get_env("BITCOIN_NODE_RPC_PASSWORD"),
  rpc_url: System.get_env("BITCOIN_NODE_RPC_URL")

# Disable Oban queues in test (but keep the supervisor running)
config :bitblocks, Oban, testing: :manual, queues: false

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
