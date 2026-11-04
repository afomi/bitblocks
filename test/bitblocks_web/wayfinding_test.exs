defmodule BitblocksWeb.WayfindingTest do
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bitblocks.ProtocolRegistry

  test "the header keeps to blocks, transactions and about, and sends Transactions to the transactions list",
       %{conn: conn} do
    html = html_response(get(conn, "/"), 200)

    for {id, href} <- [
          {"nav-blocks", "/blocks"},
          {"nav-transactions", "/transactions"},
          {"nav-about", "/about"},
          {"nav-blocks-mobile", "/blocks"},
          {"nav-transactions-mobile", "/transactions"},
          {"nav-about-mobile", "/about"}
        ] do
      assert Regex.match?(
               ~r/id="#{id}"[^>]*href="#{Regex.escape(href)}"/,
               html
             ),
             "missing #{id} -> #{href}"
    end

    for id <- ~w(tokens order-book metanet bitcom collections),
        suffix <- ["", "-mobile"] do
      refute html =~ ~s(id="nav-#{id}#{suffix}"), "nav-#{id}#{suffix} should be off the header"
    end
  end

  test "the homepage features beta products below the recent blocks", %{conn: conn} do
    html = html_response(get(conn, "/"), 200)

    assert html =~ ~s(id="beta-features")
    assert html =~ "Beta"

    for {id, href} <- [
          {"beta-tokens", "/tokens"},
          {"beta-order-book", "/order-book"},
          {"beta-metanet", "/metanet"},
          {"beta-bitcom", "/bitcom"},
          {"beta-collections", "/collections"},
          {"beta-syncing", "/syncing"}
        ] do
      assert Regex.match?(
               ~r/id="#{id}"[^>]*href="#{Regex.escape(href)}"/,
               html
             ),
             "missing #{id} -> #{href}"
    end

    {recent, _} = :binary.match(html, "Recent Blocks")
    {beta, _} = :binary.match(html, ~s(id="beta-features"))
    assert beta > recent, "beta features should sit below the recent blocks"
  end

  test "the applications page describes on-chain apps", %{conn: conn} do
    html = html_response(get(conn, "/apps"), 200)

    assert html =~ "On-chain applications"
    assert html =~ "Tokens, the order book, Metanet, Bitcom, and collections are indexed here."
    refute html =~ "hexdocs.pm/phoenix"
  end

  test "metanet with no txid says when no roots are indexed", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/metanet")

    assert html =~ "No Metanet roots are indexed."
    refute html =~ "P_node"
  end

  test "metanet with no txid lists indexed roots", %{conn: conn} do
    protocol = metanet_protocol()
    txid = String.duplicate("ab", 32)

    {:ok, _} =
      ProtocolRegistry.create_instance(%{
        protocol_id: protocol.id,
        txid: txid,
        vout: 0,
        block_height: 50,
        parsed_data: %{
          "is_root" => true,
          "name" => "Album Root",
          "p_node" => "NULL"
        }
      })

    {:ok, _view, html} = live(conn, "/metanet")

    assert html =~ "Album Root"
    assert html =~ "/metanet?txid=#{txid}"
    refute html =~ "P_node"
  end

  test "a protocol example transaction opens on this site", %{conn: conn} do
    txid = String.duplicate("cd", 32)

    {:ok, protocol} =
      ProtocolRegistry.create_protocol(%{
        address: "1tokenordermetanetbitcomxx",
        name: "Wayfinding Example",
        category: :other,
        verification_status: :verified,
        description: "A protocol used to check the example link.",
        example_txid: txid
      })

    {:ok, view, _html} = live(conn, "/protocols")
    html = render_click(view, "select_protocol", %{"protocol" => to_string(protocol.id)})

    assert html =~ ~s(href="/transactions/#{txid}")
    refute html =~ "whatsonchain.com/tx/#{txid}"
  end

  defp metanet_protocol do
    ProtocolRegistry.get_protocol_by_name("Metanet") ||
      case ProtocolRegistry.create_protocol(%{
             address: "metanet",
             name: "Metanet",
             category: :data_storage,
             verification_status: :verified,
             description: "Metanet nodes"
           }) do
        {:ok, protocol} -> protocol
      end
  end

  test "home leaves node status to /status, and /status points to the live sync", %{conn: conn} do
    home = html_response(get(conn, "/"), 200)
    refute home =~ "RPC Node Status"
    assert home =~ ~s(href="/status")

    status = html_response(get(conn, "/status"), 200)
    assert Regex.match?(~r/id="status-live-sync"[^>]*href="\/syncing"/, status)
  end
end
