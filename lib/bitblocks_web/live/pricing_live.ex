defmodule BitblocksWeb.PricingLive do
  @moduledoc """
  `/pricing`: the plans, and (`#crawlers`) the way in for AI crawlers and data
  licensing, which the crawler 402 links to (`BitblocksWeb.Plugs.RateLimiter`,
  #107). Keys have no price yet (#61), so that section says to write to us;
  with x402 on, it also gives the per-request price and how to pay
  (`#crawlers-x402`). Its budget, coverage and price are read when the page
  loads.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.SyncProgress
  alias BitblocksWeb.Plugs.RateLimiter.AiCrawlers
  alias BitblocksWeb.Seo
  alias BitblocksWeb.StartLive.Index

  @impl true
  def mount(_params, _session, socket) do
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
     |> assign(:coverage, Index.coverage(SyncProgress.snapshot().overview))
     |> assign(:contact_email, AiCrawlers.contact_email())
     |> assign(:x402, x402())}
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
