defmodule BitblocksWeb.PricingLive do
  use BitblocksWeb, :live_view

  alias BitblocksWeb.Seo

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(
       socket,
       Seo.public_page(
         page_title: "Pricing",
         meta_description:
           "Bitblocks API pricing — free tier for exploration, paid tiers for production use.",
         canonical_path: "/pricing"
       )
     )}
  end
end
