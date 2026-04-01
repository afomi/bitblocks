defmodule BitblocksWeb.EcosystemLive do
  use BitblocksWeb, :live_view

  alias Bitblocks.ProtocolRegistry

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "BSV Ecosystem",
        node_count: 0,
        edge_count: 0,
        selected_node: nil,
        loading: true
      )

    socket =
      if connected?(socket) do
        send(self(), :load_ecosystem)
        socket
      else
        assign(socket, loading: false)
      end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_ecosystem, socket) do
    graph = build_ecosystem_graph()

    socket =
      socket
      |> assign(
        loading: false,
        node_count: length(graph.nodes),
        edge_count: length(graph.edges)
      )
      |> push_event("ecosystem_data", graph)

    {:noreply, socket}
  end

  @impl true
  def handle_event("node_selected", %{"id" => id, "name" => name}, socket) do
    {:noreply, assign(socket, selected_node: %{id: id, name: name})}
  end

  @impl true
  def handle_event("node_deselected", _params, socket) do
    {:noreply, assign(socket, selected_node: nil)}
  end

  defp build_ecosystem_graph do
    # Fetch registered protocols from DB
    db_protocols = ProtocolRegistry.list_protocols(limit: 200)

    db_nodes =
      Enum.map(db_protocols, fn p ->
        %{
          id: "proto_#{p.id}",
          name: p.name || p.address,
          category: to_string(p.category),
          description: p.description || "",
          status: to_string(p.verification_status),
          source: "registry"
        }
      end)

    db_edges =
      db_protocols
      |> Enum.flat_map(fn p ->
        (p.requires || [])
        |> Enum.map(fn req_addr ->
          target = Enum.find(db_protocols, fn other -> other.address == req_addr end)

          if target do
            %{from: "proto_#{p.id}", to: "proto_#{target.id}", type: "requires"}
          end
        end)
        |> Enum.reject(&is_nil/1)
      end)

    # Well-known BSV ecosystem services (static, always shown)
    static_nodes = ecosystem_nodes()
    static_edges = ecosystem_edges()

    %{
      nodes: static_nodes ++ db_nodes,
      edges: static_edges ++ db_edges
    }
  end

  defp ecosystem_nodes do
    [
      %{id: "bsv", name: "Bitcoin SV", category: "network", description: "The BSV blockchain network", status: "active", source: "static"},
      %{id: "bitcom", name: "Bitcom", category: "data_storage", description: "Bitcom protocol namespace system", status: "active", source: "static"},
      %{id: "map", name: "MAP", category: "data_storage", description: "Magic Attribute Protocol — key-value on-chain data", status: "active", source: "static"},
      %{id: "b", name: "B://", category: "data_storage", description: "On-chain file storage protocol", status: "active", source: "static"},
      %{id: "bcat", name: "BCAT", category: "data_storage", description: "Large file storage via chained transactions", status: "active", source: "static"},
      %{id: "run", name: "Run", category: "token", description: "Token and smart contract protocol", status: "active", source: "static"},
      %{id: "handcash", name: "HandCash", category: "identity", description: "Wallet and identity provider", status: "active", source: "static"},
      %{id: "moneybutton", name: "Money Button", category: "identity", description: "Payment and identity widget", status: "deprecated", source: "static"},
      %{id: "whatsonchain", name: "WhatsOnChain", category: "access_control", description: "Block explorer and API", status: "active", source: "static"},
      %{id: "ordinals", name: "1Sat Ordinals", category: "bearer_asset", description: "Ordinal inscriptions on BSV", status: "active", source: "static"},
      %{id: "scrypt", name: "sCrypt", category: "constraint", description: "Smart contract language for Bitcoin", status: "active", source: "static"},
      %{id: "aip", name: "AIP", category: "identity", description: "Author Identity Protocol", status: "active", source: "static"},
      %{id: "bap", name: "BAP", category: "identity", description: "Bitcoin Attestation Protocol", status: "active", source: "static"},
      %{id: "haip", name: "HAIP", category: "identity", description: "Hash Author Identity Protocol", status: "active", source: "static"},
      %{id: "sigma", name: "Sigma", category: "identity", description: "Simplified identity signatures", status: "active", source: "static"},
      %{id: "boost", name: "Boost POW", category: "multi_party", description: "Proof-of-work for content ranking", status: "active", source: "static"},
      %{id: "planaria", name: "Planaria", category: "access_control", description: "Bitcoin application framework", status: "deprecated", source: "static"},
      %{id: "bitbus", name: "Bitbus", category: "access_control", description: "Filtered Bitcoin transaction bus", status: "active", source: "static"},
      %{id: "paymail", name: "Paymail", category: "identity", description: "Human-readable payment addresses", status: "active", source: "static"},
      %{id: "op_return", name: "OP_RETURN", category: "data_storage", description: "Data carrier output protocol", status: "active", source: "static"}
    ]
  end

  defp ecosystem_edges do
    [
      %{from: "bitcom", to: "bsv", type: "built_on"},
      %{from: "map", to: "bitcom", type: "uses"},
      %{from: "b", to: "bitcom", type: "uses"},
      %{from: "bcat", to: "b", type: "extends"},
      %{from: "run", to: "bsv", type: "built_on"},
      %{from: "handcash", to: "bsv", type: "built_on"},
      %{from: "handcash", to: "paymail", type: "uses"},
      %{from: "moneybutton", to: "bsv", type: "built_on"},
      %{from: "moneybutton", to: "paymail", type: "uses"},
      %{from: "whatsonchain", to: "bsv", type: "built_on"},
      %{from: "ordinals", to: "bsv", type: "built_on"},
      %{from: "scrypt", to: "bsv", type: "built_on"},
      %{from: "aip", to: "bitcom", type: "uses"},
      %{from: "bap", to: "aip", type: "extends"},
      %{from: "haip", to: "aip", type: "extends"},
      %{from: "sigma", to: "bsv", type: "built_on"},
      %{from: "boost", to: "bsv", type: "built_on"},
      %{from: "planaria", to: "bsv", type: "built_on"},
      %{from: "bitbus", to: "planaria", type: "extends"},
      %{from: "paymail", to: "bsv", type: "built_on"},
      %{from: "op_return", to: "bsv", type: "built_on"},
      %{from: "b", to: "op_return", type: "uses"},
      %{from: "map", to: "op_return", type: "uses"}
    ]
  end
end
