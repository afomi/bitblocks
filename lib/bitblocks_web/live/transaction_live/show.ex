defmodule BitblocksWeb.TransactionLive.Show do
  use BitblocksWeb, :live_view

  alias Bitblocks.Chain

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:transaction, Chain.get_transaction!(id))}
  end

  defp page_title(:show), do: "Show Block"
  defp page_title(:edit), do: "Edit Block"
end
