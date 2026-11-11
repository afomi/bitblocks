defmodule BitblocksWeb.ReorgLive do
  use BitblocksWeb, :live_view

  alias BitblocksWeb.Seo

  @impl true
  def mount(_params, _session, socket) do
    seo =
      Seo.public_page(
        page_title: "Chain reorganizations",
        meta_description:
          "What a Bitcoin SV chain reorganization is, and what happens to the stale blocks and their transactions.",
        canonical_path: "/reorgs"
      )

    {:ok, assign(socket, seo)}
  end
end
