defmodule Bitblocks.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Ecto repository
      Bitblocks.Repo,
      # Start the Telemetry supervisor
      BitblocksWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: Bitblocks.PubSub},
      # Start the Endpoint (http/https)
      BitblocksWeb.Endpoint
      # Start a worker by calling: Bitblocks.Worker.start_link(arg)
      # {Bitblocks.Worker, arg}
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
