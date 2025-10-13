defmodule BitblocksWeb.SearchLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.Chain

  @impl true
  def mount(params, _session, socket) do
    query = Map.get(params, "query", "")

    socket =
      assign(socket,
        page_title: "Search",
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
        case Chain.get_block!(query) do
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
        case Chain.get_block!(query) do
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-4xl">
      <h1 class="text-4xl font-bold mb-6">
        Search
      </h1>

      <%!-- Search Form --%>
      <div class="bg-white shadow-md rounded-lg p-6 mb-6">
        <form phx-submit="search" class="space-y-4">
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-2">
              Block Height, Block Hash, or Transaction ID
            </label>
            <div class="flex gap-2">
              <input
                type="text"
                name="query"
                value={@query}
                placeholder="Enter block height, hash, or txid..."
                class="flex-1 px-4 py-3 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 font-mono text-sm"
                autofocus
              />
              <button
                type="submit"
                class="px-6 py-3 bg-blue-600 text-white rounded-md hover:bg-blue-700 transition-colors font-semibold"
              >
                Search
              </button>
            </div>
          </div>
        </form>
      </div>

      <%!-- Search Results --%>
      <%= if @results do %>
        <%= case @results do %>
          <% {:block, block} -> %>
            <div class="bg-white shadow-md rounded-lg p-6 mb-6">
              <div class="flex items-center justify-between mb-4">
                <h2 class="text-xl font-semibold">
                  Block Found
                </h2>
                <a
                  href={~p"/blocks/#{block.height}"}
                  class="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 transition-colors text-sm"
                >
                  View Block →
                </a>
              </div>

              <div class="grid grid-cols-2 gap-4">
                <div>
                  <div class="text-sm text-gray-600">
                    Height
                  </div>
                  <div class="font-semibold text-lg">
                    <%= block.height %>
                  </div>
                </div>

                <div>
                  <div class="text-sm text-gray-600">
                    Transactions
                  </div>
                  <div class="font-semibold text-lg">
                    <%= block.num_tx %>
                  </div>
                </div>

                <div class="col-span-2">
                  <div class="text-sm text-gray-600 mb-1">
                    Hash
                  </div>
                  <div class="font-mono text-xs break-all bg-gray-50 p-2 rounded">
                    <%= block.hash %>
                  </div>
                </div>
              </div>
            </div>

          <% {:transaction, tx} -> %>
            <div class="bg-white shadow-md rounded-lg p-6 mb-6">
              <div class="flex items-center justify-between mb-4">
                <h2 class="text-xl font-semibold">
                  Transaction Found
                </h2>
                <a
                  href={~p"/transactions/#{tx.txid}"}
                  class="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 transition-colors text-sm"
                >
                  View Transaction →
                </a>
              </div>

              <div>
                <div class="text-sm text-gray-600 mb-1">
                  Transaction ID
                </div>
                <div class="font-mono text-xs break-all bg-gray-50 p-2 rounded">
                  <%= tx.txid %>
                </div>
              </div>

              <%= if tx.block_hash do %>
                <div class="mt-4">
                  <div class="text-sm text-gray-600 mb-1">
                    Block Hash
                  </div>
                  <div class="font-mono text-xs break-all bg-gray-50 p-2 rounded">
                    <%= tx.block_hash %>
                  </div>
                </div>
              <% end %>
            </div>

          <% {:error, message} -> %>
            <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-6 mb-6">
              <p class="text-yellow-800">
                <%= message %>
              </p>
            </div>
        <% end %>
      <% end %>

      <%!-- Examples --%>
      <div class="bg-gray-50 border border-gray-200 rounded-lg p-6">
        <h2 class="text-xl font-semibold mb-4">
          Search Examples
        </h2>

        <div class="space-y-3 text-sm">
          <div>
            <div class="font-semibold text-gray-900 mb-1">
              Block by Height
            </div>
            <div class="font-mono bg-white p-2 rounded border text-xs">
              100
            </div>
          </div>

          <div>
            <div class="font-semibold text-gray-900 mb-1">
              Block by Hash
            </div>
            <div class="font-mono bg-white p-2 rounded border text-xs break-all">
              000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f
            </div>
          </div>

          <div>
            <div class="font-semibold text-gray-900 mb-1">
              Transaction by ID
            </div>
            <div class="font-mono bg-white p-2 rounded border text-xs break-all">
              4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
