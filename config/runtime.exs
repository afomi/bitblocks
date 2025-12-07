import Config

# Helper for parsing integer environment variables with fallback defaults.
parse_env_integer = fn value, default ->
  case value do
    nil ->
      default

    value ->
      case Integer.parse(value) do
        {int, ""} -> int
        _ -> default
      end
  end
end

# Load Bitcoin node connection details at runtime so release builds
# pick up secrets provided via the environment (e.g. Fly.io secrets).
bitcoin_url = System.get_env("BITCOIN_NODE_URL")
rpc_user = System.get_env("BITCOIN_NODE_RPC_USERNAME")
rpc_password = System.get_env("BITCOIN_NODE_RPC_PASSWORD")
rpc_url = System.get_env("BITCOIN_NODE_RPC_URL") || bitcoin_url
rpc_timeout_ms = parse_env_integer.(System.get_env("BITCOIN_RPC_TIMEOUT_MS"), 60_000)

rpc_recv_timeout_ms =
  parse_env_integer.(System.get_env("BITCOIN_RPC_RECV_TIMEOUT_MS"), rpc_timeout_ms)

rpc_batch_timeout_ms =
  parse_env_integer.(System.get_env("BITCOIN_RPC_BATCH_TIMEOUT_MS"), rpc_recv_timeout_ms)

slow_rpc_threshold_ms = parse_env_integer.(System.get_env("SLOW_RPC_LOG_THRESHOLD_MS"), 30_000)
fetcher_concurrency = parse_env_integer.(System.get_env("SYNC_CONCURRENCY"), 8)

config :bitblocks,
  bitcoin_url: bitcoin_url,
  rpc_user: rpc_user,
  rpc_password: rpc_password,
  rpc_url: rpc_url,
  # Allow overriding concurrency via env var (useful for memory-constrained environments)
  transaction_fetcher_concurrency: fetcher_concurrency,
  bitcoin_rpc_timeout_ms: rpc_timeout_ms,
  bitcoin_rpc_recv_timeout_ms: rpc_recv_timeout_ms,
  bitcoin_rpc_batch_timeout_ms: rpc_batch_timeout_ms,
  slow_rpc_log_threshold_ms: slow_rpc_threshold_ms

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/bitblocks start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :bitblocks, BitblocksWeb.Endpoint, server: true
end

# Bitcoin network configuration (can be overridden with BSV_NETWORK env var)
bitblocks_network =
  System.get_env("BSV_NETWORK", "test")
  |> String.downcase()
  |> case do
    "main" ->
      :main

    "test" ->
      :test

    other ->
      raise ArgumentError,
            "Invalid BSV_NETWORK value #{inspect(other)}. Expected one of: main, test."
  end

config :bitblocks, :bitcoin_network, bitblocks_network

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :bitblocks, Bitblocks.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6,
    # Increase timeout for large tables (default is 15s)
    timeout: 60_000,
    queue_target: 5_000,
    queue_interval: 1_000

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "bitblocks.app"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :bitblocks, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :bitblocks, BitblocksWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Bind on all IPv4 interfaces for Fly.io compatibility
      # Fly.io requires binding to 0.0.0.0 (IPv4) on port 8080
      ip: {0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    check_origin: [
      "https://bitblocks.app",
      "https://www.bitblocks.app",
      "https://bitblocks.fly.dev"
    ]

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :bitblocks, BitblocksWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :bitblocks, BitblocksWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :bitblocks, Bitblocks.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Hackney
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
