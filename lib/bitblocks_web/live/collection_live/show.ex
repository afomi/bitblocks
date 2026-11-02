defmodule BitblocksWeb.CollectionLive.Show do
  @moduledoc """
  `/collections/:id`: one collection, by slug or origin outpoint. The same view
  for every collection: stats, search, trait filters and items, all from the
  index. Search, filter and page live in the URL.
  """
  use BitblocksWeb, :live_view

  import BitblocksWeb.CollectionComponents

  alias Bitblocks.OrdinalCollections
  alias BitblocksWeb.Seo

  @per_page 50

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case OrdinalCollections.get_collection(id) do
      nil ->
        raise Ecto.NoResultsError, queryable: OrdinalCollections.Item

      %{slug: slug} when slug != id ->
        {:ok, push_navigate(socket, to: ~p"/collections/#{slug}")}

      collection ->
        seo =
          Seo.public_page(
            page_title: "#{collection.name} collection",
            meta_description:
              collection.description || "Items and traced holders of a BSV NFT collection.",
            canonical_path: "/collections/#{collection.slug}"
          )

        {:ok,
         socket
         |> assign(seo)
         |> assign(:collection, collection)
         |> assign(:stats, OrdinalCollections.stats(collection.id))
         |> assign(:per_page, @per_page)
         |> assign(:selected, nil)}
    end
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{collection: collection}} = socket) do
    page = parse_page(params["page"])
    search = params["q"] || ""
    trait_type = params["trait_type"] || ""
    trait_value = params["trait_value"] || ""
    trait = if trait_type != "" and trait_value != "", do: {trait_type, trait_value}

    {items, total} =
      OrdinalCollections.browse_items(
        collection.id,
        page: page,
        per_page: @per_page,
        q: search,
        trait: trait
      )

    {:noreply,
     assign(
       socket,
       page: page,
       search: search,
       trait_type: trait_type,
       trait_value: trait_value,
       items: items,
       layers: OrdinalCollections.layers(items),
       total: total,
       selected: nil
     )}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    params = if q == "", do: [], else: [q: q]

    {:noreply,
     push_patch(socket, to: ~p"/collections/#{socket.assigns.collection.slug}?#{params}")}
  end

  def handle_event("select_item", %{"id" => id}, socket) do
    selected = Enum.find(socket.assigns.items, &(to_string(&1.id) == id))
    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, :selected, nil)}
  end

  defp parse_page(nil), do: 1

  defp parse_page(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp page_path(assigns, page) do
    params =
      [
        q: assigns.search,
        trait_type: assigns.trait_type,
        trait_value: assigns.trait_value,
        page: page
      ]
      |> Enum.reject(fn {_key, value} -> value in ["", 1] end)

    ~p"/collections/#{assigns.collection.slug}?#{params}"
  end

  defp trait_path(collection, trait) do
    ~p"/collections/#{collection.slug}?#{[trait_type: trait["name"], trait_value: trait["value"]]}"
  end

  @doc false
  def subtitle(item) do
    case item.traits do
      [%{"value" => value} | _] -> value
      _ -> nil
    end
  end
end
