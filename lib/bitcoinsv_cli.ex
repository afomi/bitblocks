defmodule BitcoinsvCli do
  @moduledoc """
  Documentation for `BitcoinsvCli`.
  """

  require Logger

  # T9: node responses are untrusted (TB2) and may contain sensitive or
  # attacker-influenced content. When logging an error body/reason, cap its
  # length so a node can't flood the logs and we don't echo large payloads
  # verbatim into operator-visible output.
  @max_log_body 500

  defp redact(value) when is_binary(value) do
    if byte_size(value) > @max_log_body do
      binary_part(value, 0, @max_log_body) <> "…(truncated #{byte_size(value)} bytes)"
    else
      value
    end
  end

  defp redact(value), do: value |> inspect() |> redact()

  #
  # Specify BitcoinSV node info from `config.exs`
  #
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

  def getblock(blockhash, 0) do
    bitcoin_rpc("getblock", [blockhash, 0])
  end

  def getblock(blockhash, 1) do
    bitcoin_rpc("getblock", [blockhash, 1])
  end

  def getblock(blockhash, 2) do
    bitcoin_rpc("getblock", [blockhash, 2])
  end

  def getblockheader(blockhash, verbose \\ true) do
    verbosity =
      case verbose do
        true -> 1
        false -> 0
        0 -> 0
        1 -> 1
        other -> other
      end

    bitcoin_rpc("getblockheader", [blockhash, verbosity])
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

  def getchaintips do
    bitcoin_rpc("getchaintips", [])
  end

  # Bitcoin Transaction API
  #
  # https://en.bitcoin.it/wiki/Raw_Transactions#Input_selection_control
  # and https://github.com/bitcoin-sv/bitcoin-sv/blob/782c043fb39060bfc12179792a590b6405b91f3c/src/wallet/rpcwallet.cpp
  #
  def listunspent(minconf = 1, maxconf = 999_999) do
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

  def getblocktemplate do
    bitcoin_rpc("getblocktemplate", [])
  end

  def submitblock(hex_data) do
    bitcoin_rpc("submitblock", [hex_data])
  end

  def gettxoutproof(txids, blockhash \\ nil) do
    params = if blockhash, do: [txids, blockhash], else: [txids]
    bitcoin_rpc("gettxoutproof", params)
  end

  # [{"txid":txid,"vout":n,"scriptPubKey":hex},...] [<privatekey1>,...] [sighash="ALL"]
  def signrawtransaction(hex) do
    bitcoin_rpc("signrawtransaction", [hex])
  end

  def sendrawtransaction(hex) do
    bitcoin_rpc("sendrawtransaction", [hex])
  end

  def headers do
    case {rpc_user(), rpc_password()} do
      {nil, _} ->
        [{"Content-Type", "application/json"}]

      {_, nil} ->
        [{"Content-Type", "application/json"}]

      {user, password} ->
        [
          {"Authorization", "Basic " <> Base.encode64("#{user}:#{password}")},
          {"Content-Type", "application/json"}
        ]
    end
  end

  @doc """
  Batch RPC request - sends multiple RPC calls in a single HTTP request.
  This significantly reduces latency when making many calls, especially to remote nodes.

  ## Parameters

  - `requests` - List of {method, params} tuples or {id, method, params} tuples

  ## Returns

  - `{:ok, results}` - Map of request id to result
  - `{:error, reason}` - If the batch request fails

  ## Examples

      # Simple batch with auto-generated IDs
      requests = [
        {"getblockhash", [0]},
        {"getblockhash", [1]},
        {"getblockhash", [2]}
      ]
      {:ok, results} = BitcoinsvCli.batch_rpc(requests)
      # Returns: %{0 => "hash0", 1 => "hash1", 2 => "hash2"}

      # Batch with custom IDs
      requests = [
        {"block_0", "getblockhash", [0]},
        {"block_1", "getblockhash", [1]}
      ]
      {:ok, results} = BitcoinsvCli.batch_rpc(requests)
      # Returns: %{"block_0" => "hash0", "block_1" => "hash1"}
  """
  def batch_rpc(requests) when is_list(requests) do
    batch_size = length(requests)

    # Get method name for telemetry (use first request's method)
    method =
      case List.first(requests) do
        {_id, m, _params} -> m
        {m, _params} -> m
        _ -> "unknown"
      end

    Bitblocks.TelemetryHelper.measure_batch_rpc(method, batch_size, fn ->
      # Convert requests to batch format with IDs
      batch_commands =
        requests
        |> Enum.with_index()
        |> Enum.map(fn
          {{id, method, params}, _index} ->
            %{jsonrpc: "1.0", id: id, method: method, params: params}

          {{method, params}, index} ->
            %{jsonrpc: "1.0", id: index, method: method, params: params}
        end)

      {timeout, recv_timeout} = batch_rpc_timeouts()

      with {:ok, url} <- bitcoin_url(),
           {:ok, body} <- Poison.encode(batch_commands),
           {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} <-
             HTTPoison.post(url, body, headers(),
               timeout: timeout,
               recv_timeout: recv_timeout,
               max_body_length: 500_000_000
             ),
           {:ok, responses} <- Poison.decode(response_body) do
        # Convert array of responses to a map keyed by ID
        results =
          responses
          |> Enum.map(fn response ->
            id = response["id"]
            result = response["result"]
            error = response["error"]

            if error do
              {id, {:error, error}}
            else
              {id, result}
            end
          end)
          |> Map.new()

        {:ok, results}
      else
        {:error, :missing_bitcoin_url} ->
          {:error, :missing_bitcoin_url}

        {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:error, {:connection_error, reason}}

        {:error, %Poison.ParseError{} = error} ->
          {:error, {:parse_error, error}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Batch getblockhash - fetches multiple block hashes in a single request.

  ## Examples

      heights = [0, 1, 2, 3, 4]
      {:ok, hashes} = BitcoinsvCli.batch_getblockhash(heights)
      # Returns: %{0 => "hash0", 1 => "hash1", ...}
  """
  def batch_getblockhash(heights) when is_list(heights) do
    requests = Enum.map(heights, fn height -> {height, "getblockhash", [height]} end)
    batch_rpc(requests)
  end

  @doc """
  Batch getblock - fetches multiple blocks in a single request.

  ## Examples

      hashes = ["hash1", "hash2", "hash3"]
      {:ok, blocks} = BitcoinsvCli.batch_getblock(hashes)
  """
  def batch_getblock(hashes, level \\ 1) when is_list(hashes) do
    requests = Enum.map(hashes, fn hash -> {hash, "getblock", [hash, level]} end)
    batch_rpc(requests)
  end

  @doc """
  Batch getrawtransaction - fetches multiple raw transactions in a single request.

  ## Parameters

  - `txids` - List of transaction IDs to fetch
  - `verbose` - 0 for hex, 1 for decoded JSON (default: 1)

  ## Examples

      txids = ["txid1", "txid2", "txid3"]
      {:ok, transactions} = BitcoinsvCli.batch_getrawtransaction(txids)
  """
  def batch_getrawtransaction(txids, verbose \\ 1) when is_list(txids) do
    requests = Enum.map(txids, fn txid -> {txid, "getrawtransaction", [txid, verbose]} end)
    batch_rpc(requests)
  end

  @doc """
  Fetch transactions for a block in chunks to handle large blocks.

  ## Parameters

  - `txids` - List of transaction IDs from a block
  - `opts` - Options:
    - `:chunk_size` - Number of transactions per batch (default: 100)
    - `:max_txs` - Maximum number of transactions to fetch (default: nil = all)
    - `:verbose` - Transaction verbosity level (default: 1)

  ## Returns

  List of transactions in the same order as input txids

  ## Examples

      # Fetch first 1000 transactions in chunks of 100
      txids = block["tx"]
      transactions = BitcoinsvCli.fetch_block_transactions(txids, max_txs: 1000, chunk_size: 100)
  """
  def fetch_block_transactions(txids, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 100)
    max_txs = Keyword.get(opts, :max_txs)
    verbose = Keyword.get(opts, :verbose, 1)

    # Limit txids if max_txs is specified
    limited_txids =
      if max_txs do
        Enum.take(txids, max_txs)
      else
        txids
      end

    Logger.info("Fetching #{length(limited_txids)} transactions in chunks of #{chunk_size}")

    # Process in chunks
    limited_txids
    |> Enum.chunk_every(chunk_size)
    |> Enum.flat_map(fn chunk ->
      case batch_getrawtransaction(chunk, verbose) do
        {:ok, results} ->
          # Return transactions in original order
          Enum.map(chunk, fn txid ->
            case Map.get(results, txid) do
              {:error, _} -> nil
              tx -> tx
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:error, reason} ->
          Logger.error("Failed to fetch transaction chunk: #{inspect(reason)}")
          []
      end
    end)
  end

  # Shared functions
  #
  def bitcoin_rpc(method, params \\ []) do
    Bitblocks.TelemetryHelper.measure_rpc(method, fn ->
      command = %{jsonrpc: "1.0", method: method, params: params}

      # IO.inspect(command, label: "Bitcoin RPC Command")

      {timeout, recv_timeout} = rpc_timeouts()

      with {:ok, url} <- bitcoin_url(),
           {:ok, body} <- Poison.encode(command),
           {:ok, %HTTPoison.Response{status_code: _status, body: response_body}} <-
             HTTPoison.post(url, body, headers(),
               timeout: timeout,
               recv_timeout: recv_timeout,
               # 500MB max response
               max_body_length: 500_000_000
             ),
           {:ok, %{"error" => nil, "result" => result}} <- Poison.decode(response_body) do
        result
      else
        {:error, :missing_bitcoin_url} ->
          Logger.error("Bitcoin RPC Error: BITCOIN_NODE_URL is not configured")
          {:error, :missing_bitcoin_url}

        {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
          Logger.error("Bitcoin RPC HTTP #{status}: #{redact(body)}")
          {:error, {:http_error, status, body}}

        {:ok, %{"error" => %{"code" => -32601, "message" => "Method not found"}}} ->
          Logger.error("METHOD NOT FOUND. bitcoind may need `disablewallet=0` set in bitcoin.conf")
          {:error, :method_not_found}

        {:error, :invalid, 0} ->
          Logger.warning("Retrying request after 5 seconds due to transient error")
          Process.sleep(5_000)
          bitcoin_rpc(method, params)

        {:ok, %{"error" => reason}} ->
          Logger.error("Bitcoin RPC error: #{redact(reason)}")
          {:error, reason}

        {:error, %HTTPoison.Error{reason: reason}} ->
          Logger.error("Bitcoin RPC connection error: #{redact(reason)}")
          {:error, {:connection_error, reason}}

        {:error, %Poison.ParseError{}} ->
          Logger.error("Bitcoin RPC parse error: empty or invalid response from node")
          {:error, {:parse_error, :invalid_json}}

        {:error, reason} ->
          Logger.error("Bitcoin RPC unexpected error: #{redact(reason)}")
          {:error, reason}
      end
    end)
  end

  defp bitcoin_url do
    case Bitblocks.Config.bitcoin_url() do
      nil -> {:error, :missing_bitcoin_url}
      url -> {:ok, url}
    end
  end

  defp rpc_user do
    Bitblocks.Config.rpc_user()
  end

  defp rpc_password do
    Bitblocks.Config.rpc_password()
  end

  defp rpc_timeouts do
    timeout = Application.get_env(:bitblocks, :bitcoin_rpc_timeout_ms, 60_000)
    recv_timeout = Application.get_env(:bitblocks, :bitcoin_rpc_recv_timeout_ms, timeout)
    {timeout, recv_timeout}
  end

  defp batch_rpc_timeouts do
    timeout = Application.get_env(:bitblocks, :bitcoin_rpc_batch_timeout_ms, 60_000)
    {timeout, timeout}
  end
end
