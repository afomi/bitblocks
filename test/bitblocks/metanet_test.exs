defmodule Bitblocks.MetanetTest do
  use Bitblocks.DataCase

  alias Bitblocks.Metanet
  alias Bitblocks.ProtocolRegistry

  # Ensure the Metanet protocol is seeded
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

  describe "get_children/1" do
    test "returns children for a parent txid", %{protocol: protocol} do
      parent_txid = String.duplicate("aa", 32)

      # Create a child instance
      {:ok, _child} =
        ProtocolRegistry.create_instance(%{
          protocol_id: protocol.id,
          txid: String.duplicate("bb", 32),
          vout: 0,
          block_height: 100,
          parsed_data: %{
            "parent_txid" => parent_txid,
            "p_node" => "03" <> String.duplicate("cc", 32),
            "is_root" => false,
            "name" => "child-page"
          }
        })

      children = Metanet.get_children(parent_txid)

      assert length(children) == 1
      child = hd(children)
      assert child.name == "child-page"
      assert child.parent_txid == parent_txid
    end

    test "returns empty list when no children exist" do
      assert Metanet.get_children(String.duplicate("ff", 32)) == []
    end
  end

  describe "build_murl/1" do
    test "builds mnp:// path from root-first node list" do
      path = [
        %{name: "bobsblog", txid_short: "aaa"},
        %{name: "summer", txid_short: "bbb"},
        %{name: "beaches", txid_short: "ccc"}
      ]

      assert Metanet.build_murl(path) == "mnp://bobsblog/summer/beaches"
    end

    test "uses txid_short when name is missing" do
      path = [
        %{name: nil, txid_short: "abc123"},
        %{name: "page", txid_short: "def456"}
      ]

      assert Metanet.build_murl(path) == "mnp://abc123/page"
    end

    test "returns nil for empty path" do
      assert Metanet.build_murl([]) == nil
    end
  end

  describe "get_node/1" do
    test "returns nil for non-existent txid" do
      assert Metanet.get_node("nonexistent") == nil
    end

    test "returns indexed node from protocol_instances", %{protocol: protocol} do
      txid = String.duplicate("dd", 32)

      {:ok, _instance} =
        ProtocolRegistry.create_instance(%{
          protocol_id: protocol.id,
          txid: txid,
          vout: 0,
          block_height: 200,
          parsed_data: %{
            "p_node" => "03" <> String.duplicate("ee", 32),
            "parent_txid" => nil,
            "is_root" => true,
            "name" => "my-root"
          }
        })

      node = Metanet.get_node(txid)

      assert node.txid == txid
      assert node.name == "my-root"
      assert node.is_root == true
      assert node.parent_txid == nil
    end
  end

  describe "get_path_to_root/1" do
    test "returns path from leaf to root", %{protocol: protocol} do
      root_txid = String.duplicate("11", 32)
      child_txid = String.duplicate("22", 32)

      {:ok, _root} =
        ProtocolRegistry.create_instance(%{
          protocol_id: protocol.id,
          txid: root_txid,
          vout: 0,
          block_height: 100,
          parsed_data: %{
            "p_node" => "03" <> String.duplicate("aa", 32),
            "parent_txid" => nil,
            "is_root" => true,
            "name" => "root-site"
          }
        })

      {:ok, _child} =
        ProtocolRegistry.create_instance(%{
          protocol_id: protocol.id,
          txid: child_txid,
          vout: 0,
          block_height: 101,
          parsed_data: %{
            "p_node" => "03" <> String.duplicate("bb", 32),
            "parent_txid" => root_txid,
            "is_root" => false,
            "name" => "my-page"
          }
        })

      path = Metanet.get_path_to_root(child_txid)

      assert length(path) == 2
      assert hd(path).name == "root-site"
      assert List.last(path).name == "my-page"
    end
  end
end
