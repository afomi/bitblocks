defmodule Bitblocks.Chain.TxSources do
  @moduledoc """
  Where a block's transaction bodies come from: the configured node first,
  then WhatsOnChain for whatever the node can't serve.

  Our own node has been down for months, and the public no-auth node
  (PublicNode) is pruned to roughly the last 300 blocks: headers and recent
  bodies come from it, older bodies from WhatsOnChain (`Bitblocks.Woc`).

  Nothing here is trusted on a source's word. The txid list a block is
  checked against is merkleroot-verified in `Chain.TxidSource`, and every
  body is hashed against its txid in `Chain.TxIngest`, whichever source
  supplied it.

  A rate limit from either source (HTTP 429, JSON-RPC -32005) is reported as
  `{:error, :rate_limited}` on the txids it left unfetched, so the workers
  can back off instead of charging the block an attempt.
  """

  require Logger

  alias Bitblocks.Chain.Block
  alias Bitblocks.Woc

  @doc "Whether WhatsOnChain may be used as a fallback (`:woc_fallback`, default true)."
  def fallback_enabled?, do: Application.get_env(:bitblocks, :woc_fallback, true)

  @doc """
  False when the node is known to have pruned this block (its
  `getblockchaininfo` reports `pruneheight` above the block), so callers can
  skip a node round-trip that can only answer "not available". Unknown
  (node unreachable, not pruned) is true: ask the node.
  """
  def node_has_block?(%Block{height: height}) when is_integer(height) do
    case Bitblocks.RpcCache.get_blockchain_info() do
      %{"pruned" => true, "pruneheight" => prune} when is_integer(prune) -> height >= prune
      _ -> true
    end
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  def node_has_block?(_block), do: true

  @doc """
  Fetches bodies for `txids`, returning `txid => tx map | {:error, reason}`
  for every txid asked for. Node first (skipped when the block is below the
  node's prune height), WhatsOnChain for the rest.
  """
  @spec fetch_raw([String.t()], Block.t()) :: %{String.t() => map() | {:error, term()}}
  def fetch_raw(txids, %Block{} = block) do
    from_node =
      if node_has_block?(block) do
        case rpc().batch_getrawtransaction(txids, 1) do
          {:ok, results} ->
            Map.new(txids, &{&1, Map.get(results, &1, {:error, :no_result})})

          {:error, reason} ->
            Map.new(txids, &{&1, {:error, reason}})
        end
      else
        Map.new(txids, &{&1, {:error, :pruned}})
      end

    missing = for txid <- txids, not is_map(from_node[txid]), do: txid

    if missing == [] or not fallback_enabled?() do
      from_node
    else
      Map.merge(from_node, from_woc(missing))
    end
  end

  # WoC bulk lookups take 20 txids. A txid WoC doesn't return keeps an error;
  # a rate limit marks the rest of the chunk :rate_limited.
  defp from_woc(txids) do
    txids
    |> Enum.chunk_every(Woc.bulk_size())
    |> Enum.reduce(%{}, fn chunk, acc ->
      case Woc.txs(chunk) do
        {:ok, txs} ->
          found = for tx <- txs, is_map(tx), tx["txid"] in chunk, into: %{}, do: {tx["txid"], tx}
          Map.merge(acc, Map.new(chunk, &{&1, Map.get(found, &1, {:error, :not_found})}))

        {:error, reason} ->
          reason = if rate_limited?(reason), do: :rate_limited, else: {:woc, reason}
          Logger.warning("TxSources: WoC bulk tx fetch failed: #{inspect(reason)}")
          Map.merge(acc, Map.new(chunk, &{&1, {:error, reason}}))
      end
    end)
  end

  @doc "True for a rate-limit error from either source."
  def rate_limited?(:rate_limited), do: true
  def rate_limited?({:http_status, 429, _}), do: true
  def rate_limited?({:error, reason}), do: rate_limited?(reason)
  def rate_limited?(reason), do: BitcoinsvCli.rate_limited?(reason)

  @doc "True when any per-txid result in `results` is a rate limit."
  def any_rate_limited?(results) when is_map(results) do
    Enum.any?(results, fn
      {_txid, {:error, reason}} -> rate_limited?(reason)
      _ -> false
    end)
  end

  defp rpc, do: Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)
end
