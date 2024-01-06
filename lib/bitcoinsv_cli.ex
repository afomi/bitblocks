defmodule BitcoinsvCli do
  @moduledoc """
  Documentation for `BitcoinsvCli`.
  """

  #
  # Specify BitcoinSV node info from `config.exs`
  #
  @rpc_user Application.get_env(:bitblocks, :rpc_user)
  @rpc_password Application.get_env(:bitblocks, :rpc_password)
  @rpc_url Application.get_env(:bitblocks, :rpc_url)


  @doc """
  Hello world.

  ## Examples

      iex> BitcoinsvCli.getblockchaininfo()
      %{
        "bestblockhash" => "000000000000000008a24b07df00873a4eeef8969bfcc63e69fedc6647216b34",
        "blocks" => 811077,
        "chain" => "main",
        "chainwork" => "0000000000000000000000000000000000000000014b2057a71077c3364aa18e",
        "difficulty" => 70916790781.64828,
        "headers" => 811077,
        "mediantime" => 1695637586,
        "pruned" => false,
        "softforks" => [
          %{"id" => "bip34", "reject" => %{"status" => true}, "version" => 2},
          %{"id" => "bip66", "reject" => %{"status" => true}, "version" => 3},
          %{"id" => "bip65", "reject" => %{"status" => true}, "version" => 4},
          %{"id" => "csv", "reject" => %{"status" => true}, "version" => 5}
        ],
        "verificationprogress" => 0.9999991461626494
      }

  """

  def getblockchaininfo do
    bitcoin_rpc("getblockchaininfo", [])
  end

  def get_many_blocks(blockhashes) do
    Enum.map(blockhashes, fn blockhash -> getblock(blockhash) end)
  end

  # BitcoinsvCli.getblockhash(1)
  # "00000000839a8e6886ab5951d76f411475428afc90947ee320161bbf18eb6048"
  @spec getblockhash(integer()) :: any
  def getblockhash(blockheight) do
    bitcoin_rpc("getblockhash", [blockheight])
  end

  # BitcoinsvCli.getblock("00000000839a8e6886ab5951d76f411475428afc90947ee320161bbf18eb6048")
  # {
  #   "bits" => "1d00ffff",
  #   "chainwork" => "0000000000000000000000000000000000000000000000000000000200020002",
  #   "confirmations" => 811078,
  #   "difficulty" => 1,
  #   "hash" => "00000000839a8e6886ab5951d76f411475428afc90947ee320161bbf18eb6048",
  #   "height" => 1,
  #   "mediantime" => 1231469665,
  #   "merkleroot" => "0e3e2357e806b6cdb1f70b54c3a3a17b6714ee1f0e68bebb44a74b1efd512098",
  #   "nextblockhash" => "000000006a625f06636b8bb6ac7b960a8d03705d1ace08b1a19da3fdcc99ddbd",
  #   "nonce" => 2573394689,
  #   "num_tx" => 1,
  #   "previousblockhash" => "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f",
  #   "size" => 215,
  #   "status" => %{
  #     "data" => true,
  #     "disk meta" => true,
  #     "double spend" => false,
  #     "failed" => false,
  #     "parent failed" => false,
  #     "soft consensus frozen" => false,
  #     "soft reject" => false,
  #     "undo" => true,
  #     "validity" => "scripts"
  #   },
  #   "time" => 1231469665,
  #   "tx" => ["0e3e2357e806b6cdb1f70b54c3a3a17b6714ee1f0e68bebb44a74b1efd512098"],
  #   "version" => 1,
  #   "versionHex" => "00000001"
  # }
  def getblock(blockhash) do
    bitcoin_rpc("getblock", [blockhash])
  end

  def getblock(blockhash, level = 1) do
    bitcoin_rpc("getblock", [blockhash, level])
  end

  def getblock(blockhash, level = 2) do
    bitcoin_rpc("getblock", [blockhash, level])
  end

  def gettransaction(txid) do
    bitcoin_rpc("gettransaction", [txid])
  end

  def gettxout(txid) do
    bitcoin_rpc("gettxout", [txid])
  end

  def getmempoolinfo do
    bitcoin_rpc("getmempoolinfo", [])
  end

  def getrawmempool do
    bitcoin_rpc("getrawmempool", [])
  end

  def getmininginfo do
    bitcoin_rpc("getmininginfo", [])
  end

  def getpeerinfo do
    bitcoin_rpc("getpeerinfo", [])
  end


  # Bitcoin Transaction API
  #
  # https://en.bitcoin.it/wiki/Raw_Transactions#Input_selection_control
  # and https://github.com/bitcoin-sv/bitcoin-sv/blob/782c043fb39060bfc12179792a590b6405b91f3c/src/wallet/rpcwallet.cpp
  #
  def listunspent(minconf = 1, maxconf = 999999) do
    bitcoin_rpc("listunspent", [minconf, maxconf])
  end

  def listwallets do
    bitcoin_rpc("listwallets", [])
  end

  def listlockunspent do
    bitcoin_rpc("listlockunspent", [])
  end

  # BitcoinsvCli.getrawtransaction("698e0cfdbb8d67ec7d9947cc649eab425f0dd049321cf904ac03da0b8be8988a")
  # BitcoinsvCli.decoderawtransaction(a)
  def decoderawtransaction(hex) do
    bitcoin_rpc("decoderawtransaction", [hex])
  end

  def getrawtransaction(txid, verbose \\ 0) do
    bitcoin_rpc("getrawtransaction", [txid, verbose])
  end

  # [{"txid":txid,"vout":n,"scriptPubKey":hex},...] [<privatekey1>,...] [sighash="ALL"]
  def signrawtransaction(hex) do
    bitcoin_rpc("signrawtransaction", [hex])
  end

  def sendrawtransaction(hex) do
    bitcoin_rpc("sendrawtransaction", [hex])
  end




  def headers do
    [
      {"Authorization", "Basic " <> :base64.encode("#{@rpc_user}:#{@rpc_password}")},
      {"Content-Type", "application/json"}
    ]
  end


  # Shared functions
  #
  def bitcoin_rpc(method, params \\ []) do

    with url <- Application.get_env(:bitblocks, :bitcoin_url),
      command <- %{ jsonrpc: "1.0", method: method, params: params },
      {:ok, body} <- Poison.encode(command),
      {:ok, response} <- HTTPoison.post(url, body, headers(), [timeout: 45_000, recv_timeout: 45_000]),
      {:ok, metadata} <- Poison.decode(response.body),
      %{"error" => nil, "result" => result} <- metadata do
        result
      end
      # {:error, %HTTPoison.Error{id: nil, reason: :closed}
    else
      {:error, :invalid, 0} ->
        IO.puts("Retrying request after 5 seconds")
        Process.sleep(5_000)
        bitcoin_rpc(method, params)
      %{"error" => reason} -> {:error, reason}
      if %{"code" => -32601, "message" => "Method not found"} == reason do
        IO.puts "METHOD NOT FOUND. This is likely because bitcoind needs disablewallet=0 set in bitcoin.conf"
      end
      error -> error
  end

end
