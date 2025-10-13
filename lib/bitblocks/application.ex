defmodule Bitblocks.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Ensure Hackney pool is started for HTTPoison
    :hackney_pool.start_pool(:default, [timeout: 150_000, max_connections: 100])

    children = [
      BitblocksWeb.Telemetry,
      Bitblocks.Repo,
      {DNSCluster, query: Application.get_env(:bitblocks, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Bitblocks.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Bitblocks.Finch},
      # Start Oban for background job processing
      {Oban, Application.fetch_env!(:bitblocks, Oban)},
      # Start Txbox for outbound transaction management
      # Note: Txbox requires additional configuration for mAPI miner integration
      # See config/runtime.exs for mAPI token configuration
      {Txbox, []},
      # Start sync worker for historical blockchain sync (legacy)
      Bitblocks.SyncWorker,
      # Start sync pipeline for parallel blockchain sync (new)
      Bitblocks.Sync.Pipeline,
      # Start block monitor for real-time new block detection
      Bitblocks.BlockMonitor,
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
