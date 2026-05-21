defmodule BitblocksWeb.Api.TransactionController do
  use BitblocksWeb, :controller

  alias Bitblocks.Chain

  action_fallback BitblocksWeb.FallbackController

  @doc """
  List transactions with optional filters.

  GET /api/v1/txs?page=1&per_page=50&block_hash=...
  """
  def index(conn, params) do
    cursor = parse_int(params["cursor"], nil)
    per_page = parse_int(params["per_page"], 50) |> min(100)

    filters =
      %{}
      |> maybe_put(:block_hash, params["block_hash"])
      |> maybe_put(:txid_search, params["txid"])
      |> maybe_put(:protocol, params["protocol"])

    {txs, next_cursor} = Chain.list_transactions_paginated(cursor, per_page, filters)

    json(conn, %{
      data: Enum.map(txs, &tx_to_json/1),
      meta: %{
        next_cursor: next_cursor,
        per_page: per_page
      }
    })
  end

  @doc """
  Get a single transaction by txid.

  GET /api/v1/txs/:txid
  """
  def show(conn, %{"txid" => txid}) do
    case Chain.get_transaction_by_txid(txid) do
      nil -> {:error, :not_found}
      tx -> json(conn, %{data: tx_to_json(tx)})
    end
  end

  defp tx_to_json(tx) do
    base = %{
      txid: tx.txid,
      block_hash: tx.block_hash,
      block_height: tx.block_height,
      version: tx.version,
      input_count: tx.input_count,
      output_count: tx.output_count,
      total_input_satoshis: tx.total_input_satoshis,
      total_output_satoshis: tx.total_output_satoshis,
      fee: Chain.Transaction.miner_fee(tx)
    }

    case Bitblocks.TxCdn.cdn_url(tx.txid) do
      nil -> base
      url -> Map.put(base, :cdn_url, url)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} when is_nil(default) -> n
      {n, ""} -> max(n, 1)
      _ -> default
    end
  end
  defp parse_int(val, _default) when is_integer(val), do: val
end
