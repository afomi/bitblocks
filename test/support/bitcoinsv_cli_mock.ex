defmodule BitcoinsvCliMock do
  @moduledoc """
  Mock implementation of BitcoinsvCli that returns stubbed responses from fixtures.

  This is used in tests to avoid requiring a live Bitcoin node.

  ## Usage

  In your test config (config/test.exs), you can configure the application to use this mock:

      config :bitblocks, :bitcoinsv_cli, BitcoinsvCliMock

  Or use it directly in individual tests by calling its functions.
  """

  alias BitblocksWeb.RpcStub

  @doc """
  Mock implementation of getblockchaininfo.

  Returns stubbed response from RpcStub or a default response.
  """
  def getblockchaininfo do
    case RpcStub.get_stub(:getblockchaininfo) do
      nil ->
        # Return a default response if no stub is set
        %{
          "chain" => "main",
          "blocks" => 850_000,
          "headers" => 850_000,
          "bestblockhash" => "00000000000000000123456789abcdef00000000000000000123456789abcdef",
          "difficulty" => 1_234_567_890.123456,
          "mediantime" => 1_704_067_200,
          "verificationprogress" => 0.9999999,
          "chainwork" => "0000000000000000000000000000000000000000012345678901234567890abc",
          "pruned" => false,
          "warnings" => ""
        }

      response ->
        response
    end
  end

  @doc """
  Mock implementation of getblockhash.
  """
  def getblockhash(height) do
    case RpcStub.get_stub({:getblockhash, height}) do
      nil ->
        # Generate a deterministic hash based on height
        :crypto.hash(:sha256, "block_#{height}")
        |> Base.encode16(case: :lower)
        |> String.slice(0, 64)
        |> String.pad_trailing(64, "0")

      hash ->
        hash
    end
  end

  @doc """
  Mock implementation of getblock.
  """
  def getblock(hash, verbosity \\ 1) do
    case RpcStub.get_stub({:getblock, hash, verbosity}) do
      nil ->
        case verbosity do
          0 ->
            # Return hex-encoded block data (verbosity 0)
            # This is a minimal valid block header + 1 transaction
            # 80 bytes header + 1 byte tx count + minimal coinbase tx
            # version
            # prev hash
            # merkle root
            # time
            # bits
            # nonce
            # tx count (1)
            # Minimal coinbase transaction
            "01000000" <>
              "7bc154e0fa7ea32218a72fe2c1bb9f86cf8c9ebf9a715ed27fdb229a00000000" <>
              "f3e94742aca4b5ef85488dc37c06c3282295ffec960994b2c0d5ac2a25a95766" <>
              "29ab5f49" <>
              "ffff001d" <>
              "f3e0ff0d" <>
              "01" <>
              "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff0704ffff001d0102ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"

          _ ->
            # Return JSON (verbosity 1+)
            %{
              "hash" => hash,
              "confirmations" => 100,
              "size" => 285,
              "height" => 100,
              "version" => 1,
              "merkleroot" => "f3e94742aca4b5ef85488dc37c06c3282295ffec960994b2c0d5ac2a25a95766",
              "num_tx" => 4,
              "tx" => [
                "8c14f0db3df150123e6f3dbbf30f8b955a8249b62ac1d1ff16284aefa3d06d87",
                "fff2525b8931402dd09222c50775608f75787bd2b87e56995a7bdd30f79702c4"
              ],
              "time" => 1_231_469_665,
              "mediantime" => 1_231_469_665,
              "nonce" => 1_573_057_331,
              "bits" => "1d00ffff",
              "difficulty" => 1.0,
              "chainwork" => "0000000000000000000000000000000000000000000000000000014100014100",
              "previousblockhash" =>
                "000000007bc154e0fa7ea32218a72fe2c1bb9f86cf8c9ebf9a715ed27fdb229a",
              "nextblockhash" =>
                "00000000c937983704a73af28acdec37b049d214adbda81d7e2a3dd146f6ed09"
            }
        end

      response ->
        response
    end
  end

  @doc """
  Mock implementation of getblockheader.
  """
  def getblockheader(hash, verbosity \\ true) do
    case RpcStub.get_stub({:getblockheader, hash, verbosity}) do
      nil ->
        %{
          "hash" => hash,
          "height" => 100,
          "time" => 1_693_929_600,
          "chainwork" => "0000000000000000000000000000000000000000000000000000000000100000",
          "previousblockhash" => String.duplicate("0", 64)
        }

      response ->
        response
    end
  end

  @doc """
  Mock implementation of getrawtransaction.
  """
  def getrawtransaction(txid, verbosity \\ 0) do
    case RpcStub.get_stub({:getrawtransaction, txid, verbosity}) do
      nil ->
        if verbosity == 0 do
          # Return raw hex
          "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff0704ffff001d0102ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"
        else
          # Return decoded transaction
          %{
            "txid" => txid,
            "hash" => txid,
            "version" => 1,
            "size" => 215,
            "locktime" => 0,
            "vin" => [
              %{
                "coinbase" => "04ffff001d0102",
                "sequence" => 4_294_967_295
              }
            ],
            "vout" => [
              %{
                "value" => 50.0,
                "n" => 0,
                "scriptPubKey" => %{
                  "asm" =>
                    "04678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5f OP_CHECKSIG",
                  "hex" =>
                    "4104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac",
                  "type" => "pubkey"
                }
              }
            ],
            "hex" =>
              "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff0704ffff001d0102ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000",
            "blockhash" => "00000000000000000123456789abcdef00000000000000000123456789abcdef",
            "confirmations" => 850_000,
            "time" => 1_231_469_665,
            "blocktime" => 1_231_469_665
          }
        end

      response ->
        response
    end
  end

  @doc """
  Mock implementation of batch_getblockhash.
  """
  def batch_getblockhash(heights) do
    case RpcStub.get_stub({:batch_getblockhash, heights}) do
      nil ->
        # Generate hashes for all heights
        hashes =
          Enum.map(heights, fn height ->
            {height, getblockhash(height)}
          end)
          |> Map.new()

        {:ok, hashes}

      response ->
        response
    end
  end

  @doc """
  Mock implementation of batch_getblock.
  """
  def batch_getblock(hashes, verbosity \\ 1) do
    blocks =
      Enum.map(hashes, fn hash ->
        {hash, getblock(hash, verbosity)}
      end)
      |> Map.new()

    {:ok, blocks}
  end

  @doc """
  Mock implementation of getchaintips.
  """
  def getchaintips do
    case RpcStub.get_stub(:getchaintips) do
      nil ->
        [
          %{
            "hash" => "mock-main-tip",
            "height" => 100,
            "branchlen" => 0,
            "status" => "active",
            "chainwork" => "0000000000000000000000000000000000000000000000000000000000100000"
          }
        ]

      response ->
        response
    end
  end

  @doc """
  Mock implementation of batch_getrawtransaction.
  """
  def batch_getrawtransaction(txids, verbosity \\ 0) do
    case RpcStub.get_stub({:batch_getrawtransaction, txids}) do
      nil ->
        # Generate transactions for all txids
        transactions =
          Enum.map(txids, fn txid ->
            {txid, getrawtransaction(txid, verbosity)}
          end)
          |> Map.new()

        {:ok, transactions}

      response ->
        response
    end
  end

  @doc """
  Mock implementation of batch_rpc.

  Handles batch RPC requests by routing to the appropriate mock functions.
  """
  def batch_rpc(requests) do
    responses =
      Enum.map(requests, fn {method, params} ->
        case method do
          "getblockhash" ->
            [height] = params
            getblockhash(height)

          "getblock" ->
            case params do
              [hash] -> getblock(hash, 1)
              [hash, verbosity] -> getblock(hash, verbosity)
            end

          "getrawtransaction" ->
            case params do
              [txid] -> getrawtransaction(txid, 0)
              [txid, verbosity] -> getrawtransaction(txid, verbosity)
            end

          _ ->
            {:error, "Unknown method: #{method}"}
        end
      end)

    {:ok, responses}
  end

  @doc """
  Mock implementation of bitcoin_url (for testing config).
  """
  def bitcoin_url do
    {:ok, "http://localhost:8332"}
  end

  @doc """
  Mock implementation of decoderawtransaction.
  """
  def decoderawtransaction(hex) do
    # Return a basic decoded structure
    %{
      "txid" => "mock_txid_#{String.slice(hex, 0, 8)}",
      "version" => 1,
      "locktime" => 0,
      "vin" => [],
      "vout" => []
    }
  end
end
