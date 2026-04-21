defmodule BitblocksWeb.TransactionLive.Index do
  use BitblocksWeb, :live_view

  alias Bitblocks.Chain
  alias Bitblocks.Chain.Transaction

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:filters, %{})
     |> assign(:show_filters, true)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    cursor = parse_cursor(params["cursor"])
    filters = build_filters(params)

    {transactions, next_cursor} = Chain.list_transactions_paginated(cursor, @per_page, filters)

    socket =
      socket
      |> assign(:cursor, cursor)
      |> assign(:next_cursor, next_cursor)
      |> assign(:filters, filters)
      |> assign(:transactions, transactions)
      |> apply_action(socket.assigns.live_action, params)

    {:noreply, socket}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Transaction")
    |> assign(:transaction, Chain.get_transaction!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Transaction")
    |> assign(:transaction, %Transaction{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Transactions")
    |> assign(:transaction, nil)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    transaction = Chain.get_transaction!(id)
    {:ok, _} = Chain.delete_transaction(transaction)
    {transactions, next_cursor} = Chain.list_transactions_paginated(socket.assigns.cursor, @per_page, socket.assigns.filters)
    {:noreply, socket |> assign(:transactions, transactions) |> assign(:next_cursor, next_cursor)}
  end

  @impl true
  def handle_event("toggle_filters", _params, socket) do
    {:noreply, assign(socket, :show_filters, !socket.assigns.show_filters)}
  end

  @impl true
  def handle_event("apply_filters", params, socket) do
    filter_params = params["filters"] || %{}

    query_params =
      filter_params
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/transactions?#{query_params}")}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/transactions")}
  end

  defp build_filters(params) do
    %{}
    |> maybe_put(:block_hash, params["block_hash"])
    |> maybe_put(:txid_search, params["txid_search"])
    |> maybe_put_integer(:min_inputs, params["min_inputs"])
    |> maybe_put_integer(:min_outputs, params["min_outputs"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_integer(map, _key, nil), do: map
  defp maybe_put_integer(map, _key, ""), do: map
  defp maybe_put_integer(map, key, value) do
    case Integer.parse(value) do
      {num, ""} -> Map.put(map, key, num)
      _ -> map
    end
  end

  defp parse_cursor(nil), do: nil
  defp parse_cursor(""), do: nil
  defp parse_cursor(cursor) do
    case Integer.parse(cursor) do
      {id, ""} -> id
      _ -> nil
    end
  end

  def build_next_url(next_cursor, filters) do
    query_params =
      filters
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> Map.new()
      |> Map.put("cursor", to_string(next_cursor))

    ~p"/transactions?#{query_params}"
  end
end
