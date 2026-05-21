defmodule BitblocksWeb.BlockSyncCardComponent do
  use Phoenix.Component

  @batch_size Application.compile_env(:bitblocks, :tx_fetch_batch_size, 100)

  attr :blocks, :list, required: true

  def block_sync_cards(assigns) do
    ~H"""
    <div
      :if={@blocks != []}
      class="space-y-3 mb-6"
    >
      <h2 class="text-lg font-semibold text-gray-900 dark:text-white">
        Syncing Blocks
      </h2>
      <div class="space-y-3">
        <.block_sync_card
          :for={block <- @blocks}
          block={block}
        />
      </div>
    </div>
    """
  end

  attr :block, :map, required: true

  def block_sync_card(assigns) do
    total = assigns.block.num_tx || 0
    downloaded = assigns.block.downloaded || 0
    downloading = min(@batch_size, max(total - downloaded, 0))
    pct_downloaded = if total > 0, do: Float.round(downloaded / total * 100, 1), else: 0
    pct_downloading = if total > 0, do: Float.round(downloading / total * 100, 1), else: 0
    syncing? = assigns.block.sync_state == "txs_syncing"

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:downloaded, downloaded)
      |> assign(:downloading, downloading)
      |> assign(:pct_downloaded, pct_downloaded)
      |> assign(:pct_downloading, pct_downloading)
      |> assign(:batch_size, @batch_size)
      |> assign(:syncing?, syncing?)

    ~H"""
    <div class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-5 border border-gray-200 dark:border-gray-700">
      <%!-- Header row: block height + tx counts --%>
      <div class="flex items-baseline justify-between mb-4">
        <div class="flex items-center gap-2">
          <a
            href={"/blocks/#{@block.height}"}
            class="text-lg font-semibold font-mono text-gray-900 dark:text-white hover:text-blue-600 dark:hover:text-blue-400"
          >
            Block <%= format_number(@block.height) %>
          </a>
          <span
            :if={@syncing?}
            class="inline-block w-2 h-2 rounded-full bg-blue-500 animate-pulse"
          >
          </span>
          <span
            :if={!@syncing?}
            class="text-xs px-1.5 py-0.5 rounded bg-amber-100 text-amber-700 dark:bg-amber-900/50 dark:text-amber-300"
          >
            queued
          </span>
        </div>
        <div class="text-sm text-gray-500 dark:text-gray-400">
          <span class="font-mono font-semibold text-gray-900 dark:text-white">
            <%= format_number(@downloaded) %>
          </span>
          /
          <span class="font-mono">
            <%= format_number(@total) %>
          </span>
          transaction IDs
        </div>
      </div>

      <%!-- Info row: batch size + created count --%>
      <div class="flex items-center justify-between mb-3 text-xs text-gray-500 dark:text-gray-400">
        <div>
          Syncing
          <span class="font-mono font-semibold text-gray-700 dark:text-gray-300">
            <%= @batch_size %>
          </span>
          at a time
        </div>
        <div>
          Transactions created:
          <span class="font-mono font-semibold text-green-600 dark:text-green-400">
            <%= format_number(@downloaded) %>
          </span>
        </div>
      </div>

      <%!-- Progress bars --%>
      <div class="space-y-2">
        <%!-- Downloaded (green) --%>
        <div class="flex items-center gap-3">
          <div class="flex-1 h-3 bg-gray-100 dark:bg-gray-700 rounded-full overflow-hidden">
            <div
              class="h-full bg-green-500 rounded-full transition-all duration-500 ease-out"
              style={"width: #{@pct_downloaded}%"}
            >
            </div>
          </div>
          <span class="text-xs font-mono text-green-600 dark:text-green-400 w-20 text-right">
            <%= @pct_downloaded %>% done
          </span>
        </div>

        <%!-- Downloading (blue, only when actively syncing) --%>
        <div
          :if={@syncing? && @downloading > 0}
          class="flex items-center gap-3"
        >
          <div class="flex-1 h-3 bg-gray-100 dark:bg-gray-700 rounded-full overflow-hidden">
            <div
              class="h-full bg-blue-400 rounded-full animate-pulse"
              style={"width: #{@pct_downloading}%"}
            >
            </div>
          </div>
          <span class="text-xs font-mono text-blue-500 dark:text-blue-400 w-20 text-right">
            +<%= @downloading %> fetching
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(number) when is_float(number), do: to_string(number)
  defp format_number(nil), do: "0"
  defp format_number(number), do: to_string(number)
end
