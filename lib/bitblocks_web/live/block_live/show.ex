defmodule BitblocksWeb.BlockLive.Show do
  use BitblocksWeb, :live_view

  alias Bitblocks.Chain

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :downloading, false)}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    block = Chain.get_block!(id)
    transactions_downloaded = Chain.block_transactions_downloaded?(block)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:block, block)
     |> assign(:transactions_downloaded, transactions_downloaded)}
  end

  @impl true
  def handle_event("download_transactions", _params, socket) do
    block = socket.assigns.block

    # Queue the job
    case Chain.queue_transaction_fetch(block) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:downloading, true)
         |> put_flash(:info, "Transaction download job queued for block #{block.height}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to queue job: #{inspect(reason)}")}
    end
  end

  defp page_title(:show), do: "Show Block"
  defp page_title(:edit), do: "Edit Block"

  defp format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  defp format_number(number), do: to_string(number)
end
