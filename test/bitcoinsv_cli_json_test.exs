defmodule BitcoinsvCliJsonTest do
  # The node's JSON-RPC bodies go through Jason (#65 dropped Poison): a
  # result decodes as before, and an empty body is a parse error, not a crash.
  use ExUnit.Case, async: false
  use ExVCR.Mock, adapter: ExVCR.Adapter.Finch

  import Bitblocks.DataCase, only: [setup_bitcoin_rpc: 0]

  setup do
    setup_bitcoin_rpc()
    :ok
  end

  test "decodes a result, floats included, then reports an empty body as a parse error" do
    use_cassette "bitcoinsv_cli/json_rpc", record: :none do
      assert %{"blocks" => 974_382, "difficulty" => difficulty, "chain" => "main"} =
               BitcoinsvCli.bitcoin_rpc("getblockchaininfo")

      assert is_float(difficulty)

      assert {:error, {:parse_error, :invalid_json}} =
               BitcoinsvCli.bitcoin_rpc("getblockchaininfo")
    end
  end
end
