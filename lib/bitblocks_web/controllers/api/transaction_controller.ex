defmodule BitblocksWeb.Api.TransactionController do
  use BitblocksWeb, :controller

  alias Bitblocks.Chain

  action_fallback BitblocksWeb.FallbackController

  @doc """
  List transactions with optional filters.

  GET /api/v1/txs?cursor=...&per_page=50&block_hash=...

  Confirmation order: highest block first, by `(block_height, txid)`, so a
  backfill of old blocks never jumps the first page. `cursor` is the previous
  page's `meta.next_cursor`. `meta.complete` is false while any block in the
  listing's range isn't `completed` (`Chain.tx_list_coverage/1`).
  """
  def index(conn, params) do
    per_page = parse_int(params["per_page"], 50) |> min(100)

    filters =
      %{}
      |> maybe_put(:block_hash, params["block_hash"])
      |> maybe_put(:txid_search, params["txid"])
      |> maybe_put(:protocol, params["protocol"])

    case Chain.decode_tx_cursor(params["cursor"]) do
      {:ok, cursor} ->
        {txs, next_cursor} = Chain.list_transactions_paginated(cursor, per_page, filters)

        json(conn, %{
          data: with_confirmation(txs),
          meta:
            filters
            |> Chain.tx_list_coverage()
            |> Map.merge(%{next_cursor: next_cursor, per_page: per_page})
        })

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid cursor: use meta.next_cursor from the previous page."})
    end
  end

  @doc """
  Get a single transaction by txid.

  GET /api/v1/txs/:txid
  """
  def show(conn, %{"txid" => txid}) do
    case Chain.get_transaction_by_txid(txid) do
      nil ->
        {:error, :not_found}

      tx ->
        spend_depth =
          case Chain.spend_depth(tx.txid) do
            {:ok, d} -> d
            {:error, reason} -> %{error: reason}
          end

        [data] = with_confirmation([tx])
        json(conn, %{data: Map.put(data, :spend_depth, spend_depth)})
    end
  end

  defp with_confirmation(txs) do
    confirmations = Chain.confirmations(txs)
    Enum.map(txs, &Map.merge(tx_to_json(&1), Map.fetch!(confirmations, &1.txid)))
  end

  defp tx_to_json(tx) do
    base = %{
      txid: tx.txid,
      block_hash: tx.block_hash,
      block_height: tx.block_height,
      version: tx.version,
      input_count: tx.input_count,
      output_count: tx.output_count,
      size_bytes: tx.size_bytes,
      raw_in_db: tx.raw_in_db,
      total_input_satoshis: tx.total_input_satoshis,
      total_output_satoshis: tx.total_output_satoshis,
      fee: Chain.Transaction.miner_fee(tx)
    }

    # Only once the bytes are verified in the blob store (Bitblocks.TxStore):
    # the raw tx, immutable, at one global CDN URL.
    case Bitblocks.TxStore.url(tx) do
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
      {n, ""} -> max(n, 1)
      _ -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
end
