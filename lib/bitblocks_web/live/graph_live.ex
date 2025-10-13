defmodule BitblocksWeb.GraphLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.{Repo, Chain}
  import Ecto.Query

  @impl true
  def mount(params, _session, socket) do
    txid = Map.get(params, "txid")
    depth = Map.get(params, "depth", "2") |> String.to_integer()

    socket =
      assign(socket,
        page_title: "Transaction Graph",
        start_txid: txid,
        depth: depth,
        graph_data: nil
      )

    # Load graph if txid is provided
    socket =
      if txid do
        case Chain.get_transaction_by_txid(txid) do
          nil ->
            assign(socket, :graph_data, {:error, "Transaction not found"})

          tx ->
            assign(socket, :graph_data, build_graph(tx, depth))
        end
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("load_graph", %{"txid" => txid, "depth" => depth_str}, socket) do
    depth = String.to_integer(depth_str)

    graph_data =
      case Chain.get_transaction_by_txid(txid) do
        nil ->
          {:error, "Transaction not found"}

        tx ->
          build_graph(tx, depth)
      end

    {:noreply,
     socket
     |> assign(:start_txid, txid)
     |> assign(:depth, depth)
     |> assign(:graph_data, graph_data)}
  end

  defp build_graph(start_tx, max_depth) do
    nodes = []
    edges = []

    # Add the starting transaction
    nodes = [
      %{
        id: start_tx.txid,
        label: String.slice(start_tx.txid, 0, 8) <> "...",
        type: "transaction",
        level: 0
      }
      | nodes
    ]

    # Build the graph recursively
    {nodes, edges} = traverse_inputs(start_tx, 0, max_depth, nodes, edges)
    {nodes, edges} = traverse_outputs(start_tx, 0, max_depth, nodes, edges)

    %{
      nodes: Enum.uniq_by(nodes, & &1.id),
      edges: Enum.uniq_by(edges, & &1.id)
    }
  end

  defp traverse_inputs(tx, current_depth, max_depth, nodes, edges)
       when current_depth < max_depth do
    {:ok, decoded_tx} = BSV.Tx.from_binary(tx.raw, encoding: :hex)

    Enum.reduce(decoded_tx.inputs, {nodes, edges}, fn input, {acc_nodes, acc_edges} ->
      prev_txid = BSV.OutPoint.get_txid(input.outpoint)

      # Skip coinbase transactions
      if prev_txid == "0000000000000000000000000000000000000000000000000000000000000000" do
        {acc_nodes, acc_edges}
      else
        # Add node for previous transaction (negative levels = left side)
        acc_nodes = [
          %{
            id: prev_txid,
            label: String.slice(prev_txid, 0, 8) <> "...",
            type: "transaction",
            # Negative for left side (inputs)
            level: -(current_depth + 1)
          }
          | acc_nodes
        ]

        # Add edge
        edge_id = "#{prev_txid}-#{tx.txid}"

        acc_edges = [
          %{
            id: edge_id,
            from: prev_txid,
            to: tx.txid,
            label: "out:#{input.outpoint.vout}"
          }
          | acc_edges
        ]

        # Recursively traverse if we haven't hit max depth
        case Chain.get_transaction_by_txid(prev_txid) do
          nil -> {acc_nodes, acc_edges}
          prev_tx -> traverse_inputs(prev_tx, current_depth + 1, max_depth, acc_nodes, acc_edges)
        end
      end
    end)
  end

  defp traverse_inputs(_tx, _current_depth, _max_depth, nodes, edges), do: {nodes, edges}

  defp traverse_outputs(tx, current_depth, max_depth, nodes, edges)
       when current_depth < max_depth do
    # Find transactions that spend this transaction's outputs
    # We need to search for the txid within the JSON strings in the inputs array
    query =
      from t in Chain.Transaction,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM unnest(?) AS input WHERE input::jsonb->>'txid' = ?)",
            t.inputs,
            ^tx.txid
          ),
        limit: 10

    spending_txs = Repo.all(query)

    Enum.reduce(spending_txs, {nodes, edges}, fn spending_tx, {acc_nodes, acc_edges} ->
      # Add node for spending transaction (positive levels = right side)
      acc_nodes = [
        %{
          id: spending_tx.txid,
          label: String.slice(spending_tx.txid, 0, 8) <> "...",
          type: "transaction",
          # Positive for right side (outputs)
          level: current_depth + 1
        }
        | acc_nodes
      ]

      # Add edge
      edge_id = "#{tx.txid}-#{spending_tx.txid}"

      acc_edges = [
        %{
          id: edge_id,
          from: tx.txid,
          to: spending_tx.txid,
          label: "spent"
        }
        | acc_edges
      ]

      # Recursively traverse
      traverse_outputs(spending_tx, current_depth + 1, max_depth, acc_nodes, acc_edges)
    end)
  end

  defp traverse_outputs(_tx, _current_depth, _max_depth, nodes, edges), do: {nodes, edges}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-7xl">
      <h1 class="text-4xl font-bold mb-6">
        Transaction Graph
      </h1>

      <%!-- Info Banner --%>
      <div class="bg-blue-50 border-l-4 border-blue-500 p-4 mb-6">
        <div class="flex items-start">
          <div class="flex-shrink-0">
            <svg
              class="h-5 w-5 text-blue-500"
              fill="currentColor"
              viewBox="0 0 20 20"
            >
              <path
                fill-rule="evenodd"
                d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z"
                clip-rule="evenodd"
              />
            </svg>
          </div>
          <div class="ml-3">
            <p class="text-sm text-blue-700">
              <strong>Visualize Transaction Flows:</strong> Enter a transaction ID to see how it connects to other transactions. The graph shows inputs (where value came from) and outputs (where value went to).
            </p>
          </div>
        </div>
      </div>

      <%!-- Graph Controls --%>
      <div class="bg-white shadow-md rounded-lg p-6 mb-6">
        <form phx-submit="load_graph" class="space-y-4">
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-2">
              Transaction ID
            </label>
            <input
              type="text"
              name="txid"
              value={@start_txid}
              placeholder="Enter a transaction ID..."
              class="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500"
              required
            />
          </div>

          <div>
            <label class="block text-sm font-medium text-gray-700 mb-2">
              Graph Depth (levels to traverse)
            </label>
            <select
              name="depth"
              class="px-3 py-2 border border-gray-300 rounded-md"
            >
              <option value="1" selected={@depth == 1}>
                1 level
              </option>
              <option value="2" selected={@depth == 2}>
                2 levels
              </option>
              <option value="3" selected={@depth == 3}>
                3 levels
              </option>
              <option value="4" selected={@depth == 4}>
                4 levels
              </option>
            </select>
          </div>

          <button
            type="submit"
            class="px-6 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 transition-colors"
          >
            Load Graph
          </button>
        </form>
      </div>

      <%!-- Graph Visualization --%>
      <%= if @graph_data do %>
        <%= case @graph_data do %>
          <% {:error, message} -> %>
            <div class="bg-red-50 border border-red-200 rounded-lg p-4">
              <p class="text-red-700">
                <%= message %>
              </p>
            </div>

          <% %{nodes: nodes, edges: edges} -> %>
            <div class="bg-white shadow-md rounded-lg p-6">
              <div class="mb-4">
                <h2 class="text-xl font-semibold">
                  Transaction Network
                </h2>
                <p class="text-sm text-gray-600">
                  <%= length(nodes) %> transactions, <%= length(edges) %> connections
                </p>
              </div>

              <div
                id="transaction-graph"
                phx-hook="TransactionGraph"
                data-graph-data={Jason.encode!(%{nodes: nodes, edges: edges})}
                class="w-full border border-gray-200 rounded"
                style="height: 600px;"
              >
              </div>

              <div class="mt-4 text-sm text-gray-600">
                <div class="mb-2">
                  <strong>How to read:</strong> Value flows from left to right.
                  Green nodes on the left are inputs (where value came from),
                  blue in the center is your selected transaction,
                  and orange nodes on the right are outputs (where value went to).
                </div>

                <div class="flex gap-4 mt-3 flex-wrap">
                  <div class="flex items-center gap-2">
                    <div class="w-4 h-4 bg-green-600 rounded"></div>
                    <span>← Inputs (left)</span>
                  </div>
                  <div class="flex items-center gap-2">
                    <div class="w-4 h-4 bg-blue-600 rounded"></div>
                    <span>Selected transaction (center)</span>
                  </div>
                  <div class="flex items-center gap-2">
                    <div class="w-4 h-4 bg-orange-500 rounded"></div>
                    <span>Outputs (right) →</span>
                  </div>
                </div>

                <div class="mt-3 text-xs">
                  <strong>Tip:</strong> Click any transaction node to view its details
                </div>
              </div>
            </div>
        <% end %>
      <% end %>

      <%!-- Example Transactions --%>
      <div class="mt-8 bg-gray-50 border border-gray-200 rounded-lg p-6">
        <h2 class="text-xl font-semibold mb-4">
          Try These Transactions
        </h2>
        <p class="text-sm text-gray-600 mb-4">
          Don't have a transaction ID? Try one of these:
        </p>
        <div class="space-y-2">
          <div class="text-sm">
            <strong>Genesis Coinbase:</strong>
            <code class="bg-gray-200 px-2 py-1 rounded text-xs ml-2">
              4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b
            </code>
          </div>
          <div class="text-sm">
            <strong>First Bitcoin Transaction:</strong>
            <code class="bg-gray-200 px-2 py-1 rounded text-xs ml-2">
              f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16
            </code>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
