defmodule BitblocksWeb.ProtocolsLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.ProtocolRegistry
  alias BitblocksWeb.Seo

  @impl true
  def mount(_params, _session, socket) do
    # Load registered protocols from database
    protocols = ProtocolRegistry.list_protocols(limit: 50)
    protocol_count = ProtocolRegistry.count_protocols()

    # Group by category for display
    by_category =
      protocols
      |> Enum.group_by(& &1.category)
      |> Enum.sort_by(fn {cat, _} -> category_order(cat) end)

    socket =
      assign(
        socket,
        Seo.public_page(
          page_title: "Bitcoin SV Protocol Registry",
          meta_description:
            "Browse Bitcoin SV protocols indexed by Bitblocks, including identity, token, data storage, and application-layer standards.",
          canonical_path: "/protocols"
        )
      )
      |> assign(
        selected_layer: nil,
        selected_protocol: nil,
        protocols: protocols,
        protocol_count: protocol_count,
        protocols_by_category: by_category,
        search_query: "",
        category_filter: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("select_protocol", %{"protocol" => protocol_id}, socket) do
    # Check if it's a database protocol (numeric ID) or hardcoded (string key)
    selected =
      case Integer.parse(protocol_id) do
        {id, ""} ->
          # Database protocol
          ProtocolRegistry.get_protocol(id)

        _ ->
          # Hardcoded protocol key
          protocol_id
      end

    {:noreply, assign(socket, :selected_protocol, selected)}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_protocol, nil)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    protocols =
      if String.length(query) >= 2 do
        ProtocolRegistry.list_protocols(search: query, limit: 50)
      else
        ProtocolRegistry.list_protocols(limit: 50)
      end

    by_category =
      protocols
      |> Enum.group_by(& &1.category)
      |> Enum.sort_by(fn {cat, _} -> category_order(cat) end)

    {:noreply,
     assign(socket,
       search_query: query,
       protocols: protocols,
       protocols_by_category: by_category
     )}
  end

  @impl true
  def handle_event("filter_category", %{"category" => category}, socket) do
    category_atom =
      case category do
        "" -> nil
        cat -> String.to_existing_atom(cat)
      end

    opts =
      [limit: 50]
      |> then(fn opts ->
        if category_atom, do: Keyword.put(opts, :category, category_atom), else: opts
      end)
      |> then(fn opts ->
        if socket.assigns.search_query != "",
          do: Keyword.put(opts, :search, socket.assigns.search_query),
          else: opts
      end)

    protocols = ProtocolRegistry.list_protocols(opts)

    by_category =
      protocols
      |> Enum.group_by(& &1.category)
      |> Enum.sort_by(fn {cat, _} -> category_order(cat) end)

    {:noreply,
     assign(socket,
       category_filter: category_atom,
       protocols: protocols,
       protocols_by_category: by_category
     )}
  rescue
    ArgumentError ->
      {:noreply, socket}
  end

  defp category_order(category) do
    order = %{
      data_storage: 1,
      identity: 2,
      token: 3,
      consumable: 4,
      multi_party: 5,
      constraint: 6,
      bearer_asset: 7,
      access_control: 8,
      credential: 9,
      other: 10
    }

    Map.get(order, category, 99)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8 max-w-7xl">
      <h1 class="text-4xl font-bold mb-6">
        Bitcoin SV Protocols
      </h1>

      <div class="bg-blue-50 border-l-4 border-blue-500 p-4 mb-8">
        <div class="flex items-start">
          <div class="flex-shrink-0">
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
          <div class="ml-3">
            <p class="text-sm text-blue-700">
              Bitcoin SV enables unlimited data storage on-chain through OP_RETURN outputs, creating a foundation for diverse, interoperable Application Layer protocols that build functionality on top of the blockchain.
            </p>
          </div>
        </div>
      </div>

      <%!-- Protocol Stack Visualization --%>
      <div class="bg-white shadow-lg rounded-lg p-8 mb-8">
        <h2 class="text-2xl font-bold mb-6 text-center">
          Building on Bitcoin
        </h2>

        <div class="space-y-3">
          <%!-- Level 4: Application Protocols --%>
          <div class="relative">
            <div class="bg-gradient-to-r from-slate-400 to-slate-500 text-white rounded-lg p-6 hover:shadow-xl transition-shadow cursor-pointer">
              <div class="flex items-center justify-between gap-6">
                <div class="flex-1">
                  <div class="text-xs font-semibold mb-1 opacity-90">
                    LEVEL 4: APPLICATION PROTOCOLS
                  </div>
                  <div class="text-lg font-bold">
                    Data Protocols & Applications
                  </div>
                  <div class="text-sm mt-1 opacity-90">
                    <%= @protocol_count %> registered protocols including B://, 1SAT Ordinals, MAP, AIP, and more
                  </div>
                </div>
                <div class="bg-slate-300 bg-opacity-30 border border-slate-200 border-opacity-40 rounded-lg p-3 max-w-xs">
                  <div class="text-xs font-semibold mb-1 opacity-90">
                    DEVELOPER FOCUS
                  </div>
                  <div class="text-xs opacity-90">
                    Use
                    <a
                      href="#protocols"
                      class="underline"
                    >
                      Application Layer protocols
                    </a>
                    to create innovative solutions - from storing data and minting tokens to establishing identity systems and crafting decentralized applications.
                  </div>
                </div>
                <div class="text-4xl font-bold opacity-50">
                  4
                </div>
              </div>
            </div>
            <div class="absolute left-0 -bottom-2 w-full h-2 bg-slate-300 rounded-b-lg opacity-30">
            </div>
          </div>

          <%!-- Level 3: Transactions --%>
          <div class="relative">
            <div class="bg-gradient-to-r from-slate-500 to-slate-600 text-white rounded-lg p-6 hover:shadow-xl transition-shadow cursor-pointer">
              <div class="flex items-center justify-between">
                <div>
                  <div class="text-xs font-semibold mb-1 opacity-90">
                    LEVEL 3: TRANSACTIONS
                  </div>
                  <div class="text-lg font-bold">
                    Transaction Structure
                  </div>
                  <div class="text-sm mt-1 opacity-90">
                    Inputs, Outputs, Scripts (OP_RETURN, P2PKH, etc.), Signatures
                  </div>
                </div>
                <div class="text-4xl font-bold opacity-50">
                  3
                </div>
              </div>
            </div>
            <div class="absolute left-0 -bottom-2 w-full h-2 bg-slate-400 rounded-b-lg opacity-30">
            </div>
          </div>

          <%!-- Level 2: Blocks --%>
          <div class="relative">
            <div class="bg-gradient-to-r from-slate-600 to-slate-700 text-white rounded-lg p-6 hover:shadow-xl transition-shadow cursor-pointer">
              <div class="flex items-center justify-between">
                <div>
                  <div class="text-xs font-semibold mb-1 opacity-90">
                    LEVEL 2: BLOCKS
                  </div>
                  <div class="text-lg font-bold">
                    Block Structure
                  </div>
                  <div class="text-sm mt-1 opacity-90">
                    Block Header, Merkle Tree, Timestamp, Difficulty
                  </div>
                </div>
                <div class="text-4xl font-bold opacity-50">
                  2
                </div>
              </div>
            </div>
            <div class="absolute left-0 -bottom-2 w-full h-2 bg-slate-500 rounded-b-lg opacity-30">
            </div>
          </div>

          <%!-- Level 1: Blockchain --%>
          <div class="bg-gradient-to-r from-slate-700 to-slate-800 text-white rounded-lg p-6 hover:shadow-xl transition-shadow cursor-pointer">
            <div class="flex items-center justify-between">
              <div>
                <div class="text-xs font-semibold mb-1 opacity-90">
                  LEVEL 1: BLOCKCHAIN
                </div>
                <div class="text-lg font-bold">
                  Bitcoin SV Blockchain
                </div>
                <div class="text-sm mt-1 opacity-90">
                  Immutable Ledger, Proof of Work, Chain of Blocks
                </div>
              </div>
              <div class="text-4xl font-bold opacity-50">
                1
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Protocol Registry Section --%>
      <div
        id="protocols"
        class="mb-8 mt-12"
      >
        <div class="flex flex-col md:flex-row md:items-center md:justify-between mb-6 gap-4">
          <div>
            <h2 class="text-2xl font-bold mb-2">
              Protocol Registry
            </h2>
            <p class="text-gray-600">
              <%= @protocol_count %> registered protocols. Click on a protocol to learn more.
            </p>
          </div>

          <div class="flex gap-3">
            <%!-- Search --%>
            <form
              phx-change="search"
              class="relative"
            >
              <label
                for="protocol-search"
                class="sr-only"
              >Search protocols</label>
              <input
                type="text"
                id="protocol-search"
                name="query"
                value={@search_query}
                placeholder="Search protocols..."
                class="pl-10 pr-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-purple-500 focus:border-transparent"
              />
              <svg
                class="absolute left-3 top-1/2 transform -translate-y-1/2 h-5 w-5 text-gray-400"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                />
              </svg>
            </form>

            <%!-- Category Filter --%>
            <form phx-change="filter_category">
              <label
                for="protocol-category"
                class="sr-only"
              >Filter by category</label>
              <select
                id="protocol-category"
                name="category"
                class="px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-purple-500 focus:border-transparent"
              >
                <option value="">All Categories</option>
                <option
                  value="data_storage"
                  selected={@category_filter == :data_storage}
                >
                  Data Storage
                </option>
                <option
                  value="identity"
                  selected={@category_filter == :identity}
                >
                  Identity
                </option>
                <option
                  value="token"
                  selected={@category_filter == :token}
                >
                  Tokens
                </option>
                <option
                  value="consumable"
                  selected={@category_filter == :consumable}
                >
                  Consumable
                </option>
                <option
                  value="multi_party"
                  selected={@category_filter == :multi_party}
                >
                  Multi-Party
                </option>
                <option
                  value="constraint"
                  selected={@category_filter == :constraint}
                >
                  Constraint
                </option>
              </select>
            </form>
          </div>
        </div>

        <%!-- Registered Protocols Grid --%>
        <%= if Enum.empty?(@protocols) do %>
          <div class="bg-gray-50 border border-gray-200 rounded-lg p-8 text-center">
            <p class="text-gray-500 mb-4">
              No protocols found matching your criteria.
            </p>
            <p class="text-sm text-gray-500">
              Try adjusting your search or filter settings.
            </p>
          </div>
        <% else %>
          <%= for {category, protocols} <- @protocols_by_category do %>
            <div class="mb-8">
              <h3 class="text-lg font-semibold text-gray-700 mb-4 flex items-center gap-2">
                <span class={"px-2 py-1 rounded text-xs font-semibold #{category_color(category)}"}>
                  <%= format_category(category) %>
                </span>
                <span class="text-gray-500 text-sm font-normal">
                  (<%= length(protocols) %>)
                </span>
              </h3>

              <div class="grid md:grid-cols-2 lg:grid-cols-3 gap-6">
                <%= for protocol <- protocols do %>
                  <div
                    phx-click="select_protocol"
                    phx-value-protocol={protocol.id}
                    class="bg-white border-2 border-gray-200 rounded-lg p-6 hover:border-purple-500 hover:shadow-lg transition-all cursor-pointer"
                  >
                    <div class="flex items-start justify-between mb-3">
                      <h4 class="text-xl font-bold text-gray-900">
                        <%= protocol.name %>
                      </h4>
                      <div class="flex items-center gap-2">
                        <%= if protocol.has_covenant do %>
                          <span
                            class="px-2 py-1 bg-green-100 text-green-700 rounded text-xs font-semibold"
                            title="Covenant Enforced"
                          >
                            Enforced
                          </span>
                        <% end %>
                        <span class={"px-2 py-1 rounded text-xs font-semibold #{status_color(protocol.verification_status)}"}>
                          <%= format_status(protocol.verification_status) %>
                        </span>
                      </div>
                    </div>

                    <p class="text-sm text-gray-600 mb-3 line-clamp-2">
                      <%= protocol.description || "No description available." %>
                    </p>

                    <div class="text-xs font-mono bg-gray-50 p-2 rounded mb-2 truncate">
                      <%= protocol.address %>
                    </div>

                    <%= if protocol.documentation_url do %>
                      <a
                        href={protocol.documentation_url}
                        target="_blank"
                        class="text-xs text-blue-600 hover:underline"
                        onclick="event.stopPropagation()"
                      >
                        Documentation
                      </a>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>

      <%!-- Protocol Detail Modal --%>
      <%= if @selected_protocol do %>
        <div
          class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50"
          phx-click="clear_selection"
        >
          <div
            class="bg-white rounded-lg max-w-3xl w-full max-h-[90vh] overflow-y-auto"
            phx-click="stop_propagation"
          >
            <%= render_protocol_detail(assigns) %>
          </div>
        </div>
      <% end %>

      <%!-- How Protocols Work --%>
      <div
        id="how"
        class="bg-gray-50 border border-gray-200 rounded-lg p-6"
      >
        <h2 class="text-2xl font-bold mb-4">
          How Application Layer Protocols Work
        </h2>

        <div class="space-y-4 text-gray-700">
          <div>
            <h3 class="font-semibold text-lg mb-2">
              OP_RETURN Outputs
            </h3>
            <p class="text-sm">
              Most Application Layer protocols use OP_RETURN outputs to embed data directly in transactions.
              Bitcoin SV has no practical limit on OP_RETURN size, enabling protocols to store
              everything from simple metadata to complete files.
            </p>
          </div>

          <div>
            <h3 class="font-semibold text-lg mb-2">
              Protocol Identifiers (Bitcom)
            </h3>
            <p class="text-sm">
              Protocols use a unique Bitcoin address as their identifier (Bitcom convention). This address
              is placed as the first field in OP_RETURN data, allowing parsers to efficiently recognize
              and decode protocol-specific data. This approach prevents namespace collisions.
            </p>
          </div>

          <div>
            <h3 class="font-semibold text-lg mb-2">
              Covenant Enforcement
            </h3>
            <p class="text-sm">
              Some protocols use Bitcoin script covenants to enforce rules on-chain. These "enforced"
              protocols guarantee that state transitions follow the protocol specification - the rules
              are literally physics, not promises. Look for the "Enforced" badge on protocol cards.
            </p>
          </div>

          <div>
            <h3 class="font-semibold text-lg mb-2">
              Data Encoding
            </h3>
            <p class="text-sm">
              Protocol data can be encoded in various formats: UTF-8 text, JSON, CBOR, or custom binary
              encodings. The protocol specification defines how to structure and interpret the data.
              Data is public by default but can be encrypted for privacy-sensitive applications.
            </p>
          </div>
        </div>
      </div>

      <%!-- API Documentation --%>
      <div class="mt-8 bg-gray-50 border border-gray-200 rounded-lg p-6">
        <h2 class="text-2xl font-bold mb-4">
          Protocol Registry API
        </h2>
        <p class="text-gray-600 mb-4">
          Access protocol information programmatically via our REST API.
        </p>

        <div class="space-y-3 font-mono text-sm">
          <div class="bg-white p-3 rounded border">
            <span class="text-green-700">GET</span>
            <span class="text-gray-700">/api/v1/protocols</span>
            <span class="text-gray-500 ml-2">- List all protocols</span>
          </div>
          <div class="bg-white p-3 rounded border">
            <span class="text-green-700">GET</span>
            <span class="text-gray-700">/api/v1/protocols/:address</span>
            <span class="text-gray-500 ml-2">- Get protocol by address</span>
          </div>
          <div class="bg-white p-3 rounded border">
            <span class="text-blue-600">POST</span>
            <span class="text-gray-700">/api/v1/protocols/identify</span>
            <span class="text-gray-500 ml-2">- Identify protocol from address</span>
          </div>
          <div class="bg-white p-3 rounded border">
            <span class="text-green-700">GET</span>
            <span class="text-gray-700">/api/v1/protocols/stats</span>
            <span class="text-gray-500 ml-2">- Protocol usage statistics</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Render database protocol detail
  defp render_protocol_detail(
         %{selected_protocol: %Bitblocks.ProtocolRegistry.Protocol{} = protocol} = assigns
       ) do
    assigns = assign(assigns, :protocol, protocol)

    ~H"""
    <div class="p-6">
      <div class="flex items-start justify-between mb-4">
        <h2 class="text-3xl font-bold">
          <%= @protocol.name %>
        </h2>
        <div class="flex gap-2">
          <%= if @protocol.has_covenant do %>
            <span class="px-3 py-1 bg-green-100 text-green-700 rounded-full text-sm font-semibold">
              Covenant Enforced
            </span>
          <% end %>
          <span class={"px-3 py-1 rounded-full text-sm font-semibold #{status_color(@protocol.verification_status)}"}>
            <%= format_status(@protocol.verification_status) %>
          </span>
        </div>
      </div>

      <div class="mb-6">
        <span class={"px-3 py-1 rounded-full text-sm font-semibold #{category_color(@protocol.category)}"}>
          <%= format_category(@protocol.category) %>
        </span>
      </div>

      <div class="space-y-4 text-gray-700">
        <p>
          <%= @protocol.description || "No description available." %>
        </p>

        <h3 class="font-semibold text-lg mt-4">
          Protocol Address
        </h3>
        <div class="bg-gray-50 p-4 rounded font-mono text-sm break-all">
          <%= @protocol.address %>
        </div>

        <%= if @protocol.author do %>
          <h3 class="font-semibold text-lg mt-4">
            Author
          </h3>
          <p class="text-sm">
            <%= @protocol.author %>
          </p>
        <% end %>

        <%= if @protocol.schema do %>
          <h3 class="font-semibold text-lg mt-4">
            Schema
          </h3>
          <pre class="bg-gray-50 p-4 rounded text-sm overflow-x-auto"><%= Jason.encode!(@protocol.schema, pretty: true) %></pre>
        <% end %>

        <h3 class="font-semibold text-lg mt-4">
          Resources
        </h3>
        <ul class="space-y-2">
          <%= if @protocol.documentation_url do %>
            <li>
              <a
                href={@protocol.documentation_url}
                target="_blank"
                class="text-blue-600 hover:underline"
              >
                Documentation
              </a>
            </li>
          <% end %>
          <%= if @protocol.source_url do %>
            <li>
              <a
                href={@protocol.source_url}
                target="_blank"
                class="text-blue-600 hover:underline"
              >
                Source Code
              </a>
            </li>
          <% end %>
          <%= if @protocol.example_txid do %>
            <li>
              <a
                href={"https://whatsonchain.com/tx/#{@protocol.example_txid}"}
                target="_blank"
                class="text-blue-600 hover:underline"
              >
                Example Transaction
              </a>
            </li>
          <% end %>
        </ul>
      </div>

      <button
        phx-click="clear_selection"
        class="mt-6 px-4 py-2 bg-gray-200 hover:bg-gray-300 rounded"
      >
        Close
      </button>
    </div>
    """
  end

  # Fallback for legacy hardcoded protocols
  defp render_protocol_detail(%{selected_protocol: "b"} = assigns) do
    ~H"""
    <div class="p-6">
      <h2 class="text-3xl font-bold mb-4">
        B:// Protocol
      </h2>

      <div class="mb-6">
        <span class="px-3 py-1 bg-purple-100 text-purple-700 rounded-full text-sm font-semibold">
          Files on Chain
        </span>
      </div>

      <div class="space-y-4 text-gray-700">
        <p>
          The B:// protocol (Bitcoin Files) allows you to store complete files directly on the
          Bitcoin SV blockchain with content addressing and metadata.
        </p>

        <h3 class="font-semibold text-lg mt-4">
          Structure
        </h3>
        <div class="bg-gray-50 p-4 rounded font-mono text-sm">
          OP_RETURN<br /> 19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut (protocol ID)<br /> [file data]<br />
          [media type]<br /> [encoding]<br /> [filename]
        </div>

        <h3 class="font-semibold text-lg mt-4">
          Use Cases
        </h3>
        <ul class="list-disc list-inside space-y-1">
          <li>Store documents, images, videos permanently on-chain</li>
          <li>Create immutable backups of important files</li>
          <li>Build decentralized content delivery networks</li>
          <li>Archive historical records with cryptographic proof</li>
        </ul>

        <h3 class="font-semibold text-lg mt-4">
          Resources
        </h3>
        <ul class="space-y-2">
          <li>
            <a
              href="https://b.bitdb.network/"
              target="_blank"
              class="text-blue-600 hover:underline"
            >
              B:// Documentation
            </a>
          </li>
        </ul>
      </div>

      <button
        phx-click="clear_selection"
        class="mt-6 px-4 py-2 bg-gray-200 hover:bg-gray-300 rounded"
      >
        Close
      </button>
    </div>
    """
  end

  defp render_protocol_detail(assigns) do
    ~H"""
    <div class="p-6">
      <h2 class="text-3xl font-bold mb-4">
        <%= if is_binary(@selected_protocol), do: String.upcase(@selected_protocol), else: "Protocol" %>
      </h2>

      <p class="text-gray-700 mb-4">
        Detailed information for this protocol is coming soon.
      </p>

      <button
        phx-click="clear_selection"
        class="mt-6 px-4 py-2 bg-gray-200 hover:bg-gray-300 rounded"
      >
        Close
      </button>
    </div>
    """
  end

  # Helper functions for formatting

  defp format_category(category) do
    category
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_status(status) do
    case status do
      :unverified -> "Unverified"
      :pending -> "Pending"
      :beta -> "Beta"
      :verified -> "Verified"
      :deprecated -> "Deprecated"
      _ -> "Unknown"
    end
  end

  defp category_color(category) do
    case category do
      :data_storage -> "bg-purple-100 text-purple-700"
      :identity -> "bg-green-100 text-green-700"
      :token -> "bg-yellow-100 text-yellow-700"
      :consumable -> "bg-orange-100 text-orange-700"
      :multi_party -> "bg-blue-100 text-blue-700"
      :constraint -> "bg-red-100 text-red-700"
      :bearer_asset -> "bg-pink-100 text-pink-700"
      :access_control -> "bg-indigo-100 text-indigo-700"
      :credential -> "bg-teal-100 text-teal-700"
      _ -> "bg-gray-100 text-gray-700"
    end
  end

  defp status_color(status) do
    case status do
      :verified -> "bg-green-100 text-green-700"
      :beta -> "bg-blue-100 text-blue-700"
      :pending -> "bg-yellow-100 text-yellow-700"
      :deprecated -> "bg-red-100 text-red-700"
      _ -> "bg-gray-100 text-gray-700"
    end
  end
end
