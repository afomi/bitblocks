defmodule BitblocksWeb.TxGraphLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.Repo
  alias Bitblocks.Chain.Transaction
  import Ecto.Query

  @max_depth 3
  @max_nodes 50

  @impl true
  def mount(params, _session, socket) do
    txid = Map.get(params, "txid", "")

    socket =
      assign(socket,
        page_title: "Transaction Graph",
        txid: txid,
        graph: %{nodes: [], edges: []},
        node_count: 0,
        edge_count: 0,
        loading: false,
        error: nil
      )

    socket =
      if connected?(socket) and txid != "" do
        send(self(), {:trace_graph, txid})
        assign(socket, loading: true)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("trace", %{"txid" => txid}, socket) do
    txid = String.trim(txid)

    if txid != "" do
      send(self(), {:trace_graph, txid})
      {:noreply, assign(socket, txid: txid, loading: true, error: nil)}
    else
      {:noreply, assign(socket, error: "Enter a transaction ID")}
    end
  end

  @impl true
  def handle_info({:trace_graph, txid}, socket) do
    case build_call_graph(txid) do
      {:ok, graph} ->
        socket =
          socket
          |> assign(
            graph: graph,
            node_count: length(graph.nodes),
            edge_count: length(graph.edges),
            loading: false
          )
          |> push_event("tx_graph_data", graph)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, loading: false, error: reason)}
    end
  end

  defp build_call_graph(root_txid) do
    case Repo.one(from t in Transaction, where: t.txid == ^root_txid, limit: 1) do
      nil ->
        {:error, "Transaction #{String.slice(root_txid, 0, 16)}... not found"}

      root_tx ->
        {nodes, edges} = trace_references(root_tx, %{}, [], 0)

        {:ok,
         %{
           nodes: Map.values(nodes),
           edges: edges,
           root_txid: root_txid
         }}
    end
  end

  defp trace_references(tx, visited, edges, depth)
       when depth < @max_depth and map_size(visited) < @max_nodes do
    if Map.has_key?(visited, tx.txid) do
      {visited, edges}
    else
      node = %{
        id: tx.txid,
        block_height: tx.block_height,
        input_count: tx.input_count || 0,
        output_count: tx.output_count || 0,
        total_out: tx.total_output_satoshis,
        depth: depth,
        is_coinbase: (tx.input_count || 0) == 0
      }

      visited = Map.put(visited, tx.txid, node)

      # Trace backward: find parent txids from inputs
      parent_txids = extract_parent_txids(tx.inputs || [])

      # Trace forward: find children that spend this tx's outputs
      child_txs = find_spending_txs(tx.txid)

      # Build edges
      parent_edges =
        Enum.map(parent_txids, fn parent_txid ->
          %{from: parent_txid, to: tx.txid, type: "spends"}
        end)

      child_edges =
        Enum.map(child_txs, fn child ->
          %{from: tx.txid, to: child.txid, type: "spent_by"}
        end)

      new_edges = edges ++ parent_edges ++ child_edges

      # Recursively trace parents
      parent_txs =
        parent_txids
        |> Enum.reject(&Map.has_key?(visited, &1))
        |> Enum.take(10)
        |> Enum.map(fn txid ->
          Repo.one(from t in Transaction, where: t.txid == ^txid, limit: 1)
        end)
        |> Enum.reject(&is_nil/1)

      {visited, new_edges} =
        Enum.reduce(parent_txs, {visited, new_edges}, fn parent_tx, {v, e} ->
          trace_references(parent_tx, v, e, depth + 1)
        end)

      # Recursively trace children
      unvisited_children =
        child_txs
        |> Enum.reject(fn c -> Map.has_key?(visited, c.txid) end)
        |> Enum.take(10)

      Enum.reduce(unvisited_children, {visited, new_edges}, fn child_tx, {v, e} ->
        trace_references(child_tx, v, e, depth + 1)
      end)
    end
  end

  defp trace_references(_tx, visited, edges, _depth), do: {visited, edges}

  defp extract_parent_txids(inputs) do
    inputs
    |> Enum.flat_map(fn input_str ->
      case Jason.decode(input_str) do
        {:ok, %{"txid" => txid}} when is_binary(txid) and txid != "" ->
          # Skip coinbase null txid
          if String.match?(txid, ~r/^0+$/) do
            []
          else
            [txid]
          end

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp find_spending_txs(txid) do
    # input_txids is a GIN-indexed array of parent txids extracted at write time.
    # ANY() on a GIN-indexed array is O(log n) vs the previous unnest+LIKE full scan.
    from(t in Transaction,
      where: fragment("? = ANY(?)", ^txid, t.input_txids),
      limit: 20
    )
    |> Repo.all()
  end
end
