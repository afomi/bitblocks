defmodule BitblocksWeb.ElectionLive.Index do
  @moduledoc """
  `/elections`: open an election by the outpoint of its record.
  Bitblocks reads the chain and does not cast a vote.
  """
  use BitblocksWeb, :live_view

  alias BitblocksWeb.ElectionCount
  alias BitblocksWeb.Seo

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       Seo.public_page(
         page_title: "Elections",
         meta_description:
           "Open an election by its record's outpoint. Bitblocks reads the chain and does not cast a vote.",
         canonical_path: "/elections"
       )
     )
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("open", params, socket) do
    outpoint = params |> Map.get("outpoint", "") |> String.trim()

    if outpoint == "" do
      {:noreply, assign(socket, :error, ElectionCount.message(:invalid_outpoint))}
    else
      {:noreply, push_navigate(socket, to: ~p"/elections/#{outpoint}")}
    end
  end
end
