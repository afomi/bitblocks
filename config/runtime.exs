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

# The node's RPC worker threads (bitcoind rpcthreads): a ceiling on how many
# blocks the sync works at once (Bitblocks.Sync.concurrency_limit/0).
# A read-only web node (#39): see Bitblocks.NodeRole. Unset is a writer.
config :bitblocks,
       :node_role,
       (case System.get_env("NODE_ROLE") do
          value when value in [nil, "", "writer"] -> :writer
          "reader" -> :reader
          value -> raise "NODE_ROLE must be writer or reader, got: #{value}"
        end)

case System.get_env("SYNC_STOP_AT_HEIGHT") do
  nil -> :ok
  "" -> :ok
  "none" -> config :bitblocks, :sync_stop_at_height, nil
  height -> config :bitblocks, :sync_stop_at_height, String.to_integer(height)
end

if limit = System.get_env("SYNC_RPC_LIMIT") do
  config :bitblocks, :sync_rpc_limit, String.to_integer(limit)
end

# The node's REST interface for raw blocks (Bitblocks.Chain.RawBlock); by
# default the host and port of BITCOIN_NODE_URL / BITCOIN_NODE_RPC_URL.
if rest_url = System.get_env("BITCOIN_NODE_REST_URL") do
  config :bitblocks, :rest_url, rest_url
end

# Completed blocks' bytes as one object each in the tx store
# (Bitblocks.TxStore.BlockObject). Unset: on only while the store is ready
# (AWS_S3_BUCKET_TXS set). "false" turns it off; "true" forces it on.
case System.get_env("STORE_BLOCK_OBJECTS") do
  "false" -> config :bitblocks, :store_block_objects, false
  "true" -> config :bitblocks, :store_block_objects, true
  _ -> :ok
end

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

# Header sync pacing for a rate-limited public endpoint (PublicNode answers
# bursts with 429 / -32005): headers per batch and a pause before each batch.
config :bitblocks,
  header_batch_size: parse_env_integer.(System.get_env("HEADER_BATCH_SIZE"), 500),
  header_batch_pause_ms: parse_env_integer.(System.get_env("HEADER_BATCH_PAUSE_MS"), 0)

# WhatsOnChain: historical txid lists and tx bodies while our node is down or
# pruned (Bitblocks.Woc). No key = free tier (~3 req/s). With WOC_API_KEY,
# WOC_RPS sets the pace for the plan (10, 20 or 40).
woc_api_key = System.get_env("WOC_API_KEY")

config :bitblocks, Bitblocks.Woc,
  api_key: woc_api_key,
  rps:
    if(woc_api_key in [nil, ""],
      do: nil,
      else: parse_env_integer.(System.get_env("WOC_RPS"), 10)
    )

# GitHub sign-in and the admin allowlist (BitblocksWeb.UserAuth).
# In prod these come from the AWS Secrets Manager secret `bitblocks/prod`,
# which .github/scripts/deploy.sh writes to /opt/bitblocks.env on every
# deploy. Test keeps the defaults from config/config.exs so a developer's
# shell can't change what the suite sees.
if config_env() != :test do
  config :ueberauth, Ueberauth.Strategy.Github.OAuth,
    client_id: System.get_env("GITHUB_CLIENT_ID"),
    client_secret: System.get_env("GITHUB_CLIENT_SECRET")
end

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

# --- Mining proxy (runtime-controlled) --------------------------------------
# Mining is OFF unless MINING_ENABLED=true. At launch, 100% of every block's
# reward goes to MINING_COINBASE_ADDRESS (single-output coinbase; hashers call
# /work without ?address). Driven by env so the payout address is never
# hardcoded and mining can be toggled without a code change.
#   MINING_ENABLED=true
#   MINING_COINBASE_ADDRESS=<your BSV payout address>
#   MINING_COINBASE_MESSAGE="mined via bitblocks"   # optional
# Note: poll_interval_ms and platform_share_pct are COMPILE-time (config.exs).
mining_enabled = System.get_env("MINING_ENABLED") in ~w(true 1)
mining_coinbase_address = System.get_env("MINING_COINBASE_ADDRESS")

