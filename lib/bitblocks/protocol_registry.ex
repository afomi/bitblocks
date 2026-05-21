defmodule Bitblocks.ProtocolRegistry do
  @moduledoc """
  Context module for the Protocol Registry.

  Provides functions to register, discover, and query Bitcoin protocols.
  Supports both OP_RETURN data protocols and covenant-enforced protocols.
  """

  import Ecto.Query, warn: false
  alias Bitblocks.Repo

  alias Bitblocks.ProtocolRegistry.{Protocol, ProtocolStats, Audit, Instance}

  # ============================================================================
  # Protocol CRUD
  # ============================================================================

  @doc """
  Returns all registered protocols with optional filters.

  ## Options

    * `:category` - Filter by protocol category
    * `:verification_status` - Filter by verification status
    * `:has_covenant` - Filter by covenant enforcement (boolean)
    * `:search` - Search by name or address
    * `:limit` - Maximum number of results
    * `:offset` - Offset for pagination

  ## Examples

      iex> list_protocols()
      [%Protocol{}, ...]

      iex> list_protocols(category: :consumable, verification_status: :verified)
      [%Protocol{}, ...]

  """
  def list_protocols(opts \\ []) do
    query = from(p in Protocol, order_by: [desc: p.inserted_at])

    query
    |> apply_protocol_filters(opts)
    |> apply_pagination(opts)
    |> Repo.all()
  end

  defp apply_protocol_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:category, category}, q when not is_nil(category) ->
        from p in q, where: p.category == ^category

      {:verification_status, status}, q when not is_nil(status) ->
        from p in q, where: p.verification_status == ^status

      {:has_covenant, has_covenant}, q when is_boolean(has_covenant) ->
        from p in q, where: p.has_covenant == ^has_covenant

      {:search, search}, q when is_binary(search) and search != "" ->
        like_pattern = "%#{search}%"
        from p in q, where: ilike(p.name, ^like_pattern) or ilike(p.address, ^like_pattern)

      _, q ->
        q
    end)
  end

  defp apply_pagination(query, opts) do
    query
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: from(p in query, limit: ^limit)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, offset), do: from(p in query, offset: ^offset)

  @doc """
  Gets a protocol by ID.

  Raises `Ecto.NoResultsError` if the protocol does not exist.
  """
  def get_protocol!(id), do: Repo.get!(Protocol, id)

  @doc """
  Gets a protocol by ID, returns nil if not found.
  """
  def get_protocol(id), do: Repo.get(Protocol, id)

  @doc """
  Gets a protocol by its Bitcom-style address.

  ## Examples

      iex> get_protocol_by_address("19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut")
      %Protocol{name: "B://", ...}

      iex> get_protocol_by_address("unknown")
      nil

  """
  def get_protocol_by_address(address, version \\ nil) do
    query = from p in Protocol, where: p.address == ^address

    query =
      if version do
        from p in query, where: p.version == ^version
      else
        from p in query, order_by: [desc: p.version], limit: 1
      end

    Repo.one(query)
  end

  @doc """
  Gets a protocol by name.
  """
  def get_protocol_by_name(name, version \\ nil) do
    query = from p in Protocol, where: p.name == ^name

    query =
      if version do
        from p in query, where: p.version == ^version
      else
        from p in query, order_by: [desc: p.version], limit: 1
      end

    Repo.one(query)
  end

  @doc """
  Creates a new protocol.

  ## Examples

      iex> create_protocol(%{address: "1...", name: "MyProtocol"})
      {:ok, %Protocol{}}

      iex> create_protocol(%{address: "invalid"})
      {:error, %Ecto.Changeset{}}

  """
  def create_protocol(attrs \\ %{}) do
    %Protocol{}
    |> Protocol.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a protocol.
  """
  def update_protocol(%Protocol{} = protocol, attrs) do
    protocol
    |> Protocol.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a protocol.
  """
  def delete_protocol(%Protocol{} = protocol) do
    Repo.delete(protocol)
  end

  @doc """
  Returns the count of registered protocols.
  """
  def count_protocols(opts \\ []) do
    query = from(p in Protocol)

    query
    |> apply_protocol_filters(opts)
    |> Repo.aggregate(:count, :id)
  end

  # ============================================================================
  # Protocol Detection
  # ============================================================================

  @doc """
  Identifies a protocol from OP_RETURN data.

  Takes the first chunk of OP_RETURN data (typically a Bitcom address)
  and looks it up in the registry.

  ## Examples

      iex> identify_protocol("19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut")
      {:ok, %Protocol{name: "B://", ...}}

      iex> identify_protocol("unknown")
      {:error, :not_found}

  """
  def identify_protocol(first_chunk) when is_binary(first_chunk) do
    case get_protocol_by_address(first_chunk) do
      nil -> {:error, :not_found}
      protocol -> {:ok, protocol}
    end
  end

  @doc """
  Identifies all protocols from a list of OP_RETURN outputs.

  Returns a list of {output_index, protocol} tuples.
  """
  def identify_protocols_in_outputs(op_return_outputs) when is_list(op_return_outputs) do
    op_return_outputs
    |> Enum.map(fn op_return ->
      first_chunk = get_first_chunk(op_return)

      case identify_protocol(first_chunk) do
        {:ok, protocol} -> {op_return[:output_index], protocol}
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp get_first_chunk(%{data: [%{utf8: utf8} | _]}) when is_binary(utf8), do: utf8
  defp get_first_chunk(%{data: [%{hex: hex} | _]}) when is_binary(hex), do: hex
  defp get_first_chunk(_), do: ""

  # ============================================================================
  # Protocol Statistics
  # ============================================================================

  @doc """
  Gets all-time statistics for a protocol.
  """
  def get_protocol_stats(protocol_id) do
    query =
      from s in ProtocolStats,
        where: s.protocol_id == ^protocol_id and s.period == "all_time"

    Repo.one(query)
  end

  @doc """
  Gets statistics for a protocol by period.
  """
  def get_protocol_stats(protocol_id, period, period_start \\ nil) do
    query =
      from s in ProtocolStats,
        where: s.protocol_id == ^protocol_id and s.period == ^period

    query =
      if period_start do
        from s in query, where: s.period_start == ^period_start
      else
        query
      end

    Repo.one(query)
  end

  @doc """
  Increments protocol statistics for a new instance.
  """
  def increment_protocol_stats(protocol_id, attrs \\ %{}) do
    now = DateTime.utc_now()
    today = Date.utc_today()

    # Upsert all-time stats
    upsert_stats(protocol_id, "all_time", nil, attrs, now)

    # Upsert daily stats
    upsert_stats(protocol_id, "daily", today, attrs, now)

    # Upsert weekly stats (start of week)
    week_start = Date.beginning_of_week(today, :monday)
    upsert_stats(protocol_id, "weekly", week_start, attrs, now)

    # Upsert monthly stats (start of month)
    month_start = Date.beginning_of_month(today)
    upsert_stats(protocol_id, "monthly", month_start, attrs, now)

    :ok
  end

  defp upsert_stats(protocol_id, period, period_start, attrs, now) do
    txid = attrs[:txid]
    satoshis = attrs[:satoshis] || 0

    case get_protocol_stats(protocol_id, period, period_start) do
      nil ->
        %ProtocolStats{}
        |> ProtocolStats.changeset(%{
          protocol_id: protocol_id,
          period: period,
          period_start: period_start,
          instance_count: 1,
          transaction_count: 1,
          total_satoshis: satoshis,
          first_seen_txid: txid,
          first_seen_at: now,
          last_seen_txid: txid,
          last_seen_at: now
        })
        |> Repo.insert()

      stats ->
        stats
        |> ProtocolStats.changeset(%{
          instance_count: stats.instance_count + 1,
          transaction_count: stats.transaction_count + 1,
          total_satoshis: stats.total_satoshis + satoshis,
          last_seen_txid: txid,
          last_seen_at: now
        })
        |> Repo.update()
    end
  end

  # ============================================================================
  # Protocol Instances
  # ============================================================================

  @doc """
  Creates a new protocol instance.
  """
  def create_instance(attrs \\ %{}) do
    %Instance{}
    |> Instance.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets an instance by txid and vout.
  """
  def get_instance(txid, vout) do
    Repo.get_by(Instance, txid: txid, vout: vout)
  end

  @doc """
  Lists instances for a protocol with pagination.
  """
  def list_instances(protocol_id, opts \\ []) do
    query =
      from i in Instance,
        where: i.protocol_id == ^protocol_id,
        order_by: [desc: i.block_height, desc: i.id]

    query
    |> apply_pagination(opts)
    |> Repo.all()
  end

  @doc """
  Marks an instance as spent.
  """
  def mark_instance_spent(txid, vout, spent_txid) do
    case get_instance(txid, vout) do
      nil ->
        {:error, :not_found}

      instance ->
        instance
        |> Instance.changeset(%{spent: true, spent_txid: spent_txid})
        |> Repo.update()
    end
  end

  # ============================================================================
  # Audits
  # ============================================================================

  @doc """
  Creates an audit record for a protocol.
  """
  def create_audit(attrs \\ %{}) do
    %Audit{}
    |> Audit.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists audits for a protocol.
  """
  def list_audits(protocol_id) do
    query =
      from a in Audit,
        where: a.protocol_id == ^protocol_id,
        order_by: [desc: a.audit_date]

    Repo.all(query)
  end

  # ============================================================================
  # Seeding / Built-in Protocols
  # ============================================================================

  @doc """
  Seeds the registry with well-known protocols.

  These are existing Bitcom protocols that are widely used.
  """
  def seed_builtin_protocols do
    builtins = [
      %{
        address: "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut",
        name: "B://",
        category: :data_storage,
        verification_status: :verified,
        description: "Store complete files directly on the blockchain with content addressing.",
        documentation_url: "https://b.bitdb.network/",
        author: "unwriter"
      },
      %{
        address: "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5",
        name: "MAP",
        category: :data_storage,
        verification_status: :verified,
        description:
          "Magic Attribute Protocol: Store key-value metadata for any on-chain content.",
        documentation_url: "https://github.com/rohenaz/MAP",
        author: "rohenaz"
      },
      %{
        address: "15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva",
        name: "AIP",
        category: :identity,
        verification_status: :verified,
        description: "Author Identity Protocol: Sign content on-chain to prove authorship.",
        author: "unwriter"
      },
      %{
        address: "1HA1P2exomAwCUycZHr8WeyFoy5vuQASE3",
        name: "HAIP",
        category: :identity,
        verification_status: :verified,
        description: "Hash Author Identity Protocol: Hash-based verification for data integrity.",
        author: "unwriter"
      },
      %{
        address: "meta",
        name: "Metanet",
        category: :data_storage,
        verification_status: :verified,
        description:
          "Metanet protocol: a directed acyclic graph (DAG) layered on BSV transactions for on-chain content hierarchies.",
        documentation_url: "https://metanet.planaria.network/",
        author: "nchain"
      }
    ]

    Enum.each(builtins, fn attrs ->
      case get_protocol_by_address(attrs.address) do
        nil -> create_protocol(attrs)
        _existing -> :ok
      end
    end)

    :ok
  end
end
