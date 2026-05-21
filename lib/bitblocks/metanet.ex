defmodule Bitblocks.Metanet do
  @moduledoc """
  Context module for Metanet DAG traversal.

  Provides functions to look up Metanet nodes, navigate parent-child
  relationships, and build MURL paths. Nodes are parsed from raw
  transaction data and cached in the `protocol_instances` table.
  """

  import Ecto.Query, warn: false

  alias Bitblocks.Repo
  alias Bitblocks.Chain.Transaction
  alias Bitblocks.ProtocolRegistry
  alias Bitblocks.ProtocolRegistry.Instance
  alias Bitblocks.MetanetParser

  @max_path_depth 20

  @doc """
  Gets a Metanet node by txid.

  Looks up the protocol instance first (cached).
  If not found, parses the raw transaction and indexes it.

  Returns a map with node data and txid, or nil.
  """
  def get_node(txid) when is_binary(txid) do
    case get_indexed_node(txid) do
      %{} = node ->
        node

      nil ->
        case index_node(txid) do
          {:ok, node} -> node
          _ -> nil
        end
    end
  end

  @doc """
  Gets the children of a Metanet node.

  Returns a list of child node maps, ordered by block height.
  """
  def get_children(txid) when is_binary(txid) do
    case get_metanet_protocol_id() do
      nil ->
        []

      protocol_id ->
        from(i in Instance,
          where: i.protocol_id == ^protocol_id,
          where: fragment("?->>'parent_txid' = ?", i.parsed_data, ^txid),
          order_by: [asc: i.block_height]
        )
        |> Repo.all()
        |> Enum.map(&instance_to_node/1)
    end
  end

  @doc """
  Gets the parent of a Metanet node.

  Returns the parent node map, or nil for root nodes.
  """
  def get_parent(txid) when is_binary(txid) do
    case get_node(txid) do
      %{parent_txid: nil} -> nil
      %{parent_txid: parent_txid} -> get_node(parent_txid)
      nil -> nil
    end
  end

  @doc """
  Walks from a node to the root, returning the path as a list ordered root-first.

  Stops at the root node or when the depth limit is reached.
  """
  def get_path_to_root(txid) when is_binary(txid) do
    do_walk_to_root(txid, [], 0)
  end

  @doc """
  Builds a MURL (Metanet URL) from a path of nodes.

  The path should be ordered root-first (as returned by `get_path_to_root/1`).
  Returns a string like `"mnp://root-name/child-name/grandchild-name"`.
  """
  def build_murl(path) when is_list(path) do
    segments =
      path
      |> Enum.map(fn node -> node[:name] || node[:txid_short] || "?" end)

    case segments do
      [] -> nil
      [root | rest] -> "mnp://#{root}/#{Enum.join(rest, "/")}"
    end
  end

  @doc """
  Returns all Metanet root nodes (nodes with no parent).
  """
  def get_roots do
    case get_metanet_protocol_id() do
      nil ->
        []

      protocol_id ->
        from(i in Instance,
          where: i.protocol_id == ^protocol_id,
          where: fragment("(?->>'is_root')::boolean = true", i.parsed_data),
          order_by: [desc: i.block_height],
          limit: 100
        )
        |> Repo.all()
        |> Enum.map(&instance_to_node/1)
    end
  end

  @doc """
  Parses and indexes a Metanet node from a raw transaction.

  Creates a protocol_instance record with the parsed data.
  Returns `{:ok, node_map}` or `{:error, reason}`.
  """
  def index_node(txid) when is_binary(txid) do
    with %Transaction{} = tx <- Repo.one(from(t in Transaction, where: t.txid == ^txid, limit: 1)),
         {:ok, parsed} <- MetanetParser.parse_transaction(tx),
         protocol_id when not is_nil(protocol_id) <- get_metanet_protocol_id() do
      # Find the OP_RETURN output index (usually 0)
      vout = find_op_return_vout(tx)

      attrs = %{
        protocol_id: protocol_id,
        txid: txid,
        vout: vout,
        block_height: tx.block_height,
        block_hash: tx.block_hash,
        parsed_data: %{
          "p_node" => parsed.p_node,
          "parent_txid" => parsed.parent_txid,
          "is_root" => parsed.is_root,
          "node_id" => parsed.node_id,
          "name" => parsed.name,
          "content_type" => parsed.content_type,
          "content" => parsed.content
        }
      }

      case ProtocolRegistry.create_instance(attrs) do
        {:ok, instance} ->
          {:ok, instance_to_node(instance)}

        {:error, %Ecto.Changeset{} = changeset} ->
          # If unique constraint violation, the instance already exists — fetch it
          if has_unique_error?(changeset) do
            case get_indexed_node(txid) do
              %{} = node -> {:ok, node}
              nil -> {:error, :index_failed}
            end
          else
            {:error, :index_failed}
          end
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Private ----------------------------------------------------------------

  defp get_indexed_node(txid) do
    case get_metanet_protocol_id() do
      nil ->
        nil

      protocol_id ->
        instance =
          from(i in Instance,
            where: i.protocol_id == ^protocol_id and i.txid == ^txid,
            limit: 1
          )
          |> Repo.one()

        if instance, do: instance_to_node(instance), else: nil
    end
  end

  defp instance_to_node(%Instance{} = i) do
    pd = i.parsed_data || %{}

    %{
      txid: i.txid,
      txid_short: String.slice(i.txid || "", 0, 12),
      block_height: i.block_height,
      p_node: pd["p_node"],
      parent_txid: pd["parent_txid"],
      is_root: pd["is_root"] || false,
      node_id: pd["node_id"],
      name: pd["name"],
      content_type: pd["content_type"],
      content: pd["content"]
    }
  end

  defp do_walk_to_root(_txid, path, depth) when depth >= @max_path_depth, do: path

  defp do_walk_to_root(txid, path, depth) do
    case get_node(txid) do
      nil ->
        path

      %{is_root: true} = node ->
        [node | path]

      %{parent_txid: nil} = node ->
        [node | path]

      %{parent_txid: parent_txid} = node ->
        do_walk_to_root(parent_txid, [node | path], depth + 1)
    end
  end

  defp get_metanet_protocol_id do
    case ProtocolRegistry.get_protocol_by_name("Metanet") do
      nil -> nil
      protocol -> protocol.id
    end
  end

  defp find_op_return_vout(%Transaction{outputs: outputs}) when is_list(outputs) do
    Enum.find_index(outputs, fn output_str ->
      case Jason.decode(output_str) do
        {:ok, %{"scriptPubKey" => %{"type" => "nulldata"}}} -> true
        _ -> false
      end
    end) || 0
  end

  defp find_op_return_vout(_), do: 0

  defp has_unique_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} when is_list(opts) ->
        Keyword.get(opts, :constraint) == :unique

      _ ->
        false
    end)
  end
end
