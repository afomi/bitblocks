defmodule BitblocksWeb.SearchLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.{Chain, SyncProgress}
  alias BitblocksWeb.{Sats, Seo}

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

  # The largest height a blocks.height column can hold.
  @max_height 2_147_483_647

  defp search(query) do
    cond do
      String.match?(query, ~r/^[0-9a-fA-F]{64}$/) -> search_hash(String.downcase(query))
      String.match?(query, ~r/^[0-9]+$/) -> search_height(String.to_integer(query))
      true -> {:error, invalid_query()}
    end
  end

  defp search_height(height) when height > @max_height, do: {:error, not_indexed(height)}

  defp search_height(height) do
    case Chain.get_block_at_height(height) do
      nil -> {:error, not_indexed(height)}
      block -> {:block, block}
    end
  end

  # 64 hex characters: a txid or a block hash, and nothing says which.
  defp search_hash(hash) do
    cond do
      tx = Chain.get_transaction_by_txid(hash) -> {:transaction, tx}
      block = Chain.get_block(hash) -> {:block, block}
      true -> {:error, hash_not_found()}
    end
  end

  defp invalid_query,
    do:
      "That doesn't look like a block height, a block hash or a transaction ID. " <>
        "A height is a whole number, and a hash or transaction ID is 64 hexadecimal characters."

  defp not_indexed(height) do
    "Block #{Sats.delimit(height)} is not indexed yet." <>
      case Bitblocks.Sync.tip() do
        tip when is_integer(tip) -> " The highest block we know is #{Sats.delimit(tip)}."
        _ -> ""
      end
  end

  defp hash_not_found do
    "Block or transaction not found." <>
      case SyncProgress.snapshot().overview.complete_through do
        through when is_integer(through) and through >= 0 ->
          " It may not be indexed yet: every transaction is stored through block #{Sats.delimit(through)}."

        _ ->
          ""
      end
  end

  # Template: search_live.html.heex
end
