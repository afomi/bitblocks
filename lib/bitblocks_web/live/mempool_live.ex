defmodule BitblocksWeb.MempoolLive do
  @moduledoc """
  Live-updating mempool status indicator.
  Polls the node every 10 seconds for unconfirmed transaction count and size.
  Designed to be embedded in other pages via live_render.
  """
  use BitblocksWeb, :live_view

  @poll_interval :timer.seconds(10)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      send(self(), :poll)
    end

    {:ok,
     assign(socket,
       tx_count: nil,
       bytes: nil,
       prev_count: nil,
       error: false
     )}
  end

  @impl true
  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_interval)

    case BitcoinsvCli.getmempoolinfo() do
      %{"size" => size, "bytes" => bytes} ->
        {:noreply,
         assign(socket,
           prev_count: socket.assigns.tx_count,
           tx_count: size,
           bytes: bytes,
           error: false
         )}

      _ ->
        {:noreply, assign(socket, error: true)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <%= if @error or (@tx_count != nil and @tx_count == 0) do %>
        <%!-- Hide entirely when mempool is empty or unavailable --%>
      <% else %>
        <span class={[
          "w-1.5 h-1.5 rounded-full",
          if(@tx_count && @tx_count > 0, do: "bg-green-500 animate-pulse", else: "bg-neutral-500")
        ]}>
        </span>
        <%= if @tx_count do %>
          <span class="font-mono text-xs text-neutral-400 tabular-nums">
            <span class={[
              "transition-all duration-300",
              direction_class(@tx_count, @prev_count)
            ]}>
              {@tx_count}
            </span>
            unconfirmed
          </span>
          <span class="font-mono text-xs text-neutral-500 tabular-nums">
            {format_bytes(@bytes)}
          </span>
        <% else %>
          <span class="font-mono text-xs text-neutral-500">
            loading…
          </span>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp direction_class(current, prev) when is_integer(current) and is_integer(prev) do
    cond do
      current > prev -> "text-green-400"
      current < prev -> "text-neutral-400"
      true -> "text-neutral-400"
    end
  end

  defp direction_class(_, _), do: "text-neutral-400"

  defp format_bytes(nil), do: ""
  defp format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
