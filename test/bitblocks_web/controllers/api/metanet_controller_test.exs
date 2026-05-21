defmodule BitblocksWeb.Api.MetanetControllerTest do
  use BitblocksWeb.ConnCase

  alias Bitblocks.ProtocolRegistry

  setup do
    case ProtocolRegistry.get_protocol_by_name("Metanet") do
      nil ->
        {:ok, protocol} =
          ProtocolRegistry.create_protocol(%{
            address: "meta",
            name: "Metanet",
            category: :data_storage,
            verification_status: :verified,
            description: "Metanet protocol"
          })

        %{protocol: protocol}

      protocol ->
        %{protocol: protocol}
    end
  end

  describe "GET /api/v1/metanet/:txid" do
    test "returns 404 for unknown txid", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/metanet/nonexistent_txid")

      assert json_response(conn, 404)["error"] =~ "not found"
    end

    test "returns structured node data", %{conn: conn, protocol: protocol} do
      root_txid = String.duplicate("aa", 32)
      child_txid = String.duplicate("bb", 32)

      {:ok, _root} =
        ProtocolRegistry.create_instance(%{
          protocol_id: protocol.id,
          txid: root_txid,
          vout: 0,
          block_height: 100,
          parsed_data: %{
            "p_node" => "03" <> String.duplicate("cc", 32),
            "parent_txid" => nil,
            "is_root" => true,
            "node_id" => String.duplicate("dd", 32),
            "name" => "api-root",
            "content_type" => "text/plain",
            "content" => "test content"
          }
        })

      {:ok, _child} =
        ProtocolRegistry.create_instance(%{
          protocol_id: protocol.id,
          txid: child_txid,
          vout: 0,
          block_height: 101,
          parsed_data: %{
            "p_node" => "03" <> String.duplicate("ee", 32),
            "parent_txid" => root_txid,
            "is_root" => false,
            "name" => "api-child"
          }
        })

      conn = get(conn, ~p"/api/v1/metanet/#{root_txid}")

      response = json_response(conn, 200)

      assert response["data"]["txid"] == root_txid
      assert response["data"]["name"] == "api-root"
      assert response["data"]["is_root"] == true
      assert response["data"]["content"] == "test content"
      assert response["parent"] == nil
      assert length(response["children"]) == 1
      assert hd(response["children"])["name"] == "api-child"
      assert response["murl"] =~ "mnp://"
    end
  end

  describe "GET /api/v1/metanet/:txid/children" do
    test "returns children for a node", %{conn: conn, protocol: protocol} do
      parent_txid = String.duplicate("11", 32)

      {:ok, _parent} =
        ProtocolRegistry.create_instance(%{
          protocol_id: protocol.id,
          txid: parent_txid,
          vout: 0,
          block_height: 100,
          parsed_data: %{
            "p_node" => "03" <> String.duplicate("22", 32),
            "parent_txid" => nil,
            "is_root" => true,
            "name" => "parent"
          }
        })

      {:ok, _child} =
        ProtocolRegistry.create_instance(%{
          protocol_id: protocol.id,
          txid: String.duplicate("33", 32),
          vout: 0,
          block_height: 101,
          parsed_data: %{
            "p_node" => "03" <> String.duplicate("44", 32),
            "parent_txid" => parent_txid,
            "is_root" => false,
            "name" => "child-one"
          }
        })

      conn = get(conn, ~p"/api/v1/metanet/#{parent_txid}/children")

      response = json_response(conn, 200)
      assert length(response["data"]) == 1
      assert hd(response["data"])["name"] == "child-one"
    end
  end

  describe "GET /api/v1/metanet/roots" do
    test "returns root nodes", %{conn: conn, protocol: protocol} do
      {:ok, _root} =
        ProtocolRegistry.create_instance(%{
          protocol_id: protocol.id,
          txid: String.duplicate("55", 32),
          vout: 0,
          block_height: 100,
          parsed_data: %{
            "p_node" => "03" <> String.duplicate("66", 32),
            "parent_txid" => nil,
            "is_root" => true,
            "name" => "root-node"
          }
        })

      conn = get(conn, ~p"/api/v1/metanet/roots")

      response = json_response(conn, 200)
      root_names = Enum.map(response["data"], & &1["name"])
      assert "root-node" in root_names
    end
  end
end
