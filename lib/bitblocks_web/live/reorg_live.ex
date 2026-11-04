defmodule BitblocksWeb.ReorgLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.Reorgs
  alias BitblocksWeb.Seo

  @impl true
  def mount(_params, _session, socket) do
    seo =
      Seo.public_page(
        page_title: "Chain reorganizations",
        meta_description:
          "Reorganizations Bitblocks has seen on Bitcoin SV, as annotations at the height where the node tip and this index disagreed.",
        canonical_path: "/reorgs"
      )

    reorgs = Reorgs.list_reorgs()

    {:ok,
     socket
     |> assign(seo)
     |> assign(reorgs: reorgs, resolved_later: Reorgs.resolved_later(reorgs))}
  end

  @doc false
  def annotation_time(%{detected_at: %DateTime{} = detected_at}) do
    Calendar.strftime(detected_at, "%Y-%m-%d %H:%M UTC")
  end
end
