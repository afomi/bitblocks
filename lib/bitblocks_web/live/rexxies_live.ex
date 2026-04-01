defmodule BitblocksWeb.RexxiesLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.Rexxies

  @per_page 50

  @impl true
  def mount(params, _session, socket) do
    page = parse_int(params["page"], 1)
    search = Map.get(params, "q", "")
    trait_type = Map.get(params, "trait_type", "")
    trait_value = Map.get(params, "trait_value", "")

    socket =
      assign(socket,
        page_title: "Rexxies Collection",
        page: page,
        per_page: @per_page,
        search: search,
        trait_type: trait_type,
        trait_value: trait_value,
        nfts: [],
        total: 0,
        stats: nil,
        selected_nft: nil,
        loading: true
      )

    socket =
      if connected?(socket) do
        send(self(), :load_data)
        socket
      else
        assign(socket, loading: false)
      end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_data, socket) do
    %{page: page, search: search, trait_type: trait_type, trait_value: trait_value} =
      socket.assigns

    {nfts, total} = fetch_nfts(page, search, trait_type, trait_value)
    stats = Rexxies.stats()

    {:noreply,
     assign(socket,
       nfts: nfts,
       total: total,
       stats: stats,
       loading: false
     )}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    send(self(), :load_data)

    {:noreply,
     assign(socket,
       search: query,
       page: 1,
       trait_type: "",
       trait_value: "",
       loading: true
     )}
  end

  @impl true
  def handle_event("filter_trait", %{"type" => type, "value" => value}, socket) do
    send(self(), :load_data)

    {:noreply,
     assign(socket,
       trait_type: type,
       trait_value: value,
       search: "",
       page: 1,
       loading: true
     )}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    send(self(), :load_data)

    {:noreply,
     assign(socket,
       search: "",
       trait_type: "",
       trait_value: "",
       page: 1,
       loading: true
     )}
  end

  @impl true
  def handle_event("page", %{"page" => page_str}, socket) do
    page = parse_int(page_str, 1)
    send(self(), :load_data)
    {:noreply, assign(socket, page: page, loading: true)}
  end

  @impl true
  def handle_event("select_nft", %{"number" => number_str}, socket) do
    number = String.to_integer(number_str)
    nft = Rexxies.get_item(number)
    {:noreply, assign(socket, selected_nft: nft)}
  end

  @impl true
  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, selected_nft: nil)}
  end

  defp fetch_nfts(page, search, trait_type, trait_value) do
    cond do
      search != "" ->
        results = Rexxies.search(search)
        {results, length(results)}

      trait_type != "" && trait_value != "" ->
        results = Rexxies.filter_trait(trait_type, trait_value)
        {results, length(results)}

      true ->
        Rexxies.list_items(page, @per_page)
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(n, _default) when is_integer(n), do: n
end
