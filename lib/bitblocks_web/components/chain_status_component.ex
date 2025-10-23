defmodule BitblocksWeb.ChainStatusComponent do
  use Phoenix.Component

  def chain_status(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 mb-6">
      <%!-- RPC Node Status --%>
      <%= if assigns[:blockchain_info] do %>
        <div class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-4">
          <div class="flex items-center justify-between mb-3">
            <div class="text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide">
              RPC Node Status
            </div>
            <%= if @blockchain_info.blocks == @blockchain_info.headers do %>
              <span class="text-xs text-green-700 dark:text-green-400 font-semibold">
                ✓ Fully Synced
              </span>
            <% end %>
          </div>
          <div class="text-gray-600 dark:text-gray-300 space-y-2 text-xs">
            <div>
              Network:
              <%= for option <- ["test", "main"] do %>
                <%= if option == @blockchain_info.chain do %>
                  <span class="inline-flex items-center rounded-md bg-orange-50 dark:bg-orange-900 px-2 py-1 text-xs font-medium text-orange-700 dark:text-orange-300 ring-1 ring-inset ring-orange-600/20">
                    <%= @blockchain_info.chain %>
                  </span>
                <% else %>
                  <span class="inline-flex items-center rounded-md bg-gray-50 dark:bg-gray-700 px-2 py-1 text-xs font-medium text-gray-600 dark:text-gray-400 ring-1 ring-inset ring-gray-500/10">
                    <%= option %>
                  </span>
                <% end %>
              <% end %>
            </div>
            <div>
              Synced Blocks:
              <span class="font-semibold text-gray-900 dark:text-white text-sm">
                <%= format_number(@blockchain_info.blocks) %>
              </span>
            </div>
            <div>
              Total Blocks:
              <span class="font-semibold text-gray-900 dark:text-white text-sm">
                <%= format_number(@blockchain_info.headers) %>
              </span>
            </div>
            <div>
              Verification progress:
              <span class="font-semibold text-gray-900 dark:text-white text-sm">
                <%= (@blockchain_info.verificationprogress * 100) |> Decimal.from_float() |> Decimal.round(6) %>% verified
              </span>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- App Indexed Status --%>
      <%= if assigns[:blocks_count] do %>
        <div class="bg-blue-100 dark:bg-blue-900 border border-blue-300 dark:border-blue-700 rounded-lg px-4 py-2 w-full">
          <div class="flex flex-wrap items-center gap-4 text-xs">
            <div>
              <span class="font-medium text-gray-700 dark:text-gray-300">
                App Indexed:
              </span>
              <span class="ml-1 text-sm font-bold text-blue-600 dark:text-blue-400">
                <%= format_number(@blocks_count) %>
              </span>
              <span class="text-gray-600 dark:text-gray-400">
                blocks
              </span>
            </div>
            <%= if assigns[:transactions_count] do %>
              <div>
                <span class="ml-1 text-sm font-bold text-blue-600 dark:text-blue-400">
                  <%= format_number(@transactions_count) %>
                </span>
                <span class="text-gray-600 dark:text-gray-400">
                  txs
                </span>
              </div>
            <% end %>
            <%= if assigns[:latest_block] do %>
              <div>
                <span class="font-medium text-gray-700 dark:text-gray-300">
                  Latest:
                </span>
                <a
                  href={"/blocks/#{@latest_block.height}"}
                  class="ml-1 text-sm font-bold text-blue-600 dark:text-blue-400 hover:underline"
                >
                  #<%= format_number(@latest_block.height) %>
                </a>
              </div>
            <% end %>
            <%= if assigns[:time_ago_minutes] && assigns[:block_time] do %>
              <div>
                <span class="font-medium text-gray-700 dark:text-gray-300">
                  Last Block:
                </span>
                <span class="ml-1 text-sm font-semibold text-green-700 dark:text-green-400">
                  <%= @time_ago_minutes %> min ago
                </span>
                <span class="ml-1 text-gray-500 dark:text-gray-400">
                  <%= Calendar.strftime(@block_time, "%Y-%m-%d %H:%M UTC") %>
                </span>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
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

  defp format_number(number), do: to_string(number)
end
