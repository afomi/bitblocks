defmodule BitblocksWeb.GraphLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.Chain.TxGraph

  @impl true
  def mount(params, _session, socket) do
    txid = Map.get(params, "txid")
    depth = parse_depth(Map.get(params, "depth"))

    # Once, when the socket connects, not on the first render as well.
    graph_data = if txid && connected?(socket), do: graph(txid, depth)

    {:ok,
     assign(socket,
       page_title: "Transaction Graph",
       start_txid: txid,
       depth: depth,
       graph_data: graph_data
     )}
  end

  @impl true
  def handle_event("load_graph", %{"txid" => txid, "depth" => depth}, socket) do
    depth = parse_depth(depth)

    {:noreply, assign(socket, start_txid: txid, depth: depth, graph_data: graph(txid, depth))}
  end

  defp graph(txid, depth) do
    case TxGraph.build(String.trim(txid), depth) do
      {:error, :not_found} -> {:error, "Transaction not found"}
      graph -> graph
    end
  end

  defp parse_depth(value) do
    case Integer.parse(to_string(value)) do
      {depth, ""} -> depth |> max(1) |> min(TxGraph.max_depth())
      _ -> 2
    end
  end

  # Template: graph_live.html.heex
end
