defmodule BitblocksWeb.CollectionLive.Show do
  @moduledoc """
  `/collections/:id`: a collection's items in mint order, by slug or origin
  outpoint. Rexxies have their own page (`BitblocksWeb.RexxiesLive`), so any
  address but a collection's own redirects there.
  """
  use BitblocksWeb, :live_view

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

        {:ok, socket |> assign(seo) |> assign(:collection, collection)}
    end
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{collection: collection}} = socket) do
    cursor = parse_cursor(params["cursor"])
    page = OrdinalCollections.list_items(collection.id, cursor: cursor, limit: @per_page)

    {:noreply,
     socket
     |> assign(:cursor, cursor)
     |> assign(:items, page.items)
     |> assign(:next_cursor, page.next_cursor)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp parse_cursor(nil), do: nil

  defp parse_cursor(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  @doc false
  def image?(%{content_type: "image/" <> _}), do: true
  def image?(_item), do: false
end
