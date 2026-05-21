defmodule BitblocksWeb.OrderBookLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.OrderBook
  alias BitblocksWeb.Seo

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Bitblocks.PubSub, "order_book")
    end

    listings = OrderBook.list_active_listings(limit: 50)
    stats = OrderBook.listing_stats()

    socket =
      assign(
        socket,
        Seo.public_page(
          page_title: "Open Order Book",
          meta_description:
            "Browse BSV-20 token listings on the permissionless Open Order Book protocol.",
          canonical_path: "/order-book"
        )
      )
      |> assign(
        listings: listings,
        stats: stats,
        token_filter: "",
        seller_filter: "",
        min_price: "",
        max_price: ""
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    token_filter = params["token_id"] || ""
    seller_filter = params["seller"] || ""
    min_price = params["min_price"] || ""
    max_price = params["max_price"] || ""

    opts =
      [limit: 50]
      |> maybe_put(:token_id, non_empty(token_filter))
      |> maybe_put(:seller_address, non_empty(seller_filter))
      |> maybe_put(:min_price, parse_int(min_price))
      |> maybe_put(:max_price, parse_int(max_price))

    listings = OrderBook.list_active_listings(opts)

    {:noreply,
     assign(socket,
       listings: listings,
       token_filter: token_filter,
       seller_filter: seller_filter,
       min_price: min_price,
       max_price: max_price
     )}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    listings = OrderBook.list_active_listings(limit: 50)

    {:noreply,
     assign(socket,
       listings: listings,
       token_filter: "",
       seller_filter: "",
       min_price: "",
       max_price: ""
     )}
  end

  @impl true
  def handle_info({:new_listing, listing}, socket) do
    listings = [listing | socket.assigns.listings]
    stats = OrderBook.listing_stats()
    {:noreply, assign(socket, listings: listings, stats: stats)}
  end

  @impl true
  def handle_info({:listing_cancelled, cancelled}, socket) do
    listings = Enum.reject(socket.assigns.listings, &(&1.txid == cancelled.txid))
    stats = OrderBook.listing_stats()
    {:noreply, assign(socket, listings: listings, stats: stats)}
  end

  @impl true
  def handle_info({:listing_filled, filled}, socket) do
    listings =
      if filled.spent do
        Enum.reject(socket.assigns.listings, &(&1.txid == filled.txid))
      else
        Enum.map(socket.assigns.listings, fn l ->
          if l.txid == filled.txid, do: filled, else: l
        end)
      end

    stats = OrderBook.listing_stats()
    {:noreply, assign(socket, listings: listings, stats: stats)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp non_empty(""), do: nil
  defp non_empty(str), do: str

  defp parse_int(""), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  def truncate_address(nil), do: ""

  def truncate_address(addr) when byte_size(addr) > 12 do
    String.slice(addr, 0, 6) <> "..." <> String.slice(addr, -6, 6)
  end

  def truncate_address(addr), do: addr

  def format_satoshis(nil), do: "—"

  def format_satoshis(sats) when is_binary(sats) do
    case Integer.parse(sats) do
      {n, _} -> delimit_number(n)
      :error -> sats
    end
  end

  def format_satoshis(sats) when is_integer(sats), do: delimit_number(sats)
  def format_satoshis(sats), do: to_string(sats)

  defp delimit_number(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  def status_class("active"), do: "bg-green-100 text-green-700"
  def status_class("partially_filled"), do: "bg-yellow-100 text-yellow-700"
  def status_class("filled"), do: "bg-blue-100 text-blue-700"
  def status_class("cancelled"), do: "bg-red-100 text-red-700"
  def status_class("expired"), do: "bg-gray-100 text-gray-500"
  def status_class(_), do: "bg-gray-100 text-gray-700"

  def format_time(nil), do: "—"

  def format_time(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%Y-%m-%d %H:%M")
  end

  def format_time(_), do: "—"
end
