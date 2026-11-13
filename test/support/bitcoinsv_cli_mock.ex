defmodule BitcoinsvCliMock do
  @moduledoc """
  Mock implementation of `BitcoinsvCli` backed by `BitblocksWeb.RpcStub`.

  Wired in `config/test.exs` via `config :bitblocks, :bitcoinsv_cli, BitcoinsvCliMock`;
  application code reaches it through `Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)`.

  Unstubbed calls return `{:error, {:no_stub, fun, args}}` — the same shape as
  an unreachable node — so tests that never touch RPC keep their current
  behavior, and a test that forgets a stub fails loudly instead of silently
  succeeding on canned data. Every call is recorded and inspectable via
  `RpcStub.calls/0`.

  Batch functions compose from the per-item stubs: a batch result map contains
  only the stubbed items, so partial-fetch failure paths are testable by simply
  omitting a stub. A batch where nothing is stubbed errors like a failed RPC.
  """

  alias BitblocksWeb.RpcStub

  def getblockchaininfo do
    call(:getblockchaininfo, [], {:getblockchaininfo})
  end

  # Honours the cap as the real client does, in its exact shape
  # (test/bitcoinsv_cli_rest_test.exs): {:error, {:connection_error,
  # :body_too_large}}, not the bytes.
  def rest_block(hash, max_bytes) do
    case call(:rest_block, [hash], {:rest_block, hash}) do
      {:ok, bytes}
      when is_binary(bytes) and is_integer(max_bytes) and byte_size(bytes) > max_bytes ->
        {:error, {:connection_error, :body_too_large}}

      other ->
        other
    end
  end

  # The rest_block stub's bytes, handed to `fun` in 64 KB chunks the way
  # Finch would hand them over.
  def rest_block_stream(hash, acc, fun) do
    case call(:rest_block_stream, [hash], {:rest_block, hash}) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, feed(bytes, acc, fun)}
      other -> other
    end
  end

  defp feed(<<>>, acc, _fun), do: acc

  defp feed(bytes, acc, fun) do
    size = min(byte_size(bytes), 65_536)
    <<chunk::binary-size(size), rest::binary>> = bytes

    case fun.(chunk, acc) do
      {:cont, acc} -> feed(rest, acc, fun)
      {:halt, acc} -> acc
    end
  end

  def getblockhash(height) do
    call(:getblockhash, [height], {:getblockhash, height})
  end

  def getblock(hash), do: getblock(hash, 1)

  def getblock(hash, verbosity) do
    call(:getblock, [hash, verbosity], {:getblock, hash, verbosity})
  end

  def getblockheader(hash, verbose \\ true) do
    call(:getblockheader, [hash, verbose], {:getblockheader, hash})
  end

  def getrawtransaction(txid, verbose \\ 0) do
    call(:getrawtransaction, [txid, verbose], {:getrawtransaction, txid, verbose})
  end

  def gettxoutproof(txids, blockhash \\ nil) do
    call(:gettxoutproof, [txids, blockhash], {:gettxoutproof, txids, blockhash})
  end

  def getchaintips do
    call(:getchaintips, [], {:getchaintips})
  end

  def getmempoolinfo, do: call(:getmempoolinfo, [], {:getmempoolinfo})
  def getrawmempool, do: call(:getrawmempool, [], {:getrawmempool})
  def getmininginfo, do: call(:getmininginfo, [], {:getmininginfo})
  def getpeerinfo, do: call(:getpeerinfo, [], {:getpeerinfo})

  def batch_getblockhash(heights) when is_list(heights) do
    RpcStub.record_call(:batch_getblockhash, [heights])

    results =
      for height <- heights,
          {:ok, hash} <- [RpcStub.lookup({:getblockhash, height})],
          into: %{},
          do: {height, hash}

    if map_size(results) == 0 do
      {:error, {:no_stub, :batch_getblockhash, [heights]}}
    else
      {:ok, results}
    end
  end

  def batch_getblockheader(hashes) when is_list(hashes) do
    RpcStub.record_call(:batch_getblockheader, [hashes])

    results =
      for hash <- hashes,
          {:ok, header} <- [RpcStub.lookup({:getblockheader, hash})],
          into: %{},
          do: {hash, header}

    if map_size(results) == 0 do
      {:error, {:no_stub, :batch_getblockheader, [hashes]}}
    else
      {:ok, results}
    end
  end

  def batch_getblock(hashes, level \\ 1) when is_list(hashes) do
    RpcStub.record_call(:batch_getblock, [hashes, level])

    results =
      for hash <- hashes,
          {:ok, block} <- [RpcStub.lookup({:getblock, hash, level})],
          into: %{},
          do: {hash, block}

    if map_size(results) == 0 do
      {:error, {:no_stub, :batch_getblock, [hashes, level]}}
    else
      {:ok, results}
    end
  end

  def batch_getrawtransaction(txids, verbose \\ 1) when is_list(txids) do
    RpcStub.record_call(:batch_getrawtransaction, [txids, verbose])

    results =
      for txid <- txids,
          {:ok, tx} <- [RpcStub.lookup({:getrawtransaction, txid, verbose})],
          into: %{},
          do: {txid, tx}

    if map_size(results) == 0 do
      {:error, {:no_stub, :batch_getrawtransaction, [txids, verbose]}}
    else
      {:ok, results}
    end
  end

  defp call(fun, args, key) do
    RpcStub.record_call(fun, args)

    case RpcStub.lookup(key) do
      {:ok, value} -> value
      :miss -> {:error, {:no_stub, fun, args}}
    end
  end
end