if mining_enabled and is_nil(mining_coinbase_address) do
  raise "MINING_ENABLED=true but MINING_COINBASE_ADDRESS is unset — refusing to mine to an unspendable coinbase."
end

config :bitblocks, Bitblocks.MiningProxy,
  enabled: mining_enabled,
  coinbase_address: mining_coinbase_address,
  coinbase_message: System.get_env("MINING_COINBASE_MESSAGE", "mined via bitblocks")

if config_env() == :prod do
  # Catalog PNGs for /images/rexxies. Unset keeps priv/rexxie_images in the release.
  # On-chain Rexxie payloads are encrypted, so this directory is the image source.
  if rexxie_images_dir = System.get_env("REXXIE_IMAGES_DIR") do
    config :bitblocks, :rexxie_images_dir, rexxie_images_dir
  end

  # Requests per minute by caller: logged out per IP, logged in and admin per
  # user. API keys carry their own (Release.create_api_key/2); see
  # BitblocksWeb.Plugs.RateLimiter.
  config :bitblocks, BitblocksWeb.Plugs.RateLimiter,
    max_requests: String.to_integer(System.get_env("RATE_LIMIT_PER_MINUTE", "30")),
    signed_in_max_requests:
      String.to_integer(System.get_env("RATE_LIMIT_SIGNED_IN_PER_MINUTE", "600")),
    admin_max_requests: String.to_integer(System.get_env("RATE_LIMIT_ADMIN_PER_MINUTE", "3000"))

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  db_hostname =
    database_url
    |> URI.parse()
    |> Map.get(:host)
    |> to_charlist()

  config :bitblocks, Bitblocks.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6,
    ssl:
      if(System.get_env("DATABASE_SSL", "true") != "false",
        do: [
          verify: :verify_peer,
          cacertfile: Application.app_dir(:bitblocks, "priv/ssl/aws-rds-ca.pem"),
          server_name_indication: db_hostname
        ],
        else: false
      ),
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

  # Erlang clustering across the prod instances, so PubSub reaches both and the
  # rate limiter and SSE limiter share their counts. Peers are found by EC2 tag
  # (Bitblocks.Cluster.EC2Tags). Unset, empty or "off" leaves each instance on
  # its own, which is the rollback switch.
  cluster_tag = System.get_env("CLUSTER_EC2_TAG", "")

  if cluster_tag not in ["", "off"] do
    config :libcluster,
      topologies: [
        ec2: [
          strategy: Bitblocks.Cluster.EC2Tags,
          config: [
            tag_name: "Name",
            tag_value: cluster_tag,
            region: System.get_env("CLUSTER_EC2_REGION", "us-east-1"),
            polling_interval: 5_000
          ]
        ]
      ]
  end

  # The GitHub OAuth app's callback URL is https://<PHX_HOST>/auth/github/callback.
  # Sign-in started on any other host (www.) moves to PHX_HOST first, because
  # session and OAuth state cookies are per host.
  config :bitblocks, :github_oauth,
    callback_url: "https://#{host}/auth/github/callback",
    canonical_host: host

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
      "https://www.bitblocks.app"
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

  # Mailer: AWS SES via the EC2 instance role (no static credentials).
  # ses:SendEmail is granted scoped to From: *@bitblocks.app.
  # MAILER_FROM and SES_REGION are set in the bitblocks/prod secret store.
  config :bitblocks, Bitblocks.Mailer,
    adapter: Swoosh.Adapters.AmazonSES,
    region: System.get_env("SES_REGION", "us-east-1")

  # Mail goes through the app's shared Finch pool; hackney isn't shipped (#65).
  config :swoosh, :api_client, Swoosh.ApiClient.Finch
  config :swoosh, :finch_name, Bitblocks.Finch
end
