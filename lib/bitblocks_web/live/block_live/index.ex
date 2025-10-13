defmodule BitblocksWeb.BlockLive.Index do
  use BitblocksWeb, :live_view

  alias Bitblocks.Chain
  alias Bitblocks.Chain.Block

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    page = String.to_integer(params["page"] || "1")
    per_page = 50

    socket =
      socket
      |> assign(:page, page)
      |> assign(:per_page, per_page)
      |> assign(:blocks, list_blocks(page, per_page))
      |> assign(:total_blocks, Chain.count_blocks())
      |> assign(:total_pages, calculate_total_pages(Chain.count_blocks(), per_page))

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

    {:noreply, assign(socket, :blocks, list_blocks(socket.assigns.page, socket.assigns.per_page))}
  end

  defp list_blocks(page, per_page) do
    Chain.list_blocks(page: page, per_page: per_page)
  end

  defp calculate_total_pages(total_count, per_page) do
    ceil(total_count / per_page)
  end

  defp format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(number), do: to_string(number)

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 2)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 2)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "0 B"

  defp format_timestamp(unix_timestamp) do
    datetime = DateTime.from_unix!(unix_timestamp)
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime)

    cond do
      diff_seconds < 60 ->
        "#{diff_seconds}s ago"

      diff_seconds < 3600 ->
        "#{div(diff_seconds, 60)}m ago"

      diff_seconds < 86400 ->
        "#{div(diff_seconds, 3600)}h ago"

      true ->
        Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
    end
  end
end
