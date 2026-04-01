defmodule BitblocksWeb.PulseLive do
  use BitblocksWeb, :live_view

  alias BitblocksWeb.Seo

  @refresh_interval :timer.seconds(1)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        Seo.public_page(
          page_title: "Network Pulse",
          meta_description:
            "Experimental visualization of Bitcoin SV mempool pressure and block production as a rhythmic compression and expansion cycle.",
          canonical_path: "/pulse",
          meta_robots: "noindex, follow"
        )
      )
      |> assign(
        mempool_count: 0,
        mempool_bytes: 0,
        block_height: nil,
        last_block_hash: nil,
        last_block_tx_count: 0,
        last_block_seen_at: nil,
        rpc_online: false
      )

    if connected?(socket) do
      send(self(), :refresh)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    snapshot = fetch_snapshot(socket.assigns.last_block_hash, socket.assigns.mempool_count)

    socket =
      socket
      |> assign(
        mempool_count: snapshot.mempool_count,
        mempool_bytes: snapshot.mempool_bytes,
        block_height: snapshot.block_height || socket.assigns.block_height,
        last_block_hash: snapshot.best_block_hash || socket.assigns.last_block_hash,
        last_block_tx_count: snapshot.block_tx_count || socket.assigns.last_block_tx_count,
        last_block_seen_at: snapshot.last_block_seen_at || socket.assigns.last_block_seen_at,
        rpc_online: snapshot.rpc_online
      )
      |> push_event("network_pulse_snapshot", snapshot)

    schedule_refresh()

    {:noreply, socket}
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp fetch_snapshot(previous_hash, previous_mempool_count) do
    blockchain_info = safe_rpc(fn -> BitcoinsvCli.getblockchaininfo() end)
    mempool_info = safe_rpc(fn -> BitcoinsvCli.getmempoolinfo() end)

    best_block_hash =
      case blockchain_info do
        %{} = info -> info["bestblockhash"]
        _ -> previous_hash
      end

    block_height =
      case blockchain_info do
        %{} = info -> info["blocks"]
        _ -> nil
      end

    mempool_count =
      case mempool_info do
        %{} = info -> info["size"] || 0
        _ -> previous_mempool_count
      end

    mempool_bytes =
      case mempool_info do
        %{} = info -> info["bytes"] || 0
        _ -> 0
      end

    new_block? = best_block_hash not in [nil, previous_hash]

    {block_tx_count, block_timestamp} =
      if new_block? do
        fetch_block_details(best_block_hash, previous_mempool_count)
      else
        {nil, nil}
      end

    %{
      rpc_online: is_map(blockchain_info) and is_map(mempool_info),
      mempool_count: mempool_count,
      mempool_bytes: mempool_bytes,
      best_block_hash: best_block_hash,
      block_height: block_height,
      new_block: new_block?,
      block_tx_count: block_tx_count,
      last_block_seen_at: block_timestamp
    }
  end

  defp fetch_block_details(nil, previous_mempool_count), do: {previous_mempool_count, nil}

  defp fetch_block_details(best_block_hash, previous_mempool_count) do
    case safe_rpc(fn -> BitcoinsvCli.getblock(best_block_hash, 1) end) do
      %{} = block ->
        tx_count = block["num_tx"] || length(block["tx"] || []) || previous_mempool_count
        timestamp = block["time"] && DateTime.from_unix!(block["time"]) |> DateTime.to_iso8601()
        {tx_count, timestamp}

      _ ->
        {previous_mempool_count, nil}
    end
  end

  defp safe_rpc(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  def format_count(value) when is_integer(value),
    do: value |> Integer.to_string() |> format_digits()

  def format_count(_), do: "0"

  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000_000_000,
    do: "#{Float.round(bytes / 1_000_000_000, 2)} GB"

  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000_000,
    do: "#{Float.round(bytes / 1_000_000, 2)} MB"

  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000,
    do: "#{Float.round(bytes / 1_000, 2)} KB"

  def format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  def format_bytes(_), do: "0 B"

  defp format_digits(value) do
    value
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
end
