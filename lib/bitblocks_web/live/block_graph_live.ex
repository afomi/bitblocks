defmodule BitblocksWeb.BlockGraphLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.Repo
  alias Bitblocks.Chain.{Block, Transaction}
  import Ecto.Query

  @max_range 1000

  @impl true
  def mount(params, _session, socket) do
    start_height = parse_int(params["start"], 0)
    end_height = parse_int(params["end"], 100)
    layout_mode = Map.get(params, "layout", "time")
    address_filter = Map.get(params, "address", "")
    min_value = parse_int(params["min_value"], 0)
    max_value = parse_int(params["max_value"], 0)
    tx_type = Map.get(params, "type", "all")

    # Clamp range
    end_height = min(start_height + @max_range, end_height)

    socket =
      assign(socket,
        page_title: "Block Graph",
        start_height: start_height,
        end_height: end_height,
        layout_mode: layout_mode,
        address_filter: address_filter,
        min_value: min_value,
        max_value: max_value,
        tx_type: tx_type,
        filters_open: false,
        loading: false,
        node_count: 0,
        edge_count: 0,
        block_count: 0,
        playback_state: "stopped",
        playback_cursor: start_height
      )

    socket =
      if connected?(socket) do
        send(self(), :load_graph)
        assign(socket, loading: true)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("load_graph", params, socket) do
    start_height = parse_int(params["start"], socket.assigns.start_height)
    end_height = parse_int(params["end"], socket.assigns.end_height)
    end_height = min(start_height + @max_range, end_height)

    address_filter = Map.get(params, "address", socket.assigns.address_filter)
    min_value = parse_int(params["min_value"], 0)
    max_value = parse_int(params["max_value"], 0)
    tx_type = Map.get(params, "type", socket.assigns.tx_type)

    send(self(), :load_graph)

    {:noreply,
     assign(socket,
       start_height: start_height,
       end_height: end_height,
       address_filter: address_filter,
       min_value: min_value,
       max_value: max_value,
       tx_type: tx_type,
       loading: true
     )}
  end

  @impl true
  def handle_event("set_layout", %{"mode" => mode}, socket) do
    {:noreply,
     socket
     |> assign(layout_mode: mode)
     |> push_event("block_graph_layout", %{mode: mode})}
  end

  @impl true
  def handle_event("toggle_filters", _params, socket) do
    {:noreply, assign(socket, filters_open: !socket.assigns.filters_open)}
  end

  @impl true
  def handle_event("playback_play", _params, socket) do
    {:noreply,
     socket
     |> assign(playback_state: "playing")
     |> push_event("block_graph_playback", %{action: "play", cursor: socket.assigns.playback_cursor})}
  end

  @impl true
  def handle_event("playback_pause", _params, socket) do
    {:noreply,
     socket
     |> assign(playback_state: "paused")
     |> push_event("block_graph_playback", %{action: "pause"})}
  end

  @impl true
  def handle_event("playback_rewind", _params, socket) do
    {:noreply,
     socket
     |> assign(playback_state: "stopped", playback_cursor: socket.assigns.start_height)
     |> push_event("block_graph_playback", %{action: "rewind", cursor: socket.assigns.start_height})}
  end

  @impl true
  def handle_event("playback_forward", _params, socket) do
    cursor = min(socket.assigns.playback_cursor + 1, socket.assigns.end_height)

    {:noreply,
     socket
     |> assign(playback_cursor: cursor)
     |> push_event("block_graph_playback", %{action: "forward", cursor: cursor})}
  end

  @impl true
  def handle_event("playback_cursor_update", %{"cursor" => cursor}, socket) do
    {:noreply, assign(socket, playback_cursor: cursor)}
  end

  @impl true
  def handle_info(:load_graph, socket) do
    %{
      start_height: start_height,
      end_height: end_height,
      address_filter: address_filter,
      min_value: min_value,
      max_value: max_value,
      tx_type: tx_type
    } = socket.assigns

    filters = %{
      address: address_filter,
      min_value: min_value,
      max_value: max_value,
      tx_type: tx_type
    }

    graph_data = build_block_graph(start_height, end_height, filters)

    socket =
      socket
      |> assign(
        loading: false,
        node_count: length(graph_data.nodes),
        edge_count: length(graph_data.edges),
        block_count: graph_data.block_count
      )
      |> push_event("block_graph_data", graph_data)

    {:noreply, socket}
  end

  defp build_block_graph(start_height, end_height, filters) do
    blocks =
      from(b in Block,
        where: b.height >= ^start_height and b.height <= ^end_height,
        order_by: [asc: b.height],
        select: %{
          height: b.height,
          hash: b.hash,
          num_tx: b.num_tx,
          tx: b.tx,
          time: b.time,
          size: b.size,
          prevblockhash: b.prevblockhash
        }
      )
      |> Repo.all()

    block_hashes = Enum.map(blocks, & &1.hash)

    transactions =
      from(t in Transaction,
        where: t.block_hash in ^block_hashes,
        select: %{
          txid: t.txid,
          block_hash: t.block_hash,
          block_height: t.block_height,
          total_output_satoshis: t.total_output_satoshis,
          total_input_satoshis: t.total_input_satoshis,
          input_count: t.input_count,
          output_count: t.output_count,
          inputs: t.inputs,
          outputs: t.outputs
        }
      )
      |> Repo.all()

    # Apply filters
    transactions = apply_filters(transactions, filters)

    # Build block summary nodes for progressive disclosure
    block_summaries = build_block_summaries(blocks, transactions)

    {nodes, edges} = build_nodes_and_edges(blocks, transactions)

    %{
      nodes: nodes,
      edges: edges,
      blocks: block_summaries,
      block_count: length(blocks),
      start_height: start_height,
      end_height: end_height
    }
  end

  defp apply_filters(transactions, filters) do
    transactions
    |> filter_by_address(filters.address)
    |> filter_by_value(filters.min_value, filters.max_value)
    |> filter_by_type(filters.tx_type)
  end

  defp filter_by_address(transactions, address) when address in [nil, ""], do: transactions

  defp filter_by_address(transactions, address) do
    addresses =
      address
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    if MapSet.size(addresses) == 0 do
      transactions
    else
      Enum.filter(transactions, fn tx ->
        tx_mentions_address?(tx, addresses)
      end)
    end
  end

  defp tx_mentions_address?(tx, addresses) do
    io_strings = (tx.inputs || []) ++ (tx.outputs || [])

    Enum.any?(io_strings, fn str ->
      Enum.any?(addresses, fn addr -> String.contains?(str, addr) end)
    end)
  end

  defp filter_by_value(transactions, min_val, max_val)
       when min_val in [0, nil] and max_val in [0, nil],
       do: transactions

  defp filter_by_value(transactions, min_val, max_val) do
    Enum.filter(transactions, fn tx ->
      sat = tx.total_output_satoshis || 0
      above_min = min_val in [0, nil] or sat >= min_val
      below_max = max_val in [0, nil] or sat <= max_val
      above_min and below_max
    end)
  end

  defp filter_by_type(transactions, "all"), do: transactions

  defp filter_by_type(transactions, "coinbase") do
    Enum.filter(transactions, fn tx -> tx.input_count in [0, nil] end)
  end

  defp filter_by_type(transactions, "spends") do
    Enum.filter(transactions, fn tx -> (tx.input_count || 0) > 0 end)
  end

  defp filter_by_type(transactions, _), do: transactions

  defp build_block_summaries(blocks, transactions) do
    tx_by_block = Enum.group_by(transactions, & &1.block_hash)

    Enum.map(blocks, fn block ->
      block_txs = Map.get(tx_by_block, block.hash, [])
      total_value = block_txs |> Enum.map(&(&1.total_output_satoshis || 0)) |> Enum.sum()

      %{
        height: block.height,
        hash: block.hash,
        tx_count: length(block_txs),
        total_value: total_value,
        time: block.time,
        size: block.size
      }
    end)
  end

  defp build_nodes_and_edges(blocks, transactions) do
    tx_by_block = Enum.group_by(transactions, & &1.block_hash)

    txid_to_height =
      transactions
      |> Enum.map(fn tx -> {tx.txid, tx.block_height} end)
      |> Map.new()

    edges =
      transactions
      |> Enum.flat_map(fn tx ->
        parse_input_edges(tx, txid_to_height)
      end)

    # Build set of txids that have at least one output spent (appear as edge source)
    spent_txids = edges |> Enum.map(& &1.from) |> MapSet.new()

    tx_nodes =
      Enum.flat_map(blocks, fn block ->
        block_txs = Map.get(tx_by_block, block.hash, [])

        block_txs
        |> Enum.with_index()
        |> Enum.map(fn {tx, idx} ->
          is_coinbase = idx == 0 && tx.input_count in [0, nil]

          %{
            id: tx.txid,
            type: if(is_coinbase, do: "coinbase", else: "regular"),
            spent: MapSet.member?(spent_txids, tx.txid),
            block_height: block.height,
            block_time: block.time,
            index: idx,
            total_out: tx.total_output_satoshis,
            total_in: tx.total_input_satoshis,
            input_count: tx.input_count || 0,
            output_count: tx.output_count || 0
          }
        end)
      end)

    {tx_nodes, edges}
  end

  defp parse_input_edges(tx, txid_to_height) do
    (tx.inputs || [])
    |> Enum.flat_map(fn input_str ->
      case Jason.decode(input_str) do
        {:ok, %{"txid" => prev_txid}} when is_binary(prev_txid) ->
          if Map.has_key?(txid_to_height, prev_txid) do
            [
              %{
                from: prev_txid,
                to: tx.txid,
                value: tx.total_input_satoshis
              }
            ]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(n, _default) when is_integer(n), do: n
end
