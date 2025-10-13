defmodule Mix.Tasks.Test.RefreshFixtures do
  @moduledoc """
  Refresh Bitcoin RPC test fixtures from a live Bitcoin SV node.

  ## Usage

      mix test.refresh_fixtures

  This task will:
  1. Connect to your configured Bitcoin SV node
  2. Fetch fresh responses for block 100,000 and its transactions
  3. Cache the responses as JSON fixtures in test/fixtures/bitcoin_rpc/

  ## Requirements

  - Bitcoin SV node must be running and accessible
  - BITCOIN_NODE_URL must be configured
  - RPC credentials must be set

  ## Configuration

  Set environment variables:

      export BITCOIN_NODE_URL=http://localhost:8332
      export BITCOIN_NODE_RPC_USERNAME=your_username
      export BITCOIN_NODE_RPC_PASSWORD=your_password

  Then run:

      mix test.refresh_fixtures
  """

  use Mix.Task

  @shortdoc "Refresh Bitcoin RPC test fixtures from live API"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    IO.puts("\n🔄 Refreshing Bitcoin RPC fixtures...\n")

    # Set environment variable to trigger fixture refresh
    System.put_env("REFRESH_FIXTURES", "true")

    # Run the integration tests which will fetch and cache fixtures
    Mix.Task.run("test", ["test/bitcoinsv_cli_test.exs", "--include", "integration"])

    IO.puts("\n✅ Fixtures refreshed successfully!")
    IO.puts("📁 Fixtures saved to: test/fixtures/bitcoin_rpc/\n")
  end
end
