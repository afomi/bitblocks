defmodule BitblocksWeb.PricingLive do
  @moduledoc """
  `/pricing`: the plans, and (`#crawlers`) the way in for AI crawlers and data
  licensing, which the crawler 402 links to (`BitblocksWeb.Plugs.RateLimiter`,
  #107). Keys have no price yet (#61), so that section says to write to us;
  with x402 on, it also gives the per-request price and how to pay
  (`#crawlers-x402`). Its budget, coverage and price are read when the page
  loads.

  `#downloads` quotes a bulk download of a block range (`Bitblocks.Downloads`,
  https://github.com/afomi/bitblocks/issues/111): size and file count from
  stored block sizes, bounded by `complete_through`. No price is set, so the
  quote says "Price on request" and links to us. A socket gets one quote per
  `@quote_interval_ms`, since each is an aggregate over `blocks`.
  """
  use BitblocksWeb, :live_view

  require Logger

  alias Bitblocks.Downloads
  alias Bitblocks.SyncProgress
  alias BitblocksWeb.Plugs.RateLimiter.AiCrawlers
  alias BitblocksWeb.Seo
  alias BitblocksWeb.StartLive.Index

  @quote_interval_ms 1_000
  @default_range 100_000

  @impl true
  def mount(_params, _session, socket) do
    coverage = Index.coverage(SyncProgress.snapshot().overview)

    {:ok,
     socket
     |> assign(
       Seo.public_page(
         page_title: "Pricing",
         meta_description:
           "Bitblocks API pricing: start free, and pay for what you use as you grow.",
         canonical_path: "/pricing"
       )
     )
     |> assign(:crawler_budget, crawler_budget())
     |> assign(:fetcher_budget, fetcher_budget())
     |> assign(:coverage, coverage)
     |> assign(:contact_email, AiCrawlers.contact_email())
     |> assign(:x402, x402())
     |> assign(:data_options, Downloads.data_options())
     |> assign(:quote_form, to_form(default_quote_params(coverage), as: :quote))
     |> assign(:quote, nil)
     |> assign(:quote_error, nil)
     |> assign(:quoted_at, nil)}
  end

  @impl true
  def handle_event("quote_change", %{"quote" => params}, socket) do
    {:noreply, assign(socket, :quote_form, to_form(params, as: :quote))}
  end

  def handle_event("quote", %{"quote" => params}, socket) do
    socket = assign(socket, :quote_form, to_form(params, as: :quote))
    now = System.monotonic_time(:millisecond)

    if socket.assigns.quoted_at && now - socket.assigns.quoted_at < @quote_interval_ms do
      {:noreply,
       assign(socket,
         quote: nil,
         quote_error: "One quote a second, please. Try again in a moment."
       )}
    else
      socket = assign(socket, :quoted_at, now)

      case quote_or_unavailable(params) do
        {:ok, quote} ->
          {:noreply, assign(socket, quote: quote, quote_error: nil)}

        {:error, :unavailable} ->
          {:noreply,
           assign(socket,
             quote: nil,
             quote_error: "Quotes are unavailable right now. Try again shortly."
           )}

        {:error, reason} ->
          {:noreply, assign(socket, quote: nil, quote_error: Downloads.error_message(reason))}
      end
    end
  end

  # A slow or failed query says so on the page rather than crashing it.
  defp quote_or_unavailable(params) do
    Downloads.quote(params["from"], params["to"], params["data"], format: params["format"])
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Downloads quote failed: #{Exception.message(error)}")
      {:error, :unavailable}
  end

  # Blocks 0 to 99,999, or as far as the complete blocks reach.
  defp default_quote_params(coverage) do
    to =
      case coverage do
        %{through: through} -> min(through, @default_range - 1)
        nil -> @default_range - 1
      end

    %{"from" => "0", "to" => Integer.to_string(to), "data" => "raw", "format" => "bin"}
  end

  @doc "The formats a data option comes in, for the format select."
  def formats_for(options, data) do
    case Enum.find(options, &(&1.id == data)) do
      %{formats: formats} -> Enum.filter(formats, & &1.available)
      nil -> []
    end
  end

  @doc "The mailto for a quote: our address, with the quote in the subject and body."
  def quote_mailto(email, quote) do
    subject = "Bulk download quote: blocks #{quote.from} to #{quote.to}"

    body =
      Enum.join(
        [
          "Blocks: #{format_number(quote.from)} to #{format_number(quote.to)}",
          "Data: #{quote.data}, format: #{quote.format}",
          "Files: #{format_number(quote.files)}",
          "Size: #{format_number(quote.bytes)} bytes (#{format_gib(quote.bytes)} GiB)",
          "Complete through: #{format_number(quote.complete_through)}"
        ],
        "\n"
      )

    "mailto:#{email}?" <> URI.encode_query(%{subject: subject, body: body}, :rfc3986)
  end

  @doc "Bytes as GiB with two decimals, and a floor so a small range doesn't read as zero."
  def format_gib(0), do: "0"

  def format_gib(bytes) when bytes * 100 < 1_073_741_824, do: "< 0.01"

  def format_gib(bytes) do
    [whole, fraction] =
      (bytes / 1_073_741_824) |> :erlang.float_to_binary(decimals: 2) |> String.split(".")

    format_number(String.to_integer(whole)) <> "." <> fraction
  end

  @doc """
  What the x402 offer is, for `#crawlers-x402`, or nil while x402 is off
  (`Bitblocks.Payments.X402.enabled?/0`), so no price shows that can't be paid.
  """
  def x402 do
    alias Bitblocks.Payments.X402, as: Pay

    if Pay.enabled?() do
      %{
        price: Pay.price_usdc(),
        network: Pay.network(),
        network_name: Pay.network_name(Pay.network())
      }
    end
  end

  @doc "Requests a minute an AI crawler family shares without a key."
  def crawler_budget do
    Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, [])
    |> Keyword.get(:ai_crawler_max_requests, 10)
  end

  @doc "Requests a minute a company's user-triggered fetcher has without a key."
  def fetcher_budget do
    Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, [])
    |> Keyword.get(:ai_fetcher_max_requests, 30)
  end

  defdelegate format_number(n), to: Index
end
