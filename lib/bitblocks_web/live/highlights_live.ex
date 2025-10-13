defmodule BitblocksWeb.HighlightsLive do
  use BitblocksWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Blockchain Highlights",
        highlights: get_highlights()
      )

    {:ok, socket}
  end

  defp get_highlights do
    [
      %{
        id: 1,
        title: "Genesis Block - The Beginning",
        date: ~D[2009-01-03],
        category: "milestone",
        txid: "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b",
        block_height: 0,
        author: "Community",
        content: """
        The Genesis Block marks the beginning of Bitcoin. This is where it all started.
        The coinbase transaction contains the famous message: "The Times 03/Jan/2009 Chancellor on brink of second bailout for banks"
        """,
        tags: ["genesis", "milestone", "history"]
      },
      %{
        id: 2,
        title: "First Bitcoin Transaction",
        date: ~D[2009-01-12],
        category: "first",
        txid: "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16",
        block_height: 170,
        author: "Community",
        content: """
        The first Bitcoin transaction sent from one person to another. Satoshi Nakamoto sent 10 BTC to Hal Finney,
        a cryptographer and early Bitcoin contributor. This transaction proved that the system worked.
        """,
        tags: ["first", "satoshi", "hal-finney"]
      },
      %{
        id: 3,
        title: "Bitcoin Pizza Day",
        date: ~D[2010-05-22],
        category: "culture",
        txid: nil,
        block_height: 57043,
        author: "Community",
        content: """
        On this day, Laszlo Hanyecz made the first real-world transaction by buying two pizzas for 10,000 BTC.
        This day is now celebrated annually as Bitcoin Pizza Day, marking the first time Bitcoin was used to purchase a physical good.
        """,
        tags: ["pizza-day", "culture", "milestone"]
      }
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="container mx-auto px-4 py-8 max-w-6xl"
    >
      <div
        class="mb-8"
      >
        <h1
          class="text-4xl font-bold mb-2"
        >
          Blockchain Highlights
        </h1>
        <p
          class="text-gray-600"
        >
          Notable transactions, milestones, and stories from the blockchain
        </p>
      </div>

      <%!-- Contribution Notice --%>
      <div
        class="bg-blue-50 border-l-4 border-blue-500 p-4 mb-8"
      >
        <div
          class="flex items-start"
        >
          <div
            class="flex-shrink-0"
          >
            <svg
              class="h-5 w-5 text-blue-500"
              fill="currentColor"
              viewBox="0 0 20 20"
            >
              <path
                fill-rule="evenodd"
                d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z"
                clip-rule="evenodd"
              />
            </svg>
          </div>
          <div
            class="ml-3"
          >
            <p
              class="text-sm text-blue-700"
            >
              <strong>Community Contributions Welcome!</strong> Know about an interesting transaction or blockchain event?
              <a
                href="https://github.com/yourusername/bitblocks/blob/main/CONTRIBUTING.md"
                target="_blank"
                class="underline font-semibold hover:text-blue-800"
              >
                Submit a PR
              </a> to add your story to this page.
            </p>
          </div>
        </div>
      </div>

      <%!-- Category Filter (future enhancement) --%>
      <div
        class="flex gap-2 mb-6 overflow-x-auto pb-2"
      >
        <span
          class="px-3 py-1 bg-blue-600 text-white rounded-full text-sm font-semibold cursor-pointer"
        >
          All
        </span>
        <span
          class="px-3 py-1 bg-gray-200 text-gray-700 rounded-full text-sm font-semibold cursor-pointer hover:bg-gray-300"
        >
          Milestones
        </span>
        <span
          class="px-3 py-1 bg-gray-200 text-gray-700 rounded-full text-sm font-semibold cursor-pointer hover:bg-gray-300"
        >
          First Events
        </span>
        <span
          class="px-3 py-1 bg-gray-200 text-gray-700 rounded-full text-sm font-semibold cursor-pointer hover:bg-gray-300"
        >
          Culture
        </span>
        <span
          class="px-3 py-1 bg-gray-200 text-gray-700 rounded-full text-sm font-semibold cursor-pointer hover:bg-gray-300"
        >
          NFTs
        </span>
      </div>

      <%!-- Highlights List --%>
      <div
        class="space-y-6"
      >
        <%= for highlight <- @highlights do %>
          <article
            class="bg-white shadow-md rounded-lg p-6 hover:shadow-lg transition-shadow"
          >
            <div
              class="flex items-start justify-between mb-3"
            >
              <div>
                <span class={[
                  "inline-block px-2 py-1 rounded text-xs font-semibold mb-2",
                  category_color(highlight.category)
                ]}>
                  <%= highlight.category |> String.capitalize() %>
                </span>
                <h2
                  class="text-2xl font-bold text-gray-900"
                >
                  <%= highlight.title %>
                </h2>
              </div>
              <time
                class="text-sm text-gray-500"
              >
                <%= Calendar.strftime(highlight.date, "%B %d, %Y") %>
              </time>
            </div>

            <div
              class="prose max-w-none mb-4"
            >
              <p
                class="text-gray-700"
              >
                <%= highlight.content %>
              </p>
            </div>

            <%!-- Metadata --%>
            <div
              class="border-t pt-4 mt-4"
            >
              <div
                class="flex flex-wrap items-center gap-4 text-sm"
              >
                <%= if highlight.block_height do %>
                  <div
                    class="flex items-center gap-1"
                  >
                    <span
                      class="text-gray-500"
                    >
                      Block:
                    </span>
                    <.link
                      navigate={~p"/blocks/#{highlight.block_height}"}
                      class="text-blue-600 hover:underline font-mono"
                    >
                      <%= highlight.block_height %>
                    </.link>
                  </div>
                <% end %>

                <%= if highlight.txid do %>
                  <div
                    class="flex items-center gap-1"
                  >
                    <span
                      class="text-gray-500"
                    >
                      TX:
                    </span>
                    <.link
                      navigate={~p"/transactions/#{highlight.txid}"}
                      class="text-blue-600 hover:underline font-mono text-xs"
                    >
                      <%= String.slice(highlight.txid, 0, 16) %>...
                    </.link>
                  </div>
                <% end %>

                <div
                  class="flex items-center gap-1"
                >
                  <span
                    class="text-gray-500"
                  >
                    By:
                  </span>
                  <span
                    class="text-gray-700 font-semibold"
                  >
                    <%= highlight.author %>
                  </span>
                </div>
              </div>

              <%!-- Tags --%>
              <div
                class="flex flex-wrap gap-2 mt-3"
              >
                <%= for tag <- highlight.tags do %>
                  <span
                    class="px-2 py-1 bg-gray-100 text-gray-600 rounded text-xs"
                  >
                    #<%= tag %>
                  </span>
                <% end %>
              </div>
            </div>
          </article>
        <% end %>
      </div>

      <%!-- How to Contribute Section --%>
      <div
        class="mt-12 bg-gray-50 border border-gray-200 rounded-lg p-6"
      >
        <h2
          class="text-2xl font-semibold mb-4"
        >
          How to Add a Highlight
        </h2>

        <div
          class="space-y-4 text-gray-700"
        >
          <p>
            Want to share a story about an interesting transaction or blockchain event? Here's how:
          </p>

          <ol
            class="list-decimal list-inside space-y-2 ml-4"
          >
            <li>
              Fork the <a
                href="https://github.com/yourusername/bitblocks"
                target="_blank"
                class="text-blue-600 hover:underline"
              >Bitblocks repository</a>
            </li>
            <li>
              Edit <code
                class="bg-gray-200 px-1 py-0.5 rounded"
              >lib/bitblocks_web/live/highlights_live.ex</code>
            </li>
            <li>
              Add your highlight to the <code
                class="bg-gray-200 px-1 py-0.5 rounded"
              >get_highlights/0</code> function
            </li>
            <li>
              Submit a pull request with your story
            </li>
          </ol>

          <div
            class="bg-yellow-50 border-l-4 border-yellow-400 p-4 mt-4"
          >
            <p
              class="text-sm text-yellow-700"
            >
              <strong>Ideas for highlights:</strong> First token mint, first NFT, birthday celebrations,
              notable transactions, record-breaking blocks, community milestones, historical events, or any other
              interesting blockchain moments worth sharing!
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp category_color("milestone"), do: "bg-purple-100 text-purple-800"
  defp category_color("first"), do: "bg-green-100 text-green-800"
  defp category_color("culture"), do: "bg-yellow-100 text-yellow-800"
  defp category_color("nft"), do: "bg-pink-100 text-pink-800"
  defp category_color("record"), do: "bg-red-100 text-red-800"
  defp category_color("birthday"), do: "bg-blue-100 text-blue-800"
  defp category_color(_), do: "bg-gray-100 text-gray-800"
end
