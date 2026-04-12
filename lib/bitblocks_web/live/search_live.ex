defmodule BitblocksWeb.SearchLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.Chain
  alias BitblocksWeb.Seo

  @impl true
  def mount(params, _session, socket) do
    query = Map.get(params, "query", "")

    socket =
      assign(
        socket,
        Seo.public_page(
          page_title: "Search the Bitblocks Explorer",
          meta_description:
            "Search Bitblocks for Bitcoin SV block heights, block hashes, and transaction IDs.",
          canonical_path: "/search",
          meta_robots: "noindex, follow"
        )
      )
      |> assign(
        query: query,
        results: nil,
        error: nil
      )

    # If query is provided in URL, search immediately
    socket =
      if query != "" do
        results = search(query)
        assign(socket, results: results)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, assign(socket, query: "", results: nil, error: nil)}
    else
      # Try to determine what the user is searching for
      results = search(query)

      {:noreply, assign(socket, query: query, results: results, error: nil)}
    end
  end

  defp search(query) do
    cond do
      # Check if it's a block height (numeric)
      is_numeric?(query) ->
        case Chain.get_block(query) do
          nil -> {:error, "Block not found"}
          block -> {:block, block}
        end

      # Check if it's a transaction ID (64 hex chars)
      String.length(query) == 64 and is_hex?(query) ->
        case Chain.get_transaction_by_txid(query) do
          nil -> {:error, "Transaction not found"}
          tx -> {:transaction, tx}
        end

      # Check if it's a block hash (64 hex chars) - same as txid check but try both
      is_hex?(query) ->
        # Try as block hash first
        case Chain.get_block(query) do
          nil ->
            # Try as transaction
            case Chain.get_transaction_by_txid(query) do
              nil -> {:error, "Block or transaction not found"}
              tx -> {:transaction, tx}
            end

          block ->
            {:block, block}
        end

      true ->
        {:error,
         "Invalid search query. Please enter a block height, block hash, or transaction ID."}
    end
  end

  defp is_numeric?(str) do
    case Integer.parse(str) do
      {_num, ""} -> true
      _ -> false
    end
  end

  defp is_hex?(str) do
    String.match?(str, ~r/^[0-9a-fA-F]+$/)
  end

  # Template: search_live.html.heex
end
