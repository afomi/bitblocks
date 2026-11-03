defmodule Bitblocks.Chain.TxSourcesTest do
  use Bitblocks.DataCase, async: false

  import Bitblocks.ChainFixtures

  alias Bitblocks.Chain.{TxidSource, TxSources}
  alias BitblocksWeb.RpcStub

  # Real mainnet block 170: externally verifiable txid/merkleroot pair.
  @block170_root "7dac2c5666815c17a3b36427de37bb9d2e2c5ccec3f8633eb91a4205cb4c10ff"
  @block170_txids [
    "b1fea52486ce0c62bb442b530a3f0132b826c74e473d1f2c220bfa78111c5082",
    "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16"
  ]

  # What a pruned SV Node (PublicNode) answers for an old block.
  @pruned %{"code" => -1, "message" => "Block file abc not available."}

  setup do
    RpcStub.setup()
    RpcStub.clear()
    :ok
  end

  describe "BitcoinsvCli error classification" do
    test "pruned-node answers are 'not available here', not failures" do
      assert BitcoinsvCli.not_available?(@pruned)
      assert BitcoinsvCli.not_available?(%{"code" => -5, "message" => "No such mempool tx"})

      refute BitcoinsvCli.not_available?(%{
               "code" => -8,
               "message" => "Block height out of range"
             })

      refute BitcoinsvCli.not_available?({:connection_error, :econnrefused})
    end

    test "PublicNode's -32005 and HTTP 429 are rate limits" do
      assert BitcoinsvCli.rate_limited?(%{"code" => -32005, "message" => "Rate limit exceeded"})
      assert BitcoinsvCli.rate_limited?(:rate_limited)
      refute BitcoinsvCli.rate_limited?(@pruned)
    end
  end

  describe "public no-auth endpoint" do
    setup do
      saved =
        for k <- [:rpc_url, :bitcoin_url, :rpc_user, :rpc_password],
            do: {k, Application.get_env(:bitblocks, k)}

      on_exit(fn ->
        for {k, v} <- saved,
            do:
              if(v,
                do: Application.put_env(:bitblocks, k, v),
                else: Application.delete_env(:bitblocks, k)
              )
      end)
    end

    test "blank credentials send no Authorization header" do
      Application.put_env(:bitblocks, :rpc_user, "")
      Application.put_env(:bitblocks, :rpc_password, "")
      refute List.keymember?(BitcoinsvCli.headers(), "Authorization", 0)

      Application.put_env(:bitblocks, :rpc_user, "u")
      Application.put_env(:bitblocks, :rpc_password, "p")
      assert List.keymember?(BitcoinsvCli.headers(), "Authorization", 0)
    end

    test "BITCOIN_NODE_RPC_URL wins over BITCOIN_NODE_URL" do
      Application.put_env(:bitblocks, :bitcoin_url, "http://own-node:8332")
      Application.put_env(:bitblocks, :rpc_url, "https://bsv-rpc.publicnode.com")
      assert Bitblocks.Config.bitcoin_url() == "https://bsv-rpc.publicnode.com"

      Application.put_env(:bitblocks, :rpc_url, "")
      assert Bitblocks.Config.bitcoin_url() == "http://own-node:8332"
    end
  end

  describe "TxidSource falls back to WhatsOnChain below the prune window" do
    test "a pruned block's txid list comes from WoC and is merkleroot-verified" do
      block = block_fixture(%{num_tx: 2, tx: [], merkleroot: @block170_root})
      RpcStub.stub_getblock(block.hash, 1, {:error, @pruned})
      Process.put(:woc_block_txids, %{block.hash => @block170_txids})

      assert {:ok, @block170_txids, healed} = TxidSource.txids(block)
      assert healed.tx == @block170_txids
    end

    test "a third-party list that doesn't rebuild the merkleroot fails closed" do
      block = block_fixture(%{num_tx: 2, tx: [], merkleroot: @block170_root})
      RpcStub.stub_getblock(block.hash, 1, {:error, @pruned})
      Process.put(:woc_block_txids, %{block.hash => Enum.reverse(@block170_txids)})

      assert {:error, {:merkleroot_verification_failed, :merkleroot_mismatch}} =
               TxidSource.txids(block)

      assert Repo.reload!(block).tx == []
    end

    test "a third-party list is refused when the header has no merkleroot to check it against" do
      block = block_fixture(%{num_tx: 2, tx: [], merkleroot: nil})
      RpcStub.stub_getblock(block.hash, 1, {:error, @pruned})
      Process.put(:woc_block_txids, %{block.hash => @block170_txids})

      assert {:error, :unverifiable_fallback_txids} = TxidSource.txids(block)
    end

    test "when both sources are rate limited the error says so" do
      block = block_fixture(%{num_tx: 2, tx: [], merkleroot: @block170_root})
      RpcStub.stub_getblock(block.hash, 1, {:error, :rate_limited})
      Process.put(:woc_block_txids, %{block.hash => {:error, {:http_status, 429, "slow down"}}})

      assert {:error, :rate_limited} = TxidSource.txids(block)
    end
  end

  describe "fetch_raw/2" do
    test "txs the node can't serve are fetched from WoC; node results are kept" do
      block = block_fixture(%{})
      RpcStub.stub_getrawtransaction("a", 1, %{"txid" => "a", "hex" => "00"})
      RpcStub.stub_getrawtransaction("b", 1, {:error, %{"code" => -5, "message" => "No such tx"}})
      Process.put(:woc_txs, %{"b" => %{"txid" => "b", "hex" => "01"}})

      results = TxSources.fetch_raw(["a", "b", "c"], block)

      assert results["a"]["hex"] == "00"
      assert results["b"]["hex"] == "01"
      assert {:error, _} = results["c"]
    end

    test "a failed node batch falls back to WoC for every txid" do
      block = block_fixture(%{})
      Process.put(:woc_txs, %{"a" => %{"txid" => "a", "hex" => "00"}})

      assert %{"a" => %{"hex" => "00"}} = TxSources.fetch_raw(["a"], block)
    end

    test "a WoC rate limit surfaces as :rate_limited on the missing txids" do
      block = block_fixture(%{})
      Process.put(:woc_txs_error, {:http_status, 429, "slow down"})

      assert %{"a" => {:error, :rate_limited}} = TxSources.fetch_raw(["a"], block)
    end
  end
end
