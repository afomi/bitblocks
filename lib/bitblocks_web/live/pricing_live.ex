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
           "Bitblocks API pricing: start free, and pay for what you use as you grow.",
         canonical_path: "/pricing"
       )
     )}
  end
end
