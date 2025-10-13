defmodule BitblocksWeb.RpcNodeStatusComponent do
  use Phoenix.Component

  def rpc_node_status(assigns) do
    ~H"""
    <%= if @chain_tip do %>
      <div class={[
        "rounded-lg px-4 py-2 border w-full",
        if(@chain_tip.synced,
          do: "bg-green-100 dark:bg-green-900 border-green-300 dark:border-green-700",
          else: "bg-yellow-100 dark:bg-yellow-900 border-yellow-300 dark:border-yellow-700"
        )
      ]}>
        <div class="flex flex-wrap items-center gap-4 text-xs">
          <div>
            <span class="font-medium text-gray-700 dark:text-gray-300">
              RPC Node:
            </span>
            <span class={[
              "ml-1 text-sm font-bold",
              if(@chain_tip.synced,
                do: "text-green-600 dark:text-green-400",
                else: "text-yellow-600 dark:text-yellow-400"
              )
            ]}>
              <%= format_number(@chain_tip.blocks) %>
            </span>
            <span class="text-gray-600 dark:text-gray-400">
              blocks
            </span>
          </div>
          <%= if not @chain_tip.synced do %>
            <div>
              <span class="font-medium text-gray-700 dark:text-gray-300">
                / Chain Tip:
              </span>
              <span class="ml-1 text-sm font-bold text-gray-600 dark:text-gray-400">
                <%= format_number(@chain_tip.headers) %>
              </span>
              <span class="ml-1 text-gray-600 dark:text-gray-400">
                (<%= Float.round(@chain_tip.verification_progress * 100, 2) %>% synced)
              </span>
            </div>
          <% else %>
            <span class="text-green-600 dark:text-green-400 font-semibold">
              ✓ Fully Synced
            </span>
          <% end %>
        </div>
      </div>
    <% else %>
      <div class="bg-red-100 dark:bg-red-900 border border-red-300 dark:border-red-700 rounded-lg px-4 py-2 w-full">
        <span class="text-xs font-medium text-red-700 dark:text-red-300">
          RPC Node: Unavailable
        </span>
      </div>
    <% end %>
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
