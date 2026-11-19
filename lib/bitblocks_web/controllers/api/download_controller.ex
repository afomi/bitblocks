defmodule BitblocksWeb.Api.DownloadController do
  @moduledoc """
  Bulk downloads over HTTP (https://github.com/afomi/bitblocks/issues/111),
  first cut: the free quote, with no checkout.

    * `GET /api/v1/downloads/quote?from=&to=&data=raw&format=bin` — the size,
      file count and price of a block range, from stored block sizes
      (`Bitblocks.Downloads.quote/4`), bounded by `complete_through`.
      `price_usd` is `billable_gib` x `price_usd_per_gib`, as a string; it is
      null, with `price` `on_request` and a `price_reason`, while no price is
      set or while a block in range has no stored size.
    * `GET /api/v1/downloads/sizes` — the size of each 50,000-block band up
      to `complete_through` (`Bitblocks.Downloads.size_bands/1`, cached ten
      minutes), and the named ranges (`presets`), for choosing a range.

  Errors are a 422 with `error` (a code) and `message`; a range above
  `complete_through` names it in `complete_through`.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Downloads
  alias BitblocksWeb.Plugs.RateLimiter.AiCrawlers

  @pricing "price_usd = billable_gib x price_usd_per_gib, rounded half up to the cent. " <>
             "billable_gib = bytes / 1,073,741,824, rounded half up to 0.01, and at least 0.01 for any bytes. " <>
             "No price while a block in range has no stored size: bytes is then a lower bound."

  def quote(conn, params) do
    case Downloads.quote(params["from"], params["to"], params["data"], format: params["format"]) do
      {:ok, quote} ->
        json(conn, %{
          data:
            quote
            |> Map.merge(%{
              billable_gib: Decimal.to_string(quote.billable_gib, :normal),
              price_usd_per_gib: decimal(quote.price_usd_per_gib),
              price_usd: decimal(quote.price_usd),
              price: if(quote.price_usd, do: "quoted", else: "on_request"),
              price_reason: price_reason(quote),
              contact: "mailto:" <> AiCrawlers.contact_email(),
              checkout: "not_built"
            }),
          meta: %{
            covers:
              "Blocks completed through complete_through: each with every tx stored and its merkleroot rebuilt.",
            size_source: "blocks.size",
            pricing: @pricing,
            file:
              "One .bin file per block: its exact bytes, the 80-byte header, the tx count, then every tx in order.",
            check:
              "Double SHA-256 of a file's first 80 bytes, byte-reversed, is the block hash (GET /api/v1/headers/:height); " <>
                "the txids of its txs rebuild the header's merkleroot.",
            data_options: Downloads.data_options()
          }
        })

      {:error, reason} ->
        body = %{error: Downloads.error_code(reason), message: Downloads.error_message(reason)}

        body =
          case reason do
            {:above_complete_through, h} -> Map.put(body, :complete_through, h)
            _ -> body
          end

        conn |> put_status(422) |> json(body)
    end
  end

  def sizes(conn, _params) do
    sizes = Downloads.size_bands()

    json(conn, %{
      data:
        Enum.map(sizes.bands, fn band ->
          Map.merge(band, %{
            billable_gib: Decimal.to_string(Downloads.billable_gib(band.bytes), :normal),
            price_usd: decimal(band.price_usd)
          })
        end),
      meta: %{
        complete_through: sizes.complete_through,
        band_size: sizes.band_size,
        computed_at: sizes.computed_at,
        cached_for_seconds: 600,
        price_usd_per_gib: decimal(Downloads.price_usd_per_gib()),
        pricing: @pricing,
        presets: Downloads.presets(sizes.complete_through),
        quote: "GET /api/v1/downloads/quote?from=&to=&data=raw"
      }
    })
  end

  defp price_reason(%{price_usd: %Decimal{}}), do: nil
  defp price_reason(%{price_usd_per_gib: nil}), do: "no_price_set"
  defp price_reason(%{sizes_missing: n}) when n > 0, do: "sizes_missing"
  defp price_reason(_), do: nil

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = d), do: Decimal.to_string(d, :normal)
end
