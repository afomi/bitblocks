defmodule BitblocksWeb.Api.MetanetController do
  use BitblocksWeb, :controller

  alias Bitblocks.Metanet

  action_fallback BitblocksWeb.FallbackController

  @doc """
  Get a Metanet node by txid, with parent, children, and path.

  GET /api/v1/metanet/:txid
  """
  def show(conn, %{"txid" => txid}) do
    case Metanet.get_node(txid) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Metanet node not found", txid: txid})

      node ->
        parent = Metanet.get_parent(txid)
        children = Metanet.get_children(txid)
        path = Metanet.get_path_to_root(txid)
        murl = Metanet.build_murl(path)

        json(conn, %{
          data: node_to_json(node),
          parent: if(parent, do: node_to_json(parent), else: nil),
          children: Enum.map(children, &node_to_json/1),
          path: Enum.map(path, &node_to_json/1),
          murl: murl
        })
    end
  end

  @doc """
  Get children of a Metanet node.

  GET /api/v1/metanet/:txid/children
  """
  def children(conn, %{"txid" => txid}) do
    case Metanet.get_node(txid) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Metanet node not found", txid: txid})

      _node ->
        children = Metanet.get_children(txid)

        json(conn, %{
          data: Enum.map(children, &node_to_json/1),
          parent_txid: txid
        })
    end
  end

  @doc """
  List Metanet root nodes (orphan nodes with no parent).

  GET /api/v1/metanet/roots
  """
  def roots(conn, _params) do
    roots = Metanet.get_roots()

    json(conn, %{
      data: Enum.map(roots, &node_to_json/1)
    })
  end

  defp node_to_json(node) do
    %{
      txid: node[:txid],
      block_height: node[:block_height],
      p_node: node[:p_node],
      parent_txid: node[:parent_txid],
      is_root: node[:is_root],
      node_id: node[:node_id],
      name: node[:name],
      content_type: node[:content_type],
      content: node[:content]
    }
  end
end
