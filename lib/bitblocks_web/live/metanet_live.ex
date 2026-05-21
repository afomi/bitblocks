defmodule BitblocksWeb.MetanetLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.Metanet

  @impl true
  def mount(params, _session, socket) do
    txid = Map.get(params, "txid", "")

    socket =
      assign(socket,
        page_title: "Metanet Explorer",
        txid: txid,
        node: nil,
        parent: nil,
        children: [],
        path: [],
        murl: nil,
        loading: false,
        error: nil
      )

    socket =
      if connected?(socket) and txid != "" do
        send(self(), {:load_node, txid})
        assign(socket, loading: true)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("explore", %{"txid" => txid}, socket) do
    txid = String.trim(txid)

    if txid != "" do
      send(self(), {:load_node, txid})
      {:noreply, assign(socket, txid: txid, loading: true, error: nil)}
    else
      {:noreply, assign(socket, error: "Enter a transaction ID")}
    end
  end

  def handle_event("navigate", %{"txid" => txid}, socket) do
    send(self(), {:load_node, txid})
    {:noreply, assign(socket, txid: txid, loading: true, error: nil)}
  end

  @impl true
  def handle_info({:load_node, txid}, socket) do
    case Metanet.get_node(txid) do
      nil ->
        {:noreply,
         assign(socket,
           loading: false,
           error: "Transaction #{String.slice(txid, 0, 16)}... is not a Metanet node or was not found"
         )}

      node ->
        parent = Metanet.get_parent(txid)
        children = Metanet.get_children(txid)
        path = Metanet.get_path_to_root(txid)
        murl = Metanet.build_murl(path)

        {:noreply,
         assign(socket,
           node: node,
           parent: parent,
           children: children,
           path: path,
           murl: murl,
           loading: false,
           error: nil
         )}
    end
  end
end
