defmodule Bitblocks.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Ensure Hackney pool is started for HTTPoison
    :hackney_pool.start_pool(:default, timeout: 150_000, max_connections: 100)

    # Initialize IP blocker and request tracking ETS tables
    BitblocksWeb.Plugs.IpBlocker.start_link()
    BitblocksWeb.Plugs.RequestLogger.start_link()
    Bitblocks.TelemetryHandlers.attach()

    # Clean up stale sync jobs from previous runs
    # This is done before starting children to ensure database is ready
    Task.start(fn ->
      # Wait a bit for Repo to be ready
      Process.sleep(1000)
      Bitblocks.Chain.cleanup_stale_sync_jobs()
    end)

    children = [
      BitblocksWeb.Telemetry,
      {TelemetryMetricsPrometheus.Core,
       name: Bitblocks.TelemetryPrometheus, metrics: BitblocksWeb.Telemetry.prometheus_metrics()},
      Bitblocks.Repo,
      {DNSCluster, query: Application.get_env(:bitblocks, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Bitblocks.PubSub},
      # Monitor memory usage and warn when approaching limits
      Bitblocks.MemoryMonitor,
      # Track competing chain tips and fork metadata
      Bitblocks.ForkTracker,
      # Playground for event-driven LiveView experiments
      Bitblocks.EventPlayground,
      # Start RPC cache for caching blockchain info calls
      Bitblocks.RpcCache,
      # Cache database stats (counts) to avoid slow COUNT(*) queries
      Bitblocks.StatsCache,
      # Start the Finch HTTP client for sending emails
      {Finch, name: Bitblocks.Finch},
      # Start Oban for background job processing
      {Oban, Application.fetch_env!(:bitblocks, Oban)},
      # Start Txbox for outbound transaction management
      # Note: Txbox requires additional configuration for mAPI miner integration
      # See config/runtime.exs for mAPI token configuration
      {Txbox, []},
      # Mining proxy — serves block templates to remote hashers
      Bitblocks.MiningProxy,
      # Generic collections registry
      Bitblocks.Collections,
      # Rexxie NFT collection
      Bitblocks.Rexxies,
      # Start to serve requests, typically the last entry
      BitblocksWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bitblocks.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BitblocksWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
