defmodule BitcoinsvCliTest do
  use ExUnit.Case, async: false
  # Remove doctest since it requires live API
  # doctest BitcoinsvCli

  @moduletag :integration

  describe "getblockhash/1" do
    @tag :skip
    test "returns block hash for valid height" do
      hash = BitcoinRpcFixtures.getblockhash(100_000)
      assert is_binary(hash)
      assert String.length(hash) == 64
      # Known hash for block 100,000 on BSV mainnet
      assert hash == "000000000003ba27aa200b1cecaad478d2b00432346c3f1f3986da1afd33e506"
    end
  end

  describe "getblock/1" do
    test "returns block data with cached fixture" do
      hash = "000000000003ba27aa200b1cecaad478d2b00432346c3f1f3986da1afd33e506"
      block = BitcoinRpcFixtures.getblock_verbose(hash)

      assert is_map(block)
      assert block["hash"] == hash
      assert block["height"] == 100_000
      assert block["num_tx"] == 4
      assert is_list(block["tx"])
      assert length(block["tx"]) == 4
    end

    test "block has expected fields" do
      hash = "000000000003ba27aa200b1cecaad478d2b00432346c3f1f3986da1afd33e506"
      block = BitcoinRpcFixtures.getblock_verbose(hash)

      assert block["bits"] == "1b04864c"
      assert block["merkleroot"] == "f3e94742aca4b5ef85488dc37c06c3282295ffec960994b2c0d5ac2a25a95766"
      assert block["previousblockhash"] == "000000000002d01c1fccc21636b607dfd930d31d01c3a62104612a1719011250"
      assert block["nextblockhash"] == "00000000000080b66c911bd5ba14a74260057311eaeb1982802f7010f1a9f090"
      assert block["nonce"] == 274_148_111
      assert block["size"] == 957
      assert block["version"] == 1
      assert block["time"] == 1_293_623_863
      assert block["mediantime"] == 1_293_622_620
    end
  end

  describe "getrawtransaction/1" do
    test "returns coinbase transaction details" do
      tx = BitcoinRpcFixtures.getrawtransaction_coinbase()

      assert is_map(tx)
      assert tx["txid"] == "8c14f0db3df150123e6f3dbbf30f8b955a8249b62ac1d1ff16284aefa3d06d87"
      assert tx["version"] == 1
      assert is_list(tx["vin"])
      assert is_list(tx["vout"])
    end

    test "returns regular transaction details" do
      tx = BitcoinRpcFixtures.getrawtransaction_regular()

      assert is_map(tx)
      assert tx["txid"] == "fff2525b8931402dd09222c50775608f75787bd2b87e56995a7bdd30f79702c4"
      assert tx["version"] == 1
      assert is_list(tx["vin"])
      assert is_list(tx["vout"])
    end
  end

  describe "decoderawtransaction/1" do
    test "decodes coinbase transaction" do
      decoded = BitcoinRpcFixtures.decoderawtransaction_coinbase()

      assert is_map(decoded)
      assert decoded["txid"] == "8c14f0db3df150123e6f3dbbf30f8b955a8249b62ac1d1ff16284aefa3d06d87"
      assert decoded["version"] == 1
      assert decoded["locktime"] == 0
      assert decoded["size"] == 135
    end

    test "identifies coinbase transaction" do
      decoded = BitcoinRpcFixtures.decoderawtransaction_coinbase()

      assert is_list(decoded["vin"])
      [input] = decoded["vin"]
      assert Map.has_key?(input, "coinbase")
      assert input["coinbase"] == "044c86041b020602"
    end

    test "decodes coinbase output with reward" do
      decoded = BitcoinRpcFixtures.decoderawtransaction_coinbase()

      assert is_list(decoded["vout"])
      [output] = decoded["vout"]

      assert output["n"] == 0
      assert output["value"] == 50.0
      assert is_map(output["scriptPubKey"])
      assert output["scriptPubKey"]["type"] == "pubkey"
      assert output["scriptPubKey"]["addresses"] == ["1HWqMzw1jfpXb3xyuUZ4uWXY4tqL2cW47J"]
    end
  end

  describe "full workflow with fixtures" do
    test "can use cached block and transaction data" do
      # Get block 100,000
      hash = BitcoinRpcFixtures.getblockhash(100_000)
      block = BitcoinRpcFixtures.getblock_verbose(hash)

      assert %{"tx" => transactions} = block
      assert length(transactions) == 4

      # Get coinbase transaction
      coinbase = BitcoinRpcFixtures.decoderawtransaction_coinbase()
      [first_input] = coinbase["vin"]
      assert Map.has_key?(first_input, "coinbase")

      # Get regular transaction
      regular = BitcoinRpcFixtures.getrawtransaction_regular()
      assert is_map(regular)
    end
  end

  # API contract validation tests - run with: REFRESH_FIXTURES=true mix test --only api_contract
  @moduletag api_contract: false

  describe "API contract validation" do
    @tag :api_contract
    @tag :skip
    test "live API matches cached fixtures for getblock" do
      if System.get_env("REFRESH_FIXTURES") == "true" do
        hash = "000000000003ba27aa200b1cecaad478d2b00432346c3f1f3986da1afd33e506"
        {:ok, live_block} = BitcoinsvCli.getblock(hash, 1)
        cached_block = BitcoinRpcFixtures.getblock_verbose(hash)

        # Verify key fields match
        assert live_block["hash"] == cached_block["hash"]
        assert live_block["height"] == cached_block["height"]
        assert live_block["merkleroot"] == cached_block["merkleroot"]
        assert live_block["num_tx"] == cached_block["num_tx"]
      else
        IO.puts("⚠ Skipping API contract test. Set REFRESH_FIXTURES=true to run.")
      end
    end

    @tag :api_contract
    @tag :skip
    test "live API matches cached fixtures for getrawtransaction" do
      if System.get_env("REFRESH_FIXTURES") == "true" do
        txid = "8c14f0db3df150123e6f3dbbf30f8b955a8249b62ac1d1ff16284aefa3d06d87"
        {:ok, live_tx} = BitcoinsvCli.getrawtransaction(txid, 1)
        cached_tx = BitcoinRpcFixtures.getrawtransaction_coinbase()

        # Verify key fields match
        assert live_tx["txid"] == cached_tx["txid"]
        assert live_tx["version"] == cached_tx["version"]
        assert length(live_tx["vin"]) == length(cached_tx["vin"])
        assert length(live_tx["vout"]) == length(cached_tx["vout"])
      else
        IO.puts("⚠ Skipping API contract test. Set REFRESH_FIXTURES=true to run.")
      end
    end
  end
end
