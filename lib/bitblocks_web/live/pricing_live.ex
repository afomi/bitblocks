defmodule BitblocksWeb.PricingLive do
  @moduledoc """
  `/pricing`: the plans, and (`#crawlers`) the way in for AI crawlers and data
  licensing, which the crawler 402 links to (`BitblocksWeb.Plugs.RateLimiter`,
  #107). No price is set for crawlers yet (#61), so that section says to
  write to us. Its budget and coverage are read when the page loads.
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
     |> assign(:contact_email, AiCrawlers.contact_email())}
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
