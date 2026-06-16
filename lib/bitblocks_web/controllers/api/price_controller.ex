defmodule BitblocksWeb.Api.PriceController do
  @moduledoc """
  Serves the cached BSV spot price.

  The value is fetched from CoinGecko on an interval and cached in
  `Bitblocks.PriceCache` — this endpoint never calls CoinGecko directly, so it
  is cheap and not subject to CoinGecko's rate limits.
  """
  use BitblocksWeb, :controller

  @doc """
  GET /api/v1/price/bsv

  Returns the cached BSV price. 503 until the first successful fetch after boot.
  """
  def show(conn, _params) do
    case Bitblocks.PriceCache.get() do
      nil ->
        conn
        |> put_status(503)
        |> json(%{error: "Price not available yet. Try again shortly."})

      price ->
        json(conn, %{
          data: %{
            symbol: "BSV",
            currency: price.currency,
            price: price.price,
            change_24h: price.change_24h,
            source: price.source,
            fetched_at: price.fetched_at,
            coin_updated_at: price.coin_updated_at
          }
        })
    end
  end
end
