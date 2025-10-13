defmodule BitblocksWeb.TransactionLive.Index do
  use BitblocksWeb, :live_view

  alias Bitblocks.Chain
  alias Bitblocks.Chain.Transaction

  @per_page 500

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:filters, %{})
     |> assign(:show_filters, true)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    page = String.to_integer(params["page"] || "1")
    filters = build_filters(params)

    count = Chain.count_transactions(filters)
    transactions = Chain.list_transactions_paginated(page, @per_page, filters)
    total_pages = calculate_total_pages(count, @per_page)

    socket =
      socket
      |> assign(:page, page)
      |> assign(:per_page, @per_page)
      |> assign(:filters, filters)
      |> assign(:count, count)
      |> assign(:transactions, transactions)
      |> assign(:total_pages, total_pages)
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

    page = socket.assigns.page
    filters = socket.assigns.filters
    transactions = Chain.list_transactions_paginated(page, @per_page, filters)

    {:noreply, assign(socket, :transactions, transactions)}
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
      |> Map.put("page", "1")

    {:noreply, push_patch(socket, to: ~p"/transactions?#{query_params}")}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/transactions")}
  end

  defp build_filters(params) do
    filters = %{}

    filters =
      if params["block_hash"] && params["block_hash"] != "" do
        Map.put(filters, :block_hash, params["block_hash"])
      else
        filters
      end

    filters =
      if params["txid_search"] && params["txid_search"] != "" do
        Map.put(filters, :txid_search, params["txid_search"])
      else
        filters
      end

    filters =
      if params["min_inputs"] && params["min_inputs"] != "" do
        case Integer.parse(params["min_inputs"]) do
          {num, ""} -> Map.put(filters, :min_inputs, num)
          _ -> filters
        end
      else
        filters
      end

    filters =
      if params["min_outputs"] && params["min_outputs"] != "" do
        case Integer.parse(params["min_outputs"]) do
          {num, ""} -> Map.put(filters, :min_outputs, num)
          _ -> filters
        end
      else
        filters
      end

    filters
  end

  defp calculate_total_pages(count, per_page) do
    if count == 0, do: 1, else: ceil(count / per_page)
  end

  def build_page_url(page, filters) do
    query_params =
      filters
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> Map.new()
      |> Map.put("page", to_string(page))

    ~p"/transactions?#{query_params}"
  end
end
