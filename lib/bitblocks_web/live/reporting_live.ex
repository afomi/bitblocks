defmodule BitblocksWeb.ReportingLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.{Repo, Chain}
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Reporting",
        chart_limit: 50000,
        chart_start: 0,
        chart_data: get_chart_data(0, 50000),
        total_blocks: Chain.count_blocks(),
        total_transactions: Repo.aggregate(Chain.Transaction, :count, :id)
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("update_chart", %{"start" => start_str, "limit" => limit_str}, socket) do
    start = String.to_integer(start_str)
    limit = String.to_integer(limit_str)

    {:noreply,
     socket
     |> assign(:chart_start, start)
     |> assign(:chart_limit, limit)
     |> assign(:chart_data, get_chart_data(start, limit))}
  end

  defp get_chart_data(start_height, limit) do
    # Get blocks with their transaction counts
    # For performance with large datasets, we use indexed queries
    query =
      from b in Chain.Block,
        where: b.height >= ^start_height,
        order_by: [asc: b.height],
        select: %{
          height: b.height,
          num_tx: b.num_tx
        },
        limit: ^limit

    Repo.all(query)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="container mx-auto px-4 py-8 max-w-7xl"
    >
      <h1
        class="text-4xl font-bold mb-6"
      >
        Blockchain Reporting
      </h1>

      <%!-- Stats Cards --%>
      <div
        class="grid grid-cols-2 gap-4 mb-8"
      >
        <div
          class="bg-white shadow-md rounded-lg p-6"
        >
          <div
            class="text-sm text-gray-600"
          >
            Total Blocks
          </div>
          <div
            class="text-3xl font-bold"
          >
            <%= @total_blocks |> format_number() %>
          </div>
        </div>

        <div
          class="bg-white shadow-md rounded-lg p-6"
        >
          <div
            class="text-sm text-gray-600"
          >
            Total Transactions
          </div>
          <div
            class="text-3xl font-bold"
          >
            <%= @total_transactions |> format_number() %>
          </div>
        </div>
      </div>

      <%!-- Transactions per Block Chart --%>
      <div
        class="bg-white shadow-md rounded-lg p-6"
      >
        <div
          class="flex items-center justify-between mb-4"
        >
          <h2
            class="text-2xl font-semibold"
          >
            Transactions per Block
          </h2>

          <form
            phx-change="update_chart"
            class="flex items-center gap-4"
          >
            <div
              class="flex items-center gap-2"
            >
              <label
                class="text-sm text-gray-600"
              >
                Start:
              </label>
              <input
                type="number"
                name="start"
                value={@chart_start}
                min="0"
                class="w-24 px-2 py-1 border border-gray-300 rounded text-sm"
              />
            </div>

            <div
              class="flex items-center gap-2"
            >
              <label
                class="text-sm text-gray-600"
              >
                Limit:
              </label>
              <select
                name="limit"
                class="px-2 py-1 border border-gray-300 rounded text-sm"
              >
                <option
                  value="100"
                  selected={@chart_limit == 100}
                >
                  100
                </option>
                <option
                  value="1000"
                  selected={@chart_limit == 1000}
                >
                  1K
                </option>
                <option
                  value="5000"
                  selected={@chart_limit == 5000}
                >
                  5K
                </option>
                <option
                  value="10000"
                  selected={@chart_limit == 10000}
                >
                  10K
                </option>
                <option
                  value="50000"
                  selected={@chart_limit == 50000}
                >
                  50K
                </option>
                <option
                  value="100000"
                  selected={@chart_limit == 100000}
                >
                  100K
                </option>
              </select>
            </div>
          </form>
        </div>

        <div
          class="text-sm text-gray-600 mb-4"
        >
          Showing blocks <%= @chart_start %> to <%= @chart_start + length(@chart_data) - 1 %> (<%= length(@chart_data) |> format_number() %> blocks)
        </div>

        <canvas
          id="txChart"
          phx-hook="TxChart"
          data-chart-data={Jason.encode!(@chart_data)}
          class="w-full"
          style="max-height: 400px;"
        >
        </canvas>

        <div
          class="mt-4 p-4 bg-blue-50 rounded"
        >
          <h3
            class="font-semibold text-blue-900 mb-2"
          >
            💡 Performance Notes
          </h3>
          <ul
            class="text-sm text-blue-800 space-y-1"
          >
            <li>
              • Currently showing up to 100K blocks using indexed queries
            </li>
            <li>
              • For 900K+ blocks, consider: aggregated views, materialized views, or time-based bucketing
            </li>
            <li>
              • Projection tables could pre-calculate daily/weekly/monthly stats
            </li>
            <li>
              • Chart rendering optimized with point radius = 0 (no individual dots)
            </li>
          </ul>
        </div>
      </div>

      <%!-- Info --%>
      <div
        class="mt-6 text-sm text-gray-600"
      >
        <p>
          This chart shows the number of transactions per block. Spikes indicate blocks with high transaction volume.
        </p>
      </div>

      <%!-- Ideas for Reports --%>
      <div
        class="mt-8 bg-blue-50 border border-blue-200 rounded-lg p-6"
      >
        <h2
          class="text-2xl font-semibold mb-4 text-blue-900"
        >
          Ideas for Future Reports
        </h2>

        <p
          class="text-sm text-gray-700 mb-4"
        >
          Have an idea for a report? <a
            href="https://github.com/yourusername/bitblocks/issues/new"
            target="_blank"
            class="text-blue-600 hover:underline font-semibold"
          >Submit a GitHub issue</a> with your suggestion!
        </p>

        <ul
          class="space-y-2 text-gray-700"
        >
          <li
            class="flex items-start"
          >
            <span
              class="text-blue-600 mr-2"
            >
              •
            </span>
            <span>
              <strong>Average Transaction Size</strong> - Per block and overall average in bytes
            </span>
          </li>

          <li
            class="flex items-start"
          >
            <span
              class="text-blue-600 mr-2"
            >
              •
            </span>
            <span>
              <strong>Transaction Types</strong> - Count and distribution of different transaction types
            </span>
          </li>

          <li
            class="flex items-start"
          >
            <span
              class="text-blue-600 mr-2"
            >
              •
            </span>
            <span>
              <strong>Min Transaction Size</strong> - Smallest transaction per block and overall
            </span>
          </li>

          <li
            class="flex items-start"
          >
            <span
              class="text-blue-600 mr-2"
            >
              •
            </span>
            <span>
              <strong>Max Transaction Size</strong> - Largest transaction per block and overall
            </span>
          </li>

          <li
            class="flex items-start"
          >
            <span
              class="text-blue-600 mr-2"
            >
              •
            </span>
            <span>
              <strong>Block Size Over Time</strong> - Trend of block sizes throughout the chain
            </span>
          </li>

          <li
            class="flex items-start"
          >
            <span
              class="text-blue-600 mr-2"
            >
              •
            </span>
            <span>
              <strong>Transaction Fee Analysis</strong> - Distribution and trends of transaction fees
            </span>
          </li>

          <li
            class="flex items-start"
          >
            <span
              class="text-blue-600 mr-2"
            >
              •
            </span>
            <span>
              <strong>Block Mining Time</strong> - Time between blocks and difficulty adjustments
            </span>
          </li>

          <li
            class="flex items-start"
          >
            <span
              class="text-blue-600 mr-2"
            >
              •
            </span>
            <span>
              <strong>UTXO Set Growth</strong> - How the unspent transaction output set grows over time
            </span>
          </li>
        </ul>
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

  defp format_number(number), do: to_string(number)
end
