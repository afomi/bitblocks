# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :bitblocks,
  ecto_repos: [Bitblocks.Repo],
  # TODO,
  # TODO: visualize a request from a user's browser going through the elixir stack, depicting each call in the stack
  bitcoin_url:    System.get_env("BITCOIN_NODE_URL"),
  rpc_user:       System.get_env("BITCOIN_NODE_RPC_USERNAME"),
  rpc_password:   System.get_env("BITCOIN_NODE_RPC_PASSWORD"),
  rpc_url:        System.get_env("BITCOIN_NODE_RPC_URL")

# Configures the endpoint
config :bitblocks, BitblocksWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: BitblocksWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: Bitblocks.PubSub,
  live_view: [signing_salt: "LFeNAT9u"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :bitblocks, Bitblocks.Mailer, adapter: Swoosh.Adapters.Local

# Swoosh API client is needed for adapters other than SMTP.
config :swoosh, :api_client, false

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.14.29",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

config :tailwind, version: "3.4.0", default: [
  args: ~w(
    --config=tailwind.config.js
    --input=css/app.css
    --output=../priv/static/assets/app.css
  ),
  cd: Path.expand("../assets", __DIR__)
]
