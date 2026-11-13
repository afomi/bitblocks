defmodule BitblocksWeb.TxGraphLive do
  @moduledoc """
  The transaction flow space: a range of blocks in three.js, every tx a point
  on its block's disc along the height spine, every input an arc back to the
  output it spends, scrubbed with a playhead (the `TxFlow` hook).

      /tx-graph                    blocks 0..999
      /tx-graph?from=0&to=5000     a range (at most FlowTiles.max_blocks/0 blocks)
      /tx-graph?txid=<txid>        the 200 blocks around a tx, with its lineage lit

  The graph is read by the hook: every tx from `/chain-scrubber/flow`
  (`Bitblocks.ChainFlow`) while the range fits its caps, else one node per
  block from the flow tiles (`/chain-scrubber/flow-tiles`,
  `Bitblocks.FlowTiles`, #67). This LiveView owns the range form and the
  annotation layer (`Bitblocks.ChainScrubber.annotations/0`).

  The scene grows as the sync does: when a block in the open range
  completes, or a reorg replaces one, the LiveView pushes `"flow_grew"` and
  the hook reads the range again, keeping the playhead, camera and selection.
  Placement is fixed by the data, so nothing already drawn moves.
  """

  use BitblocksWeb, :live_view

  import Ecto.Query

  alias Bitblocks.{ChainFlow, ChainScrubber, FlowTiles, Repo}
  alias Bitblocks.Chain.Transaction

  @default_span 1_000
  @focus_margin 100

  @impl true
  def mount(params, _session, socket) do
    txid = params |> Map.get("txid", "") |> String.trim() |> String.downcase()
    {from, to, error} = range(params, txid)
    annotations = ChainScrubber.annotations()

    socket =
      assign(socket,
        page_title: "Transaction flow",
        from: from,
        to: to,
        txid: txid,
        error: error,
        max_blocks: FlowTiles.max_blocks(),
        detail_max_blocks: ChainFlow.max_blocks(),
        detail_max_txs: ChainFlow.max_txs(),
        annotation_count: Enum.count(annotations, &(&1.height >= from and &1.height <= to))
      )

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Bitblocks.PubSub, Bitblocks.Annotations.topic())
        Phoenix.PubSub.subscribe(Bitblocks.PubSub, "blocks")
        push_event(socket, "annotations", %{items: annotations})
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info(:annotations_changed, socket) do
    annotations = ChainScrubber.annotations()
    {from, to} = {socket.assigns.from, socket.assigns.to}

    {:noreply,
     socket
     |> assign(
       annotation_count: Enum.count(annotations, &(&1.height >= from and &1.height <= to))
     )
     |> push_event("annotations", %{items: annotations})}
  end

  def handle_info({:block_updated, %{sync_state: "completed", height: height}}, socket)
      when is_integer(height) do
    {:noreply, grew(socket, height)}
  end

  def handle_info({:reorg, %{fork_height: fork_height}}, socket) when is_integer(fork_height) do
    {:noreply, grew(socket, max(fork_height, socket.assigns.from))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # A block in the open range changed: the hook reads the range again.
  defp grew(%{assigns: %{from: from, to: to}} = socket, height)
       when height >= from and height <= to do
    push_event(socket, "flow_grew", %{height: height})
  end

  defp grew(socket, _height), do: socket

  @doc """
  The range to open: `?from=&to=` when both are heights with `from <= to`
  (cut to `FlowTiles.max_blocks/0`), else the blocks around `txid` when we hold it, else
  blocks 0..999. The third element explains a txid we couldn't place.
  """
  def range(params, txid) do
    from = int(params["from"])
    to = int(params["to"])

    cond do
      is_integer(from) and is_integer(to) and from >= 0 and to >= from ->
        {from, min(to, from + FlowTiles.max_blocks() - 1), nil}

      txid != "" ->
        case tx_height(txid) do
          nil ->
            {0, @default_span - 1,
             "Transaction #{String.slice(txid, 0, 16)}… isn't stored, so it can't be placed."}

          h ->
            {max(0, h - @focus_margin), h + @focus_margin, nil}
        end

      true ->
        {0, @default_span - 1, nil}
    end
  end

  defp tx_height(txid) do
    Repo.one(
      from t in Transaction,
        where: t.txid == ^txid and not is_nil(t.block_height),
        select: t.block_height,
        limit: 1
    )
  end

  defp int(nil), do: nil

  defp int(text) when is_binary(text) do
    case text |> String.trim() |> String.replace(~r/[,_]/, "") |> Integer.parse() do
      {n, ""} -> n
      _ -> nil
    end
  end
end
