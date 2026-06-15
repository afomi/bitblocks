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
            try do
              assign(socket, :graph_data, build_graph(tx, depth))
            rescue
              e ->
                require Logger
                Logger.error("Graph build failed for #{txid}: #{Exception.message(e)}")
                assign(socket, :graph_data, {:error, "Failed to build graph: #{Exception.message(e)}"})
            end
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
          try do
            build_graph(tx, depth)
          rescue
            e ->
              require Logger
              Logger.error("Graph build failed for #{txid}: #{Exception.message(e)}")
              {:error, "Failed to build graph: #{Exception.message(e)}"}
          end
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
    case Bitblocks.Chain.SafeTx.from_hex(tx.raw || "") do
      {:ok, decoded_tx} ->
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

      _error ->
        {nodes, edges}
    end
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

  # Template: graph_live.html.heex
end
