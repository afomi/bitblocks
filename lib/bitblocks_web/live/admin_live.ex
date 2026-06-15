defmodule BitblocksWeb.AdminLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.StatsCache

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Admin",
       blocks_count: StatsCache.blocks_count(),
       transactions_count: StatsCache.transactions_count()
     )}
  end

  attr :href, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true

  def admin_card(assigns) do
    ~H"""
    <a
      href={@href}
      class="block rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-5 hover:border-orange-400 hover:shadow-sm transition-all"
    >
      <div class="font-semibold text-gray-900 dark:text-white mb-1">
        <%= @title %>
      </div>
      <div class="text-sm text-gray-500 dark:text-gray-400">
        <%= @description %>
      </div>
    </a>
    """
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)
end
