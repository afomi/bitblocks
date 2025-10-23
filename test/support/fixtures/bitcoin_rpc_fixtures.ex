defmodule BitcoinRpcFixtures do
  @moduledoc """
  Provides cached Bitcoin RPC responses for testing.

  These fixtures are real responses from a Bitcoin SV node, cached to avoid
  hitting live APIs during tests. To refresh fixtures with latest API responses,
  set environment variable: REFRESH_FIXTURES=true

  ## Usage

      # In tests, use cached responses
      assert BitcoinRpcFixtures.getblockhash(100_000) == "000000000003ba27aa..."

      # To refresh all fixtures from live API:
      REFRESH_FIXTURES=true mix test
  """

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "bitcoin_rpc"])

  @doc """
  Get block hash for block 100,000 (a stable, well-known block)
  """
  def getblockhash(100_000) do
    "000000000003ba27aa200b1cecaad478d2b00432346c3f1f3986da1afd33e506"
  end

  @doc """
  Get block data for block 100,000 with verbosity 0 (raw hex)
  """
  def getblock_raw(hash)
      when hash == "000000000003ba27aa200b1cecaad478d2b00432346c3f1f3986da1afd33e506" do
    load_or_fetch("block_100000_raw.json", fn ->
      BitcoinsvCli.getblock(hash, 0)
    end)
  end

  @doc """
  Get block data for block 100,000 with verbosity 1 (with tx details)
  """
  def getblock_verbose(hash)
      when hash == "000000000003ba27aa200b1cecaad478d2b00432346c3f1f3986da1afd33e506" do
    load_or_fetch("block_100000_verbose.json", fn ->
      BitcoinsvCli.getblock(hash, 1)
    end)
  end

  @doc """
  Get coinbase transaction from block 100,000
  """
  def getrawtransaction_coinbase do
    load_or_fetch("tx_100000_coinbase.json", fn ->
      txid = "8c14f0db3df150123e6f3dbbf30f8b955a8249b62ac1d1ff16284aefa3d06d87"
      BitcoinsvCli.getrawtransaction(txid, 1)
    end)
  end

  @doc """
  Get a regular (non-coinbase) transaction from block 100,000
  """
  def getrawtransaction_regular do
    load_or_fetch("tx_100000_regular.json", fn ->
      txid = "fff2525b8931402dd09222c50775608f75787bd2b87e56995a7bdd30f79702c4"
      BitcoinsvCli.getrawtransaction(txid, 1)
    end)
  end

  @doc """
  Get decoded transaction (coinbase from block 100,000)
  """
  def decoderawtransaction_coinbase do
    %{
      "hash" => "8c14f0db3df150123e6f3dbbf30f8b955a8249b62ac1d1ff16284aefa3d06d87",
      "hex" =>
        "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff08044c86041b020602ffffffff0100f2052a010000004341041b0e8c2567c12536aa13357b79a073dc4444acb83c4ec7a0e2f99dd7457516c5817242da796924ca4e99947d087fedf9ce467cb9f7c6287078f801df276fdf84ac00000000",
      "locktime" => 0,
      "size" => 135,
      "txid" => "8c14f0db3df150123e6f3dbbf30f8b955a8249b62ac1d1ff16284aefa3d06d87",
      "version" => 1,
      "vin" => [%{"coinbase" => "044c86041b020602", "sequence" => 4_294_967_295}],
      "vout" => [
        %{
          "n" => 0,
          "scriptPubKey" => %{
            "addresses" => ["1HWqMzw1jfpXb3xyuUZ4uWXY4tqL2cW47J"],
            "asm" =>
              "041b0e8c2567c12536aa13357b79a073dc4444acb83c4ec7a0e2f99dd7457516c5817242da796924ca4e99947d087fedf9ce467cb9f7c6287078f801df276fdf84 OP_CHECKSIG",
            "hex" =>
              "41041b0e8c2567c12536aa13357b79a073dc4444acb83c4ec7a0e2f99dd7457516c5817242da796924ca4e99947d087fedf9ce467cb9f7c6287078f801df276fdf84ac",
            "reqSigs" => 1,
            "type" => "pubkey"
          },
          "value" => 50.0
        }
      ]
    }
  end

  # Private functions

  defp load_or_fetch(filename, fetch_fn) do
    filepath = Path.join(@fixtures_dir, filename)

    if should_refresh_fixtures?() do
      # Fetch from live API and cache
      result = fetch_fn.()

      case result do
        {:error, reason} ->
          IO.puts("⚠ Failed to fetch from API: #{inspect(reason)}")
          IO.puts("  Falling back to cached fixture if available...")
          load_cached_fixture(filepath, fetch_fn)

        data when is_map(data) or is_binary(data) ->
          cache_fixture(filepath, data)
          data
      end
    else
      # Load from cache
      load_cached_fixture(filepath, fetch_fn)
    end
  end

  defp should_refresh_fixtures? do
    System.get_env("REFRESH_FIXTURES") == "true"
  end

  defp cache_fixture(filepath, data) do
    File.mkdir_p!(Path.dirname(filepath))
    json = Jason.encode!(data, pretty: true)
    File.write!(filepath, json)
    IO.puts("✓ Cached fixture: #{Path.basename(filepath)}")
  end

  defp load_cached_fixture(filepath, fetch_fn) do
    if File.exists?(filepath) do
      filepath
      |> File.read!()
      |> Jason.decode!()
    else
      IO.puts("⚠ Fixture not found: #{Path.basename(filepath)}")
      IO.puts("  Attempting to fetch from API...")

      result = fetch_fn.()

      case result do
        {:error, reason} ->
          raise """
          Failed to load fixture and unable to fetch from API.

          Fixture: #{Path.basename(filepath)}
          Error: #{inspect(reason)}

          To generate fixtures, ensure your Bitcoin node is running and configured:
            export BITCOIN_NODE_URL=http://localhost:8332
            export BITCOIN_NODE_RPC_USERNAME=your_username
            export BITCOIN_NODE_RPC_PASSWORD=your_password

          Then run:
            REFRESH_FIXTURES=true mix test test/bitcoinsv_cli_test.exs --include integration
          """

        data when is_map(data) or is_binary(data) ->
          cache_fixture(filepath, data)
          data
      end
    end
  end
end
