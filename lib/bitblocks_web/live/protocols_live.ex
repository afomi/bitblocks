defmodule BitblocksWeb.ProtocolsLive do
  use BitblocksWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Bitcoin SV Protocols",
        selected_layer: nil,
        selected_protocol: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("select_protocol", %{"protocol" => protocol}, socket) do
    {:noreply, assign(socket, :selected_protocol, protocol)}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_protocol, nil)}
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
            <div class="bg-gradient-to-r from-purple-500 to-purple-600 text-white rounded-lg p-6 hover:shadow-xl transition-shadow cursor-pointer">
              <div class="flex items-center justify-between gap-6">
                <div class="flex-1">
                  <div class="text-xs font-semibold mb-1 opacity-90">
                    LEVEL 4: APPLICATION PROTOCOLS
                  </div>
                  <div class="text-lg font-bold">
                    Data Protocols & Applications
                  </div>
                  <div class="text-sm mt-1 opacity-90">
                    B://, 1SAT Ordinals, MAP, AIP, HAIP, Paymail, Metanet, etc.
                  </div>
                </div>
                <div class="bg-purple-400 bg-opacity-30 border border-purple-300 border-opacity-40 rounded-lg p-3 max-w-xs">
                  <div class="text-xs font-semibold mb-1 opacity-90">
                    DEVELOPER FOCUS
                  </div>
                  <div class="text-xs opacity-90">
                    Use
                    <a
                      href="#how"
                      class="underline">Application Layer protocols</a>
                    to create innovative solutions - from storing data and minting tokens to establishing identity systems and crafting decentralized applications.
                  </div>
                </div>
                <div class="text-4xl font-bold opacity-50">
                  4
                </div>
              </div>
            </div>
            <div class="absolute left-0 -bottom-2 w-full h-2 bg-purple-400 rounded-b-lg opacity-30"></div>
          </div>

          <%!-- Level 3: Transactions --%>
          <div class="relative">
            <div class="bg-gradient-to-r from-blue-500 to-blue-600 text-white rounded-lg p-6 hover:shadow-xl transition-shadow cursor-pointer">
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
            <div class="absolute left-0 -bottom-2 w-full h-2 bg-blue-400 rounded-b-lg opacity-30"></div>
          </div>

          <%!-- Level 2: Blocks --%>
          <div class="relative">
            <div class="bg-gradient-to-r from-green-500 to-green-600 text-white rounded-lg p-6 hover:shadow-xl transition-shadow cursor-pointer">
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
            <div class="absolute left-0 -bottom-2 w-full h-2 bg-green-400 rounded-b-lg opacity-30"></div>
          </div>

          <%!-- Level 1: Blockchain --%>
          <div class="bg-gradient-to-r from-gray-700 to-gray-800 text-white rounded-lg p-6 hover:shadow-xl transition-shadow cursor-pointer">
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

      <%!-- Featured Protocols --%>
      <div class="mb-8 mt-12">
        <h2 class="text-2xl font-bold mb-2">
          Application Layer Protocols
        </h2>
        <p class="text-gray-600 mb-6">
          Click on a protocol to learn more about how it works.
        </p>

        <div class="grid md:grid-cols-2 lg:grid-cols-3 gap-6">
          <%!-- B:// Protocol --%>
          <div
            phx-click="select_protocol"
            phx-value-protocol="b"
            class="bg-white border-2 border-gray-200 rounded-lg p-6 hover:border-purple-500 hover:shadow-lg transition-all cursor-pointer"
          >
            <div class="flex items-start justify-between mb-3">
              <h3 class="text-xl font-bold text-gray-900">
                B:// Protocol
              </h3>
              <span class="px-2 py-1 bg-purple-100 text-purple-700 rounded text-xs font-semibold">
                Files
              </span>
            </div>
            <p class="text-sm text-gray-600 mb-3">
              Store complete files directly on the blockchain with metadata and content addressing.
            </p>
            <div class="text-xs font-mono bg-gray-50 p-2 rounded mb-2">
              19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut
            </div>
            <a
              href="https://b.bitdb.network/"
              target="_blank"
              class="text-xs text-blue-600 hover:underline"
              onclick="event.stopPropagation()"
            >
              b.bitdb.network →
            </a>
          </div>

          <%!-- 1SAT Ordinals --%>
          <div
            phx-click="select_protocol"
            phx-value-protocol="ordinals"
            class="bg-white border-2 border-gray-200 rounded-lg p-6 hover:border-purple-500 hover:shadow-lg transition-all cursor-pointer"
          >
            <div class="flex items-start justify-between mb-3">
              <h3 class="text-xl font-bold text-gray-900">
                1SAT Ordinals
              </h3>
              <span class="px-2 py-1 bg-pink-100 text-pink-700 rounded text-xs font-semibold">
                NFTs
              </span>
            </div>
            <p class="text-sm text-gray-600 mb-3">
              Inscribe digital artifacts and NFTs directly into transaction outputs on Bitcoin SV.
            </p>
            <div class="text-xs font-mono bg-gray-50 p-2 rounded mb-2">
              ord | 1SAT format
            </div>
            <a
              href="https://docs.1satordinals.com/"
              target="_blank"
              class="text-xs text-blue-600 hover:underline"
              onclick="event.stopPropagation()"
            >
              docs.1satordinals.com →
            </a>
          </div>

          <%!-- MAP --%>
          <div
            phx-click="select_protocol"
            phx-value-protocol="map"
            class="bg-white border-2 border-gray-200 rounded-lg p-6 hover:border-purple-500 hover:shadow-lg transition-all cursor-pointer"
          >
            <div class="flex items-start justify-between mb-3">
              <h3 class="text-xl font-bold text-gray-900">
                MAP
              </h3>
              <span class="px-2 py-1 bg-blue-100 text-blue-700 rounded text-xs font-semibold">
                Metadata
              </span>
            </div>
            <p class="text-sm text-gray-600 mb-3">
              Magic Attribute Protocol: Store key-value metadata for any on-chain content.
            </p>
            <div class="text-xs font-mono bg-gray-50 p-2 rounded mb-2">
              1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5
            </div>
            <a
              href="https://github.com/rohenaz/MAP"
              target="_blank"
              class="text-xs text-blue-600 hover:underline"
              onclick="event.stopPropagation()"
            >
              github.com/rohenaz/MAP →
            </a>
          </div>

          <%!-- AIP --%>
          <div
            phx-click="select_protocol"
            phx-value-protocol="aip"
            class="bg-white border-2 border-gray-200 rounded-lg p-6 hover:border-purple-500 hover:shadow-lg transition-all cursor-pointer"
          >
            <div class="flex items-start justify-between mb-3">
              <h3 class="text-xl font-bold text-gray-900">
                AIP
              </h3>
              <span class="px-2 py-1 bg-green-100 text-green-700 rounded text-xs font-semibold">
                Identity
              </span>
            </div>
            <p class="text-sm text-gray-600 mb-3">
              Author Identity Protocol: Sign content on-chain to prove authorship and ownership.
            </p>
            <div class="text-xs font-mono bg-gray-50 p-2 rounded">
              15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva
            </div>
          </div>

          <%!-- HAIP --%>
          <div
            phx-click="select_protocol"
            phx-value-protocol="haip"
            class="bg-white border-2 border-gray-200 rounded-lg p-6 hover:border-purple-500 hover:shadow-lg transition-all cursor-pointer"
          >
            <div class="flex items-start justify-between mb-3">
              <h3 class="text-xl font-bold text-gray-900">
                HAIP
              </h3>
              <span class="px-2 py-1 bg-green-100 text-green-700 rounded text-xs font-semibold">
                Identity
              </span>
            </div>
            <p class="text-sm text-gray-600 mb-3">
              Hash Author Identity Protocol: Hash-based verification for data integrity and provenance.
            </p>
            <div class="text-xs font-mono bg-gray-50 p-2 rounded">
              1HA1P2exomAwCUycZHr8WeyFoy5vuQASE3
            </div>
          </div>

          <%!-- Paymail --%>
          <div
            phx-click="select_protocol"
            phx-value-protocol="paymail"
            class="bg-white border-2 border-gray-200 rounded-lg p-6 hover:border-purple-500 hover:shadow-lg transition-all cursor-pointer"
          >
            <div class="flex items-start justify-between mb-3">
              <h3 class="text-xl font-bold text-gray-900">
                Paymail
              </h3>
              <span class="px-2 py-1 bg-orange-100 text-orange-700 rounded text-xs font-semibold">
                Payments
              </span>
            </div>
            <p class="text-sm text-gray-600 mb-3">
              Human-readable payment addresses (like email) that resolve to Bitcoin addresses.
            </p>
            <div class="text-xs font-mono bg-gray-50 p-2 rounded">
              user@domain.com
            </div>
          </div>

          <%!-- SIGMA --%>
          <div
            phx-click="select_protocol"
            phx-value-protocol="sigma"
            class="bg-white border-2 border-gray-200 rounded-lg p-6 hover:border-purple-500 hover:shadow-lg transition-all cursor-pointer"
          >
            <div class="flex items-start justify-between mb-3">
              <h3 class="text-xl font-bold text-gray-900">
                SIGMA
              </h3>
              <span class="px-2 py-1 bg-yellow-100 text-yellow-700 rounded text-xs font-semibold">
                Tokens
              </span>
            </div>
            <p class="text-sm text-gray-600 mb-3">
              Simplified token protocol for creating and managing fungible tokens on Bitcoin SV.
            </p>
            <div class="text-xs font-mono bg-gray-50 p-2 rounded">
              STAS/SIGMA format
            </div>
          </div>

          <%!-- Run --%>
          <div
            phx-click="select_protocol"
            phx-value-protocol="run"
            class="bg-white border-2 border-gray-200 rounded-lg p-6 hover:border-purple-500 hover:shadow-lg transition-all cursor-pointer"
          >
            <div class="flex items-start justify-between mb-3">
              <h3 class="text-xl font-bold text-gray-900">
                Run
              </h3>
              <span class="px-2 py-1 bg-red-100 text-red-700 rounded text-xs font-semibold">
                Smart Contracts
              </span>
            </div>
            <p class="text-sm text-gray-600 mb-3">
              Token and smart contract protocol with programmable logic built on Bitcoin SV.
            </p>
            <div class="text-xs font-mono bg-gray-50 p-2 rounded">
              Jig-based tokens
            </div>
          </div>

          <%!-- Metanet --%>
          <div
            phx-click="select_protocol"
            phx-value-protocol="metanet"
            class="bg-white border-2 border-gray-200 rounded-lg p-6 hover:border-purple-500 hover:shadow-lg transition-all cursor-pointer"
          >
            <div class="flex items-start justify-between mb-3">
              <h3 class="text-xl font-bold text-gray-900">
                Metanet
              </h3>
              <span class="px-2 py-1 bg-indigo-100 text-indigo-700 rounded text-xs font-semibold">
                Network
              </span>
            </div>
            <p class="text-sm text-gray-600 mb-3">
              Graph-based protocol for organizing data on-chain into interconnected structures.
            </p>
            <div class="text-xs font-mono bg-gray-50 p-2 rounded">
              Parent-child relationships
            </div>
          </div>

          <%!-- Bitcoin Schema --%>
          <div
            phx-click="select_protocol"
            phx-value-protocol="bitcoin-schema"
            class="bg-white border-2 border-gray-200 rounded-lg p-6 hover:border-purple-500 hover:shadow-lg transition-all cursor-pointer"
          >
            <div class="flex items-start justify-between mb-3">
              <h3 class="text-xl font-bold text-gray-900">
                Bitcoin Schema
              </h3>
              <span class="px-2 py-1 bg-teal-100 text-teal-700 rounded text-xs font-semibold">
                Standards
              </span>
            </div>
            <p class="text-sm text-gray-600 mb-3">
              Comprehensive collection of on-chain data standards and protocol specifications for Bitcoin SV.
            </p>
            <div class="text-xs font-mono bg-gray-50 p-2 rounded mb-2">
              Multi-protocol registry
            </div>
            <a
              href="https://bitcoinschema.org/"
              target="_blank"
              class="text-xs text-blue-600 hover:underline"
              onclick="event.stopPropagation()"
            >
              bitcoinschema.org →
            </a>
          </div>
        </div>
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
              Protocol Identifiers
            </h3>
            <p class="text-sm">
              Protocols typically use a unique identifier (often a Bitcoin address) as the first
              field in their OP_RETURN data. This allows parsers to efficiently recognize and decode protocol-specific data.
            </p>
          </div>

          <div>
            <h3 class="font-semibold text-lg mb-2">
              Data Encoding
            </h3>
            <p class="text-sm">
              Protocol data can be encoded in various formats: UTF-8 text, JSON, binary data,
              or custom encodings. The protocol specification defines how to structure and interpret the data.
              Bitcoin data is not encrypted by default - all on-chain data is publicly readable.
              However, payloads can be encrypted using various methods (symmetric encryption, public key encryption, etc.)
              before being written to the blockchain for privacy-sensitive applications.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

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
          OP_RETURN<br />
          19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut (protocol ID)<br />
          [file data]<br />
          [media type]<br />
          [encoding]<br />
          [filename]
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
              B:// Documentation →
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

  defp render_protocol_detail(%{selected_protocol: "ordinals"} = assigns) do
    ~H"""
    <div class="p-6">
      <h2 class="text-3xl font-bold mb-4">
        1SAT Ordinals
      </h2>

      <div class="mb-6">
        <span class="px-3 py-1 bg-pink-100 text-pink-700 rounded-full text-sm font-semibold">
          NFTs & Digital Artifacts
        </span>
      </div>

      <div class="space-y-4 text-gray-700">
        <p>
          1SAT Ordinals brings inscription-based NFTs to Bitcoin SV, allowing digital artifacts
          to be permanently inscribed into satoshis (the smallest unit of Bitcoin).
        </p>

        <h3 class="font-semibold text-lg mt-4">
          How It Works
        </h3>
        <p>
          Digital content (images, text, HTML, etc.) is inscribed directly into transaction outputs.
          Each inscription is associated with a specific satoshi, creating unique, trackable digital artifacts.
        </p>

        <h3 class="font-semibold text-lg mt-4">
          Use Cases
        </h3>
        <ul class="list-disc list-inside space-y-1">
          <li>Digital art and collectibles</li>
          <li>On-chain generative art</li>
          <li>Proof of authenticity for digital content</li>
          <li>Immutable digital archives</li>
        </ul>

        <h3 class="font-semibold text-lg mt-4">
          Resources
        </h3>
        <ul class="space-y-2">
          <li>
            <a
              href="https://docs.1satordinals.com/"
              target="_blank"
              class="text-blue-600 hover:underline"
            >
              1SAT Ordinals Documentation →
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

  defp render_protocol_detail(%{selected_protocol: "map"} = assigns) do
    ~H"""
    <div class="p-6">
      <h2 class="text-3xl font-bold mb-4">
        MAP (Magic Attribute Protocol)
      </h2>

      <div class="mb-6">
        <span class="px-3 py-1 bg-blue-100 text-blue-700 rounded-full text-sm font-semibold">
          Metadata & Attributes
        </span>
      </div>

      <div class="space-y-4 text-gray-700">
        <p>
          MAP provides a standardized way to attach key-value metadata to any on-chain content,
          making it searchable and categorizable.
        </p>

        <h3 class="font-semibold text-lg mt-4">
          Structure
        </h3>
        <div class="bg-gray-50 p-4 rounded font-mono text-sm">
          OP_RETURN<br />
          1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5 (MAP prefix)<br />
          SET<br />
          [key1] [value1]<br />
          [key2] [value2]<br />
          ...
        </div>

        <h3 class="font-semibold text-lg mt-4">
          Use Cases
        </h3>
        <ul class="list-disc list-inside space-y-1">
          <li>Tag and categorize on-chain content</li>
          <li>Add descriptions and titles to files</li>
          <li>Store structured metadata for NFTs</li>
          <li>Create searchable on-chain databases</li>
        </ul>

        <h3 class="font-semibold text-lg mt-4">
          Resources
        </h3>
        <ul class="space-y-2">
          <li>
            <a
              href="https://github.com/rohenaz/MAP"
              target="_blank"
              class="text-blue-600 hover:underline"
            >
              MAP Protocol Specification →
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

  defp render_protocol_detail(%{selected_protocol: "bitcoin-schema"} = assigns) do
    ~H"""
    <div class="p-6">
      <h2 class="text-3xl font-bold mb-4">
        Bitcoin Schema
      </h2>

      <div class="mb-6">
        <span class="px-3 py-1 bg-teal-100 text-teal-700 rounded-full text-sm font-semibold">
          Protocol Standards & Registry
        </span>
      </div>

      <div class="space-y-4 text-gray-700">
        <p>
          Bitcoin Schema is a comprehensive registry of on-chain data standards and protocol specifications
          for Bitcoin SV, providing a centralized reference for developers building on the blockchain.
        </p>

        <h3 class="font-semibold text-lg mt-4">
          What It Provides
        </h3>
        <ul class="list-disc list-inside space-y-1">
          <li>Standardized protocol specifications and documentation</li>
          <li>Transaction prefix registry for protocol identification</li>
          <li>Common data formats and structures</li>
          <li>Integration libraries and tools</li>
        </ul>

        <h3 class="font-semibold text-lg mt-4">
          Included Protocols
        </h3>
        <p>
          Bitcoin Schema documents many Application Layer protocols including B://, MAP, AIP, HAIP,
          Paymail, and many others, providing a unified reference for the Bitcoin SV ecosystem.
        </p>

        <h3 class="font-semibold text-lg mt-4">
          Resources
        </h3>
        <ul class="space-y-2">
          <li>
            <a
              href="https://bitcoinschema.org/"
              target="_blank"
              class="text-blue-600 hover:underline"
            >
              Bitcoin Schema Website →
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

  defp render_protocol_detail(%{selected_protocol: protocol} = assigns) do
    ~H"""
    <div class="p-6">
      <h2 class="text-3xl font-bold mb-4">
        <%= String.upcase(protocol) %> Protocol
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
end
