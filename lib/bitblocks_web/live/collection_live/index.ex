defmodule BitblocksWeb.CollectionLive.Index do
  @moduledoc """
  `/collections`: every BSV NFT collection we index, with search and a source
  filter (both in the URL), and the platforms collections come from.
  """
  use BitblocksWeb, :live_view

  import BitblocksWeb.CollectionComponents

  alias Bitblocks.OrdinalCollections
  alias BitblocksWeb.Seo

  @impl true
  def mount(_params, _session, socket) do
    seo =
      Seo.public_page(
        page_title: "BSV NFT collections",
        meta_description:
          "Browse Bitcoin SV NFT collections with membership proven on chain and holders traced through spends.",
        canonical_path: "/collections"
      )

    collections = OrdinalCollections.list_collections()

    {:ok,
     socket
     |> assign(seo)
     |> assign(:collections, collections)
     |> assign(:sources, OrdinalCollections.sources())
     |> assign(
       :filter_sources,
       collections |> Enum.map(& &1.source) |> Enum.uniq() |> Enum.sort()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    q = params["q"] || ""
    source = params["source"] || ""

    {:noreply,
     socket
     |> assign(:q, q)
     |> assign(:source, source)
     |> assign(:shown, filter(socket.assigns.collections, q, source))}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: index_path(q, socket.assigns.source))}
  end

  defp filter(collections, q, source) do
    needle = q |> String.trim() |> String.downcase()

    Enum.filter(collections, fn collection ->
      (source == "" or collection.source == source) and
        (needle == "" or
           Enum.any?(
             [collection.name, collection.id, collection.standard, collection.source],
             &(&1 && String.contains?(String.downcase(&1), needle))
           ))
    end)
  end

  @doc false
  def index_path(q, source) do
    params = [q: q, source: source] |> Enum.reject(fn {_key, value} -> value == "" end)
    ~p"/collections?#{params}"
  end

  @doc false
  def item_count(1), do: "1 item"
  def item_count(n), do: "#{n} items"
end
