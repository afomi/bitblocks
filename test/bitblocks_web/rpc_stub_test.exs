defmodule BitblocksWeb.RpcStubTest do
  use ExUnit.Case, async: true
  alias BitblocksWeb.RpcStub

  setup do
    # Clean up any existing stub state
    RpcStub.stop()
    # Set up fresh stubs for this test
    RpcStub.setup()

    on_exit(fn ->
      RpcStub.stop()
    end)

    :ok
  end

  describe "RpcStub.setup/0" do
    test "initializes default stubs" do
      # Should have blockchain info stub
      info = RpcStub.get_stub(:getblockchaininfo)
      assert is_map(info)
      assert info["chain"] == "main"
      assert is_number(info["blocks"])
    end

    test "stubs common block hashes" do
      # Genesis block
      hash_0 = RpcStub.get_stub({:getblockhash, 0})
      assert hash_0 == "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"

      # Block 100
      hash_100 = RpcStub.get_stub({:getblockhash, 100})
      assert hash_100 == "000000007bc154e0fa7ea32218a72fe2c1bb9f86cf8c9ebf9a715ed27fdb229a"
    end
  end

  describe "stub_getblockchaininfo/1" do
    test "sets custom blockchain info" do
      custom_info = %{
        "chain" => "test",
        "blocks" => 12345,
        "headers" => 12345
      }

      RpcStub.stub_getblockchaininfo(custom_info)
      assert RpcStub.get_stub(:getblockchaininfo) == custom_info
    end

    test "uses fixture when no custom data provided" do
      RpcStub.clear()
      RpcStub.stub_getblockchaininfo()

      info = RpcStub.get_stub(:getblockchaininfo)
      assert is_map(info)
      assert Map.has_key?(info, "chain")
    end
  end

  describe "stub_getblockhash/2" do
    test "sets custom block hash for a height" do
      custom_hash = "0000000000000000000000000000000000000000000000000000000000000abc"
      RpcStub.stub_getblockhash(999, custom_hash)

      assert RpcStub.get_stub({:getblockhash, 999}) == custom_hash
    end

    test "generates deterministic hash when none provided" do
      RpcStub.stub_getblockhash(5000)
      hash = RpcStub.get_stub({:getblockhash, 5000})

      assert is_binary(hash)
      assert String.length(hash) == 64
    end
  end

  describe "stub_getblock/3" do
    test "sets custom block data" do
      hash = "0000000000000000000000000000000000000000000000000000000000000abc"

      custom_block = %{
        "hash" => hash,
        "height" => 500,
        "tx" => ["tx1", "tx2", "tx3"]
      }

      RpcStub.stub_getblock(hash, 1, custom_block)
      assert RpcStub.get_stub({:getblock, hash, 1}) == custom_block
    end

    test "uses fixture when no custom data provided" do
      hash = "test_hash"
      RpcStub.stub_getblock(hash)

      block = RpcStub.get_stub({:getblock, hash, 1})
      assert is_map(block)
    end
  end

  describe "stub_getrawtransaction/3" do
    test "sets custom transaction data" do
      txid = "abc123"

      custom_tx = %{
        "txid" => txid,
        "vin" => [],
        "vout" => [%{"value" => 50.0}]
      }

      RpcStub.stub_getrawtransaction(txid, 1, custom_tx)
      assert RpcStub.get_stub({:getrawtransaction, txid, 1}) == custom_tx
    end
  end

  describe "stub_batch_getblockhash/2" do
    test "sets batch response for multiple heights" do
      heights = [1, 2, 3]
      hashes = ["hash1", "hash2", "hash3"]

      RpcStub.stub_batch_getblockhash(heights, hashes)

      result = RpcStub.get_stub({:batch_getblockhash, heights})
      assert {:ok, response} = result
      assert response == %{1 => "hash1", 2 => "hash2", 3 => "hash3"}
    end

    test "generates hashes when none provided" do
      heights = [10, 20, 30]
      RpcStub.stub_batch_getblockhash(heights)

      result = RpcStub.get_stub({:batch_getblockhash, heights})
      assert {:ok, response} = result
      assert is_map(response)
      assert Map.has_key?(response, 10)
      assert Map.has_key?(response, 20)
      assert Map.has_key?(response, 30)
    end
  end

  describe "clear/0" do
    test "removes all stubs" do
      RpcStub.stub_getblockhash(42, "custom_hash")
      assert RpcStub.get_stub({:getblockhash, 42}) == "custom_hash"

      RpcStub.clear()
      assert RpcStub.get_stub({:getblockhash, 42}) == nil
    end
  end
end
