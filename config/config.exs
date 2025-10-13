# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :bitblocks,
  ecto_repos: [Bitblocks.Repo],
  generators: [timestamp_type: :utc_datetime],
  bitcoin_url: System.get_env("BITCOIN_NODE_URL"),
  rpc_user: System.get_env("BITCOIN_NODE_RPC_USERNAME"),
  rpc_password: System.get_env("BITCOIN_NODE_RPC_PASSWORD"),
  rpc_url: System.get_env("BITCOIN_NODE_RPC_URL"),
  # Sync pipeline configuration
  # Number of parallel transaction fetchers
  transaction_fetcher_concurrency: 5,
  # Whether to fetch full tx details (heavy)
  fetch_full_transactions: false,
  # Limit tx fetching per block
  max_transactions_per_block: 1000

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
      ~w(js/app.js js/wall.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
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
       # Add cron jobs here if needed
     ]}
  ],
  queues: [
    default: 10,
    transactions: 5,
    blocks: 3
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
