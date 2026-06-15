defmodule BitblocksWeb.Api.OrderBookController do
  use BitblocksWeb, :controller

  alias Bitblocks.OrderBook

  action_fallback BitblocksWeb.FallbackController

  @doc """
  List active order book listings with optional filters.

  GET /api/v1/order-book/listings
  Query params: token_id, min_price, max_price, seller, cursor, per_page
  """
  def index(conn, params) do
    opts =
      []
      |> maybe_put(:token_id, params["token_id"])
      |> maybe_put(:seller_address, params["seller"])
      |> maybe_put(:min_price, parse_int(params["min_price"]))
      |> maybe_put(:max_price, parse_int(params["max_price"]))
      |> maybe_put(:cursor, params["cursor"])
      |> maybe_put(:limit, parse_int(params["per_page"]) || 50)

    listings = OrderBook.list_active_listings(opts)

    json(conn, %{
      data: Enum.map(listings, &listing_to_json/1),
      count: length(listings)
    })
  end

  @doc """
  Get a single listing by txid.

  GET /api/v1/order-book/listings/:txid
  """
  def show(conn, %{"txid" => txid}) do
    case OrderBook.get_listing(txid) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Listing not found", txid: txid})

      listing ->
        json(conn, %{data: listing_to_json(listing)})
    end
  end

  @doc """
  List active listings for a specific token.

  GET /api/v1/order-book/tokens/:token_id
  """
  def token_listings(conn, %{"token_id" => token_id} = params) do
    opts =
      [token_id: token_id]
      |> maybe_put(:limit, parse_int(params["per_page"]) || 50)
      |> maybe_put(:cursor, params["cursor"])

    listings = OrderBook.list_active_listings(opts)

    json(conn, %{
      data: Enum.map(listings, &listing_to_json/1),
      token_id: token_id,
      count: length(listings)
    })
  end

  @doc """
  List active listings by a seller address.

  GET /api/v1/order-book/sellers/:address
  """
  def seller_listings(conn, %{"address" => address} = params) do
    opts =
      [seller_address: address]
      |> maybe_put(:limit, parse_int(params["per_page"]) || 50)
      |> maybe_put(:cursor, params["cursor"])

    listings = OrderBook.list_active_listings(opts)

    json(conn, %{
      data: Enum.map(listings, &listing_to_json/1),
      seller_address: address,
      count: length(listings)
    })
  end

  @doc """
  Aggregate order book statistics.

  GET /api/v1/order-book/stats
  """
  def stats(conn, _params) do
    stats = OrderBook.listing_stats()

    json(conn, %{data: stats})
  end

  @doc """
  Market-data summary for a token (price, volume, trade counts).

  GET /api/v1/order-book/tokens/:token_id/market
  """
  def token_market(conn, %{"token_id" => token_id}) do
    market = OrderBook.token_market(token_id)

    json(conn, %{data: market, token_id: token_id})
  end

  @doc """
  Recent confirmed trades (fills) for a token, most recent first.

  GET /api/v1/order-book/tokens/:token_id/trades
  Query params: per_page
  """
  def token_trades(conn, %{"token_id" => token_id} = params) do
    opts = maybe_put([], :limit, parse_int(params["per_page"]) || 50)

    trades = OrderBook.token_trades(token_id, opts)

    json(conn, %{
      data: Enum.map(trades, &trade_to_json/1),
      token_id: token_id,
      count: length(trades)
    })
  end

  # -- Private ----------------------------------------------------------------

  defp listing_to_json(listing) do
    %{
      version: listing.version,
      txid: listing.txid,
      vout: listing.vout,
      block_height: listing.block_height,
      token_id: listing.token_id,
      quantity: listing.quantity,
      price_satoshis: listing.price_satoshis,
      seller_address: listing.seller_address,
      token_utxo: listing.token_utxo,
      # The seller's pre-signed offer — a buyer reconstructs the swap's token
      # input from these, so they can settle without the seller online.
      seller_pubkey: listing.seller_pubkey,
      seller_sig: listing.seller_sig,
      sighash_flag: listing.sighash_flag,
      expires_at: listing.expires_at,
      min_quantity: listing.min_quantity,
      status: listing.status,
      quantity_remaining: listing.quantity_remaining,
      fills: listing.fills,
      inserted_at: listing.inserted_at
    }
  end

  defp trade_to_json(trade) do
    %{
      txid: trade.txid,
      listing_txid: trade.listing_txid,
      token_id: trade.token_id,
      quantity: trade.quantity,
      price_satoshis: trade.price_satoshis,
      total_satoshis: trade.total_satoshis,
      seller_address: trade.seller_address,
      block_height: trade.block_height,
      filled_at: trade.filled_at
    }
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_int(nil), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val
end
