defmodule BitblocksWeb.RpcAdminLive do
  use BitblocksWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    # Get the blockchain info events
    events = Bitblocks.RpcCache.get_blockchain_info_events(limit: 100)

    socket =
      socket
      |> assign(page_title: "RPC Admin - getblockchaininfo Events")
      |> assign(events: events)
      |> assign(limit: 100)

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    events = Bitblocks.RpcCache.get_blockchain_info_events(limit: socket.assigns.limit)
    {:noreply, assign(socket, events: events)}
  end

  @impl true
  def handle_event("update_limit", %{"limit" => limit_str}, socket) do
    limit = String.to_integer(limit_str)
    events = Bitblocks.RpcCache.get_blockchain_info_events(limit: limit)

    socket =
      socket
      |> assign(events: events)
      |> assign(limit: limit)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="container mx-auto px-4 py-8"
    >
      <div
        class="mb-6"
      >
        <h1
          class="text-3xl font-bold text-gray-900 dark:text-white mb-2"
        >
          RPC Admin
        </h1>
        <p
          class="text-gray-600 dark:text-gray-400"
        >
          Monitor getblockchaininfo RPC calls and cache performance
        </p>
      </div>

      <%!-- Controls --%>
      <div
        class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6 mb-6"
      >
        <div
          class="flex items-center gap-4"
        >
          <button
            phx-click="refresh"
            class="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
          >
            Refresh
          </button>

          <div
            class="flex items-center gap-2"
          >
            <label
              for="limit"
              class="text-sm text-gray-700 dark:text-gray-300"
            >
              Limit:
            </label>
            <select
              id="limit"
              name="limit"
              phx-change="update_limit"
              class="px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
            >
              <option
                value="10"
                selected={@limit == 10}
              >
                10
              </option>
              <option
                value="50"
                selected={@limit == 50}
              >
                50
              </option>
              <option
                value="100"
                selected={@limit == 100}
              >
                100
              </option>
              <option
                value="500"
                selected={@limit == 500}
              >
                500
              </option>
              <option
                value="1000"
                selected={@limit == 1000}
              >
                1000
              </option>
            </select>
          </div>

          <div
            class="ml-auto text-sm text-gray-600 dark:text-gray-400"
          >
            Showing <%= length(@events) %> events
          </div>
        </div>
      </div>

      <%!-- Stats Summary --%>
      <div
        class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-6"
      >
        <div
          class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6"
        >
          <div
            class="text-sm text-gray-600 dark:text-gray-400 mb-1"
          >
            Total Calls
          </div>
          <div
            class="text-2xl font-bold text-gray-900 dark:text-white"
          >
            <%= length(@events) %>
          </div>
        </div>

        <div
          class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6"
        >
          <div
            class="text-sm text-gray-600 dark:text-gray-400 mb-1"
          >
            Success Rate
          </div>
          <div
            class="text-2xl font-bold text-green-600"
          >
            <%= success_rate(@events) %>%
          </div>
        </div>

        <div
          class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6"
        >
          <div
            class="text-sm text-gray-600 dark:text-gray-400 mb-1"
          >
            Avg Duration
          </div>
          <div
            class="text-2xl font-bold text-blue-600"
          >
            <%= avg_duration(@events) %>ms
          </div>
        </div>

        <div
          class="bg-white dark:bg-gray-800 shadow-md rounded-lg p-6"
        >
          <div
            class="text-sm text-gray-600 dark:text-gray-400 mb-1"
          >
            Current Height
          </div>
          <div
            class="text-2xl font-bold text-purple-600"
          >
            <%= current_height(@events) %>
          </div>
        </div>
      </div>

      <%!-- Events Table --%>
      <div
        class="bg-white dark:bg-gray-800 shadow-md rounded-lg overflow-hidden"
      >
        <div
          class="overflow-x-auto"
        >
          <table
            class="min-w-full divide-y divide-gray-200 dark:divide-gray-700"
          >
            <thead
              class="bg-gray-50 dark:bg-gray-900"
            >
              <tr>
                <th
                  class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                >
                  ID
                </th>
                <th
                  class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                >
                  Timestamp
                </th>
                <th
                  class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                >
                  Duration
                </th>
                <th
                  class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                >
                  Status
                </th>
                <th
                  class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                >
                  Blocks
                </th>
                <th
                  class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                >
                  Headers
                </th>
                <th
                  class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                >
                  Chain
                </th>
                <th
                  class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider"
                >
                  Best Block Hash
                </th>
              </tr>
            </thead>
            <tbody
              class="bg-white dark:bg-gray-800 divide-y divide-gray-200 dark:divide-gray-700"
            >
              <%= for event <- @events do %>
                <tr
                  class="hover:bg-gray-50 dark:hover:bg-gray-700"
                >
                  <td
                    class="px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100"
                  >
                    <%= event.id %>
                  </td>
                  <td
                    class="px-6 py-4 whitespace-nowrap text-sm text-gray-500 dark:text-gray-400"
                  >
                    <%= format_datetime(event.datetime) %>
                  </td>
                  <td
                    class="px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100"
                  >
                    <%= event.duration_ms %>ms
                  </td>
                  <td
                    class="px-6 py-4 whitespace-nowrap"
                  >
                    <%= if event.success do %>
                      <span
                        class="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200"
                      >
                        Success
                      </span>
                    <% else %>
                      <span
                        class="px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200"
                      >
                        Failed
                      </span>
                    <% end %>
                  </td>
                  <td
                    class="px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100"
                  >
                    <%= event.blocks %>
                  </td>
                  <td
                    class="px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100"
                  >
                    <%= event.headers %>
                  </td>
                  <td
                    class="px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100"
                  >
                    <%= event.chain %>
                  </td>
                  <td
                    class="px-6 py-4 whitespace-nowrap text-sm text-gray-500 dark:text-gray-400 font-mono"
                  >
                    <%= truncate_hash(event.bestblockhash) %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions

  defp success_rate([]), do: 0

  defp success_rate(events) do
    successful = Enum.count(events, & &1.success)
    total = length(events)
    Float.round(successful / total * 100, 1)
  end

  defp avg_duration([]), do: 0

  defp avg_duration(events) do
    total = Enum.reduce(events, 0, fn event, acc -> acc + event.duration_ms end)
    Float.round(total / length(events), 1)
  end

  defp current_height([]), do: "N/A"

  defp current_height(events) do
    case List.first(events) do
      nil -> "N/A"
      event -> event.blocks || "N/A"
    end
  end

  defp format_datetime(datetime_str) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, dt, _offset} ->
        Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

      _ ->
        datetime_str
    end
  end

  defp truncate_hash(nil), do: "N/A"

  defp truncate_hash(hash) when is_binary(hash) do
    if String.length(hash) > 16 do
      String.slice(hash, 0, 8) <> "..." <> String.slice(hash, -8, 8)
    else
      hash
    end
  end
end
