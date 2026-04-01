defmodule BitblocksWeb.Api.ProtocolController do
  use BitblocksWeb, :controller

  alias Bitblocks.ProtocolRegistry
  alias Bitblocks.ProtocolRegistry.Protocol

  action_fallback BitblocksWeb.FallbackController

  @doc """
  List all registered protocols with optional filters.

  GET /api/v1/protocols

  Query parameters:
    - category: Filter by category (consumable, data_storage, identity, etc.)
    - verification_status: Filter by status (unverified, pending, beta, verified, deprecated)
    - has_covenant: Filter by covenant enforcement (true/false)
    - search: Search by name or address
    - limit: Max results (default 50)
    - offset: Pagination offset
  """
  def index(conn, params) do
    opts = build_filter_opts(params)
    protocols = ProtocolRegistry.list_protocols(opts)
    total = ProtocolRegistry.count_protocols(opts)

    json(conn, %{
      data: Enum.map(protocols, &protocol_to_json/1),
      meta: %{
        total: total,
        limit: opts[:limit] || 50,
        offset: opts[:offset] || 0
      }
    })
  end

  @doc """
  Get a specific protocol by address.

  GET /api/v1/protocols/:address
  """
  def show(conn, %{"address" => address} = params) do
    version = params["version"]

    case ProtocolRegistry.get_protocol_by_address(address, version) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Protocol not found", address: address})

      protocol ->
        stats = ProtocolRegistry.get_protocol_stats(protocol.id)
        audits = ProtocolRegistry.list_audits(protocol.id)

        json(conn, %{
          data: protocol_to_json(protocol),
          stats: stats_to_json(stats),
          audits: Enum.map(audits, &audit_to_json/1)
        })
    end
  end

  @doc """
  Identify a protocol from a script or OP_RETURN data.

  POST /api/v1/protocols/identify

  Body:
    - address: The Bitcom-style protocol address to identify
    - script: (optional) Raw script hex to parse and identify
  """
  def identify(conn, %{"address" => address}) do
    case ProtocolRegistry.identify_protocol(address) do
      {:ok, protocol} ->
        json(conn, %{
          found: true,
          data: protocol_to_json(protocol)
        })

      {:error, :not_found} ->
        json(conn, %{
          found: false,
          address: address,
          suggestion: "This protocol is not in the registry. Consider submitting it."
        })
    end
  end

  def identify(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameter: address"})
  end

  @doc """
  Get statistics for all protocols.

  GET /api/v1/protocols/stats
  """
  def stats_overview(conn, _params) do
    protocols = ProtocolRegistry.list_protocols(limit: 100)

    stats =
      protocols
      |> Enum.map(fn protocol ->
        stats = ProtocolRegistry.get_protocol_stats(protocol.id)

        %{
          address: protocol.address,
          name: protocol.name,
          category: protocol.category,
          instance_count: (stats && stats.instance_count) || 0,
          last_seen_at: stats && stats.last_seen_at
        }
      end)
      |> Enum.sort_by(& &1.instance_count, :desc)

    json(conn, %{
      data: stats,
      summary: %{
        total_protocols: length(protocols),
        by_category: group_by_category(protocols),
        by_status: group_by_status(protocols)
      }
    })
  end

  @doc """
  Search protocols by name or address.

  GET /api/v1/protocols/search?q=:query
  """
  def search(conn, %{"q" => query}) when byte_size(query) >= 2 do
    protocols = ProtocolRegistry.list_protocols(search: query, limit: 20)

    json(conn, %{
      data: Enum.map(protocols, &protocol_to_json/1),
      query: query
    })
  end

  def search(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Query must be at least 2 characters"})
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp build_filter_opts(params) do
    []
    |> maybe_add_category(params["category"])
    |> maybe_add_status(params["verification_status"])
    |> maybe_add_covenant(params["has_covenant"])
    |> maybe_add_search(params["search"])
    |> maybe_add_limit(params["limit"])
    |> maybe_add_offset(params["offset"])
  end

  defp maybe_add_category(opts, nil), do: opts

  defp maybe_add_category(opts, category) do
    case safe_atom(category, Protocol.categories()) do
      nil -> opts
      atom -> Keyword.put(opts, :category, atom)
    end
  end

  defp maybe_add_status(opts, nil), do: opts

  defp maybe_add_status(opts, status) do
    case safe_atom(status, Protocol.verification_statuses()) do
      nil -> opts
      atom -> Keyword.put(opts, :verification_status, atom)
    end
  end

  defp maybe_add_covenant(opts, nil), do: opts
  defp maybe_add_covenant(opts, "true"), do: Keyword.put(opts, :has_covenant, true)
  defp maybe_add_covenant(opts, "false"), do: Keyword.put(opts, :has_covenant, false)
  defp maybe_add_covenant(opts, _), do: opts

  defp maybe_add_search(opts, nil), do: opts
  defp maybe_add_search(opts, ""), do: opts
  defp maybe_add_search(opts, search), do: Keyword.put(opts, :search, search)

  defp maybe_add_limit(opts, nil), do: Keyword.put(opts, :limit, 50)

  defp maybe_add_limit(opts, limit) do
    case Integer.parse(limit) do
      {n, ""} when n > 0 and n <= 100 -> Keyword.put(opts, :limit, n)
      _ -> Keyword.put(opts, :limit, 50)
    end
  end

  defp maybe_add_offset(opts, nil), do: opts

  defp maybe_add_offset(opts, offset) do
    case Integer.parse(offset) do
      {n, ""} when n >= 0 -> Keyword.put(opts, :offset, n)
      _ -> opts
    end
  end

  defp safe_atom(string, valid_atoms) do
    atom = String.to_existing_atom(string)
    if atom in valid_atoms, do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  defp protocol_to_json(%Protocol{} = p) do
    %{
      id: p.id,
      address: p.address,
      name: p.name,
      version: p.version,
      description: p.description,
      category: p.category,
      verification_status: p.verification_status,
      has_covenant: p.has_covenant,
      covenant_hash: p.covenant_hash,
      author: p.author,
      documentation_url: p.documentation_url,
      source_url: p.source_url,
      example_txid: p.example_txid,
      requires: p.requires,
      conflicts_with: p.conflicts_with,
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  defp stats_to_json(nil), do: nil

  defp stats_to_json(stats) do
    %{
      instance_count: stats.instance_count,
      transaction_count: stats.transaction_count,
      unique_addresses: stats.unique_addresses,
      total_satoshis: stats.total_satoshis,
      first_seen_at: stats.first_seen_at,
      first_seen_txid: stats.first_seen_txid,
      last_seen_at: stats.last_seen_at,
      last_seen_txid: stats.last_seen_txid
    }
  end

  defp audit_to_json(audit) do
    %{
      auditor: audit.auditor,
      audit_type: audit.audit_type,
      result: audit.result,
      notes: audit.notes,
      report_url: audit.report_url,
      audit_date: audit.audit_date
    }
  end

  defp group_by_category(protocols) do
    protocols
    |> Enum.group_by(& &1.category)
    |> Enum.map(fn {category, list} -> {category, length(list)} end)
    |> Map.new()
  end

  defp group_by_status(protocols) do
    protocols
    |> Enum.group_by(& &1.verification_status)
    |> Enum.map(fn {status, list} -> {status, length(list)} end)
    |> Map.new()
  end
end
