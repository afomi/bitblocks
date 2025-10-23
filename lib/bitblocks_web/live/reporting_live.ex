defmodule BitblocksWeb.ReportingLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.{Repo, Chain}
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    chart_data = get_chart_data(0, 50000)
    block_time_data = get_block_time_data(0, 50000)
    block_size_data = get_block_size_data(0, 50000)

    socket =
      assign(socket,
        page_title: "Reporting",
        chart_limit: 50000,
        chart_start: 0,
        chart_data: chart_data,
        block_time_data: block_time_data,
        block_size_data: block_size_data,
        total_blocks: Chain.count_blocks(),
        total_transactions: Repo.aggregate(Chain.Transaction, :count, :id),
        chart_stats: calculate_chart_stats(chart_data)
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("update_chart", %{"start" => start_str, "limit" => limit_str}, socket) do
    start = String.to_integer(start_str)
    limit = String.to_integer(limit_str)
    chart_data = get_chart_data(start, limit)
    block_time_data = get_block_time_data(start, limit)
    block_size_data = get_block_size_data(start, limit)

    {:noreply,
     socket
     |> assign(:chart_start, start)
     |> assign(:chart_limit, limit)
     |> assign(:chart_data, chart_data)
     |> assign(:block_time_data, block_time_data)
     |> assign(:block_size_data, block_size_data)
     |> assign(:chart_stats, calculate_chart_stats(chart_data))}
  end

  defp get_chart_data(start_height, limit) do
    # Get blocks with their transaction counts and satoshi totals
    # Use the new input_count and output_count columns for performance
    # If those columns don't have data yet, fall back to decoding

    query =
      from b in Chain.Block,
        left_join: t in Chain.Transaction,
        on: t.block_height == b.height,
        where: b.height >= ^start_height,
        group_by: [b.height, b.num_tx],
        order_by: [asc: b.height],
        select: %{
          height: b.height,
          num_tx: b.num_tx,
          total_inputs: coalesce(sum(t.total_input_satoshis), 0),
          total_outputs: coalesce(sum(t.total_output_satoshis), 0),
          input_count: coalesce(sum(t.input_count), 0),
          output_count: coalesce(sum(t.output_count), 0)
        },
        limit: ^limit

    Repo.all(query)
    |> Enum.map(fn block ->
      # Convert Decimal values to integers for arithmetic
      total_inputs = to_integer(block.total_inputs)
      total_outputs = to_integer(block.total_outputs)

      %{
        height: block.height,
        num_tx: block.num_tx,
        input_count: to_integer(block.input_count),
        output_count: to_integer(block.output_count),
        total_inputs: total_inputs,
        total_outputs: total_outputs,
        miner_fees: total_inputs - total_outputs
      }
    end)
  end

  defp get_block_time_data(start_height, limit) do
    # Get blocks with their timestamps to calculate time differences
    # Only include blocks where the previous block exists to avoid large gaps
    query =
      from b in Chain.Block,
        inner_join: prev in Chain.Block,
        on: prev.height == b.height - 1,
        where: b.height >= ^start_height and b.height > 0,
        order_by: [asc: b.height],
        select: %{
          height: b.height,
          time: b.time,
          prev_time: prev.time
        },
        limit: ^limit

    Repo.all(query)
    |> Enum.map(fn block ->
      time_diff_seconds = block.time - block.prev_time

      # Cap unrealistic values (e.g., if there are timestamp issues)
      # Bitcoin blocks should never take more than a few hours
      time_diff_minutes =
        cond do
          time_diff_seconds < 0 ->
            # Negative time difference (clock skew or out of order)
            0.0

          time_diff_seconds > 7200 ->
            # More than 2 hours - likely a data issue, cap it
            120.0

          true ->
            time_diff_seconds / 60.0
        end

      %{
        height: block.height,
        time_diff_minutes: time_diff_minutes
      }
    end)
  end

  defp get_block_size_data(start_height, limit) do
    # Get block sizes
    query =
      from b in Chain.Block,
        where: b.height >= ^start_height,
        order_by: [asc: b.height],
        select: %{
          height: b.height,
          size: b.size
        },
        limit: ^limit

    Repo.all(query)
    |> Enum.map(fn block ->
      # Convert bytes to megabytes, handling Decimal types
      size_bytes = to_integer(block.size)
      size_mb = size_bytes / (1024.0 * 1024.0)

      %{
        height: block.height,
        size_mb: size_mb
      }
    end)
  end

  defp calculate_chart_stats(chart_data) do
    if Enum.empty?(chart_data) do
      %{
        total_inputs: 0,
        total_outputs: 0,
        total_satoshis_in: 0,
        total_satoshis_out: 0
      }
    else
      Enum.reduce(
        chart_data,
        %{total_inputs: 0, total_outputs: 0, total_satoshis_in: 0, total_satoshis_out: 0},
        fn block, acc ->
          %{
            total_inputs: acc.total_inputs + to_integer(block.input_count),
            total_outputs: acc.total_outputs + to_integer(block.output_count),
            total_satoshis_in: acc.total_satoshis_in + to_integer(block.total_inputs),
            total_satoshis_out: acc.total_satoshis_out + to_integer(block.total_outputs)
          }
        end
      )
    end
  end

  defp to_integer(nil), do: 0
  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_integer(value) when is_float(value), do: trunc(value)
  defp to_integer(_), do: 0

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
        class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8"
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

        <div
          class="bg-white shadow-md rounded-lg p-6"
        >
          <div
            class="text-sm text-gray-600"
          >
            Total Inputs (Range)
          </div>
          <div
            class="text-3xl font-bold"
          >
            <%= @chart_stats.total_inputs |> format_number() %>
          </div>
        </div>

        <div
          class="bg-white shadow-md rounded-lg p-6"
        >
          <div
            class="text-sm text-gray-600"
          >
            Total Outputs (Range)
          </div>
          <div
            class="text-3xl font-bold"
          >
            <%= @chart_stats.total_outputs |> format_number() %>
          </div>
        </div>
      </div>

      <%!-- Satoshi Stats Cards --%>
      <div
        class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-8"
      >
        <div
          class="bg-blue-50 shadow-md rounded-lg p-6"
        >
          <div
            class="text-sm text-blue-600 font-semibold"
          >
            Total Input Satoshis (Range)
          </div>
          <div
            class="text-3xl font-bold text-blue-900"
          >
            <%= @chart_stats.total_satoshis_in |> format_number() %>
          </div>
          <div
            class="text-xs text-blue-600 mt-1"
          >
            <%= format_bsv(@chart_stats.total_satoshis_in) %> BSV
          </div>
        </div>

        <div
          class="bg-green-50 shadow-md rounded-lg p-6"
        >
          <div
            class="text-sm text-green-600 font-semibold"
          >
            Total Output Satoshis (Range)
          </div>
          <div
            class="text-3xl font-bold text-green-900"
          >
            <%= @chart_stats.total_satoshis_out |> format_number() %>
          </div>
          <div
            class="text-xs text-green-600 mt-1"
          >
            <%= format_bsv(@chart_stats.total_satoshis_out) %> BSV
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

      <%!-- Inputs/Outputs per Block Chart --%>
      <div
        class="bg-white shadow-md rounded-lg p-6 mt-8"
      >
        <h2
          class="text-2xl font-semibold mb-4"
        >
          Inputs & Outputs per Block
        </h2>

        <div
          class="text-sm text-gray-600 mb-4"
        >
          This chart shows the number of transaction inputs (blue) and outputs (green) per block.
        </div>

        <%= if @chart_stats.total_inputs == 0 and @chart_stats.total_outputs == 0 do %>
          <div
            class="p-8 bg-yellow-50 border-2 border-yellow-200 rounded-lg text-center"
          >
            <div
              class="text-4xl mb-4"
            >
              📊
            </div>
            <h3
              class="text-xl font-semibold text-yellow-900 mb-2"
            >
              No Transaction Data Available
            </h3>
            <p
              class="text-sm text-yellow-800 mb-4"
            >
              Blocks are in the database, but transaction details haven't been synced yet. To populate this chart, sync transaction data using:
            </p>
            <pre
              class="bg-yellow-100 text-yellow-900 p-3 rounded text-xs text-left"
            ><code>iex -S mix phx.server
              Bitblocks.Sync.get(block_height)</code></pre>
          </div>
        <% else %>
          <canvas
            id="ioChart"
            phx-hook="IOChart"
            data-chart-data={Jason.encode!(@chart_data)}
            class="w-full"
            style="max-height: 400px;"
          >
          </canvas>
        <% end %>
      </div>

      <%!-- Satoshi Flow Chart --%>
      <div
        class="bg-white shadow-md rounded-lg p-6 mt-8"
      >
        <h2
          class="text-2xl font-semibold mb-4"
        >
          Satoshi Flow & Miner Fees
        </h2>

        <div
          class="text-sm text-gray-600 mb-4"
        >
          This chart shows the total satoshis flowing through each block. The difference between inputs and outputs represents miner fees collected.
        </div>

        <%= if @chart_stats.total_satoshis_in == 0 and @chart_stats.total_satoshis_out == 0 do %>
          <div
            class="p-8 bg-yellow-50 border-2 border-yellow-200 rounded-lg text-center"
          >
            <div
              class="text-4xl mb-4"
            >
              💰
            </div>
            <h3
              class="text-xl font-semibold text-yellow-900 mb-2"
            >
              No Transaction Data Available
            </h3>
            <p
              class="text-sm text-yellow-800 mb-4"
            >
              Blocks are in the database, but transaction details haven't been synced yet. To populate this chart, sync transaction data using:
            </p>
            <pre
              class="bg-yellow-100 text-yellow-900 p-3 rounded text-xs text-left"
            ><code>iex -S mix phx.server
              Bitblocks.Sync.get(block_height)</code></pre>
          </div>
        <% else %>
          <canvas
            id="satoshiFlowChart"
            phx-hook="SatoshiFlowChart"
            data-chart-data={Jason.encode!(@chart_data)}
            class="w-full"
            style="max-height: 400px;"
          >
          </canvas>

          <div
            class="mt-4 p-4 bg-yellow-50 rounded"
          >
            <h3
              class="font-semibold text-yellow-900 mb-2"
            >
              💰 About Miner Fees
            </h3>
            <p
              class="text-sm text-yellow-800"
            >
              Miner fees = Total Input Satoshis - Total Output Satoshis. This represents the reward miners receive for including transactions in blocks, in addition to the block subsidy.
            </p>
          </div>
        <% end %>
      </div>

      <%!-- Block Time Variance Chart --%>
      <div
        class="bg-white shadow-md rounded-lg p-6 mt-8"
      >
        <h2
          class="text-2xl font-semibold mb-4"
        >
          Block Time Variance
        </h2>

        <div
          class="text-sm text-gray-600 mb-4"
        >
          This chart shows how long it took to mine each block compared to the 10-minute target.
          <div
            class="mt-2 flex flex-wrap gap-4"
          >
            <div
              class="flex items-center gap-2"
            >
              <div
                class="w-4 h-4 bg-green-500 rounded"
              >
              </div>
              <span>
                Near Target (±2 min)
              </span>
            </div>
            <div
              class="flex items-center gap-2"
            >
              <div
                class="w-4 h-4 bg-blue-500 rounded"
              >
              </div>
              <span>
                Faster (&lt;8 min)
              </span>
            </div>
            <div
              class="flex items-center gap-2"
            >
              <div
                class="w-4 h-4 bg-orange-500 rounded"
              >
              </div>
              <span>
                Slightly Slower (12-15 min)
              </span>
            </div>
            <div
              class="flex items-center gap-2"
            >
              <div
                class="w-4 h-4 bg-red-500 rounded"
              >
              </div>
              <span>
                Significantly Slower (&gt;15 min)
              </span>
            </div>
          </div>
        </div>

        <canvas
          id="blockTimeChart"
          phx-hook="BlockTimeChart"
          data-chart-data={Jason.encode!(@block_time_data)}
          class="w-full"
          style="max-height: 400px;"
        >
        </canvas>
      </div>

      <%!-- Block Size Chart --%>
      <div
        class="bg-white shadow-md rounded-lg p-6 mt-8"
      >
        <h2
          class="text-2xl font-semibold mb-4"
        >
          Block Size Over Time
        </h2>

        <div
          class="text-sm text-gray-600 mb-4"
        >
          This chart shows the size of each block in megabytes. Larger blocks contain more transactions and data.
        </div>

        <canvas
          id="blockSizeChart"
          phx-hook="BlockSizeChart"
          data-chart-data={Jason.encode!(@block_size_data)}
          class="w-full"
          style="max-height: 400px;"
        >
        </canvas>
      </div>

      <%!-- Info --%>
      <div
        class="mt-6 text-sm text-gray-600"
      >
        <p>
          The transactions chart shows the number of transactions per block. The inputs & outputs chart shows how many inputs and outputs are in each block's transactions. The satoshi flow chart displays the total value moving through blocks and miner fees collected. The block time variance chart shows mining time variations - the Bitcoin network targets 10 minutes per block, with difficulty adjustments every 2016 blocks to maintain this average. The block size chart shows how much data each block contains, with larger blocks capable of processing more transactions.
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

  defp format_bsv(satoshis) when is_integer(satoshis) do
    (satoshis / 100_000_000) |> Float.round(2)
  end

  defp format_bsv(_), do: "0.00"
end
