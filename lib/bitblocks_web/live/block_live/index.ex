defmodule BitblocksWeb.BlockLive.Index do
  use BitblocksWeb, :live_view

  alias Bitblocks.Chain
  alias Bitblocks.Block

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :blocks, list_blocks())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Block")
    |> assign(:block, Chain.get_block!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Block")
    |> assign(:block, %Block{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Blocks")
    |> assign(:block, nil)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    block = Chain.get_block!(id)
    {:ok, _} = Chain.delete_block(block)

    {:noreply, assign(socket, :blocks, list_blocks())}
  end

  defp list_blocks do
    Chain.list_blocks()
  end
end
