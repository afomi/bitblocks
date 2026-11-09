defmodule BitblocksWeb.FactsLive do
  @moduledoc """
  `/facts`: what the chain doesn't announce (#70). Miner rewards left
  unclaimed, sats burned, and a supply audit, each through a stated block,
  from the cache in `Bitblocks.Facts`.
  """
  use BitblocksWeb, :live_view

  alias Bitblocks.Facts
  alias BitblocksWeb.Seo

  import BitblocksWeb.Sats, only: [bsv: 1, sats: 1, delimit: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       Seo.public_page(
         page_title: "Chain facts: unclaimed rewards, burned sats, supply",
         meta_description:
           "What the Bitcoin SV chain doesn't announce: miner rewards left unclaimed, sats burned, and a supply audit, each verified through a stated block.",
         canonical_path: "/facts"
       )
     )
     |> assign(:facts, Facts.get())
     |> assign(:unspendable_coinbases, Facts.unspendable_coinbases())}
  end
end
