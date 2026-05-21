defmodule BitblocksWeb.MetanetLiveTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Bitblocks.ProtocolRegistry

  setup do
    # Ensure Metanet protocol is seeded
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

  test "renders the Metanet explorer page with search form", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/metanet")

    assert html =~ "Metanet Explorer"
    assert html =~ "Enter a transaction ID"
  end

  test "shows error for unknown txid", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/metanet?txid=nonexistent_tx")

    rendered = render(view)
    assert rendered =~ "not found" or rendered =~ "not a Metanet node"
  end

  test "shows node data for a valid indexed Metanet node", %{conn: conn, protocol: protocol} do
    root_txid = String.duplicate("aa", 32)
    child_txid = String.duplicate("bb", 32)

    # Create root instance
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
          "name" => "test-root",
          "content_type" => "text/plain",
          "content" => "Hello from the Metanet"
        }
      })

    # Create child instance
    {:ok, _child} =
      ProtocolRegistry.create_instance(%{
        protocol_id: protocol.id,
        txid: child_txid,
        vout: 0,
        block_height: 101,
        parsed_data: %{
          "p_node" => "03" <> String.duplicate("dd", 32),
          "parent_txid" => root_txid,
          "is_root" => false,
          "name" => "test-child"
        }
      })

    {:ok, view, _html} = live(conn, "/metanet?txid=#{root_txid}")

    rendered = render(view)

    # Should show node name
    assert rendered =~ "test-root"
    # Should show root badge
    assert rendered =~ "root"
    # Should show content
    assert rendered =~ "Hello from the Metanet"
    # Should show child
    assert rendered =~ "test-child"
  end

  test "shows parent link for non-root node", %{conn: conn, protocol: protocol} do
    root_txid = String.duplicate("ee", 32)
    child_txid = String.duplicate("ff", 32)

    {:ok, _root} =
      ProtocolRegistry.create_instance(%{
        protocol_id: protocol.id,
        txid: root_txid,
        vout: 0,
        block_height: 100,
        parsed_data: %{
          "p_node" => "03" <> String.duplicate("11", 32),
          "parent_txid" => nil,
          "is_root" => true,
          "name" => "parent-root"
        }
      })

    {:ok, _child} =
      ProtocolRegistry.create_instance(%{
        protocol_id: protocol.id,
        txid: child_txid,
        vout: 0,
        block_height: 101,
        parsed_data: %{
          "p_node" => "03" <> String.duplicate("22", 32),
          "parent_txid" => root_txid,
          "is_root" => false,
          "name" => "child-page"
        }
      })

    {:ok, view, _html} = live(conn, "/metanet?txid=#{child_txid}")

    rendered = render(view)

    # Should show MURL breadcrumb
    assert rendered =~ "mnp://"
    assert rendered =~ "parent-root"
    assert rendered =~ "child-page"
    # Should show parent section
    assert rendered =~ "Parent"
  end

  test "submit form explores a new txid", %{conn: conn, protocol: protocol} do
    txid = String.duplicate("33", 32)

    {:ok, _instance} =
      ProtocolRegistry.create_instance(%{
        protocol_id: protocol.id,
        txid: txid,
        vout: 0,
        block_height: 100,
        parsed_data: %{
          "p_node" => "03" <> String.duplicate("44", 32),
          "parent_txid" => nil,
          "is_root" => true,
          "name" => "form-test-node"
        }
      })

    {:ok, view, _html} = live(conn, "/metanet")

    view
    |> form("form", %{"txid" => txid})
    |> render_submit()

    rendered = render(view)
    assert rendered =~ "form-test-node"
  end
end
