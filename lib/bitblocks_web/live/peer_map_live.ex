defmodule BitblocksWeb.PeerMapLive do
  use BitblocksWeb, :live_view

  @refresh_interval :timer.seconds(30)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Peer Map",
        peers: [],
        peer_count: 0,
        loading: true,
        last_updated: nil,
        geo_progress: 0
      )

    if connected?(socket) do
      send(self(), :fetch_peers)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:fetch_peers, socket) do
    case BitcoinsvCli.getpeerinfo() do
      peers when is_list(peers) ->
        peer_data = extract_peer_data(peers)
        send(self(), {:geolocate_peers, peer_data})

        schedule_refresh()

        {:noreply,
         assign(socket,
           peers: peer_data,
           peer_count: length(peer_data),
           loading: true,
           last_updated: DateTime.utc_now() |> DateTime.to_iso8601()
         )}

      {:error, _reason} ->
        schedule_refresh()
        {:noreply, assign(socket, loading: false, peers: [])}
    end
  end

  @impl true
  def handle_info({:geolocate_peers, peer_data}, socket) do
    # Geolocate in batches to respect rate limits
    located_peers = geolocate_batch(peer_data)

    socket =
      socket
      |> assign(peers: located_peers, loading: false, geo_progress: 100)
      |> push_event("peer_map_data", %{peers: located_peers, home: node_location()})

    {:noreply, socket}
  end

  # Our own node's approximate, static location (the home marker). Sourced from
  # config rather than a runtime geo-IP lookup, since the node doesn't move.
  defp node_location do
    Application.get_env(:bitblocks, :node_location)
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    send(self(), :fetch_peers)
    {:noreply, assign(socket, loading: true)}
  end

  defp extract_peer_data(peers) do
    Enum.map(peers, fn peer ->
      addr = Map.get(peer, "addr", "")
      {ip, port} = parse_addr(addr)

      %{
        ip: ip,
        port: port,
        subver: Map.get(peer, "subver", ""),
        version: Map.get(peer, "version", 0),
        inbound: Map.get(peer, "inbound", false),
        synced_headers: Map.get(peer, "synced_headers", 0),
        synced_blocks: Map.get(peer, "synced_blocks", 0),
        pingtime: Map.get(peer, "pingtime", 0),
        conntime: Map.get(peer, "conntime", 0),
        bytessent: Map.get(peer, "bytessent", 0),
        bytesrecv: Map.get(peer, "bytesrecv", 0),
        lat: nil,
        lon: nil,
        country: nil,
        city: nil,
        isp: nil
      }
    end)
    |> Enum.reject(fn p -> p.ip in [nil, "", "127.0.0.1", "::1"] end)
  end

  defp parse_addr(addr) do
    cond do
      # IPv6 with port: [::1]:8333
      String.starts_with?(addr, "[") ->
        case Regex.run(~r/\[(.+)\]:(\d+)/, addr) do
          [_, ip, port] -> {ip, String.to_integer(port)}
          _ -> {addr, 0}
        end

      # IPv4 with port: 1.2.3.4:8333
      String.contains?(addr, ":") ->
        case String.split(addr, ":") do
          [ip, port] -> {ip, String.to_integer(port)}
          _ -> {addr, 0}
        end

      true ->
        {addr, 0}
    end
  end

  defp geolocate_batch(peers) do
    # Use ip-api.com batch endpoint (free, no key, up to 100 per request)
    # Rate limit: 15 requests per minute for single, batch up to 100
    ips = Enum.map(peers, & &1.ip) |> Enum.uniq()

    geo_results =
      ips
      |> Enum.chunk_every(100)
      |> Enum.flat_map(fn chunk ->
        case geolocate_chunk(chunk) do
          {:ok, results} -> results
          {:error, _} -> []
        end
      end)
      |> Enum.map(fn result -> {result["query"], result} end)
      |> Map.new()

    Enum.map(peers, fn peer ->
      case Map.get(geo_results, peer.ip) do
        %{"status" => "success"} = geo ->
          %{
            peer
            | lat: geo["lat"],
              lon: geo["lon"],
              country: geo["country"],
              city: geo["city"],
              isp: geo["isp"]
          }

        _ ->
          peer
      end
    end)
  end

  defp geolocate_chunk(ips) do
    body = Jason.encode!(ips)

    case HTTPoison.post(
           "http://ip-api.com/batch?fields=query,status,country,city,lat,lon,isp",
           body,
           [{"Content-Type", "application/json"}],
           timeout: 10_000,
           recv_timeout: 10_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
        Jason.decode(response_body)

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        # Rate limited — wait and retry once
        Process.sleep(1_000)

        case HTTPoison.post(
               "http://ip-api.com/batch?fields=query,status,country,city,lat,lon,isp",
               body,
               [{"Content-Type", "application/json"}],
               timeout: 10_000,
               recv_timeout: 10_000
             ) do
          {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
            Jason.decode(response_body)

          _ ->
            {:error, :rate_limited}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schedule_refresh do
    Process.send_after(self(), :fetch_peers, @refresh_interval)
  end
end
