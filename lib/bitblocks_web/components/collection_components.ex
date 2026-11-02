defmodule BitblocksWeb.CollectionComponents do
  @moduledoc "Markup shared by the collections index and show pages."
  use Phoenix.Component

  @doc "The page frame every collections page sits in."
  slot :inner_block, required: true

  def collection_page(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-7xl">
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc "A pill naming a collection's standard, or anything like it."
  slot :inner_block, required: true

  def pill(assigns) do
    ~H"""
    <span class="shrink-0 px-3 py-1 bg-pink-100 text-pink-800 rounded-full text-sm font-semibold">
      <%= render_slot(@inner_block) %>
    </span>
    """
  end

  @doc "A white card."
  attr :id, :string, default: nil
  attr :class, :string, default: "p-4"
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <div
      id={@id}
      class={["bg-white shadow rounded-lg", @class]}
    >
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc "A labelled figure."
  attr :label, :string, required: true
  attr :value, :any, required: true

  def stat(assigns) do
    ~H"""
    <.panel>
      <div class="text-sm text-gray-500">
        <%= @label %>
      </div>
      <div class="text-2xl font-bold">
        <%= @value %>
      </div>
    </.panel>
    """
  end

  @doc """
  An item's picture: its layers stacked bottom first, or its one image. The
  parent sizes the frame; `layers` comes from `OrdinalCollections.layers/1`.
  """
  attr :item, :map, required: true
  attr :layers, :list, default: []
  attr :loading, :string, default: "lazy"

  def item_art(assigns) do
    ~H"""
    <div
      :if={@layers != []}
      class="relative w-full h-full"
    >
      <img
        :for={{layer, index} <- Enum.with_index(@layers)}
        src={layer}
        alt={if index == 0, do: @item.name || @item.origin, else: ""}
        loading={@loading}
        class="absolute inset-0 w-full h-full object-contain"
      />
    </div>
    <img
      :if={@layers == [] && Bitblocks.OrdinalCollections.image_path(@item)}
      src={Bitblocks.OrdinalCollections.image_path(@item)}
      alt={@item.name || @item.origin}
      loading={@loading}
      class="w-full h-full object-cover"
    />
    """
  end

  @doc "The search field and button, in a form the parent names."
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :placeholder, :string, required: true
  attr :label, :string, required: true
  attr :rest, :global, include: ~w(phx-change phx-submit)

  def search_form(assigns) do
    ~H"""
    <form
      id={@id}
      class="flex items-center gap-2 flex-1 min-w-[200px]"
      {@rest}
    >
      <input
        type="text"
        name="q"
        value={@value}
        placeholder={@placeholder}
        aria-label={@label}
        phx-debounce="200"
        class="flex-1 px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-pink-500 text-sm"
      />
      <button
        type="submit"
        class="px-4 py-2 bg-pink-600 text-white rounded-md hover:bg-pink-700 text-sm"
      >
        Search
      </button>
    </form>
    """
  end
end
