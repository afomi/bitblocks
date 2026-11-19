defmodule BitblocksWeb.Api.DownloadController do
  @moduledoc """
  Bulk downloads over HTTP (https://github.com/afomi/bitblocks/issues/111),
  first cut: the free quote only.

    * `GET /api/v1/downloads/quote?from=&to=&data=raw&format=bin` — the size
      and file count of a block range, from stored block sizes
      (`Bitblocks.Downloads.quote/4`), bounded by `complete_through`.
      `price_usd` is null while no price is set; `price` then says
      `on_request` and `contact` where to ask.

  Errors are a 422 with `error` (a code) and `message`; a range above
  `complete_through` names it in `complete_through`.
  """
  use BitblocksWeb, :controller

  alias Bitblocks.Downloads
  alias BitblocksWeb.Plugs.RateLimiter.AiCrawlers

  def quote(conn, params) do
    case Downloads.quote(params["from"], params["to"], params["data"], format: params["format"]) do
      {:ok, quote} ->
        json(conn, %{
          data:
            quote
            |> Map.update!(:price_usd, &(&1 && Decimal.to_string(&1)))
            |> Map.merge(%{
              price: if(quote.price_usd, do: "quoted", else: "on_request"),
              contact: "mailto:" <> AiCrawlers.contact_email(),
              checkout: "not_built"
            }),
          meta: %{
            covers:
              "Blocks completed through complete_through: each with every tx stored and its merkleroot rebuilt.",
            size_source: "blocks.size",
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
end
