defmodule BitblocksWeb.AccessibilityTest do
  use BitblocksWeb.ConnCase
  import BitblocksWeb.AccessibilityCase
  import Bitblocks.ChainFixtures

  # Bypass basic auth for testing
  setup %{conn: conn} do
    conn =
      Plug.Conn.put_req_header(conn, "authorization", "Basic " <> Base.encode64("admin:secret"))

    {:ok, conn: conn}
  end

  describe "accessibility scanning" do
    test "home page is accessible", %{conn: conn} do
      conn = get(conn, ~p"/")
      html = html_response(conn, 200)
      assert_accessible(html, "Home page")
    end

    test "status page is accessible", %{conn: conn} do
      conn = get(conn, ~p"/status")
      html = html_response(conn, 200)
      assert_accessible(html, "Status page")
    end

    test "blocks index page is accessible", %{conn: conn} do
      conn = get(conn, ~p"/blocks")
      html = html_response(conn, 200)
      assert_accessible(html, "Blocks index page")
    end

    test "block show page is accessible", %{conn: conn} do
      block = block_fixture()
      conn = get(conn, ~p"/blocks/#{block.height}")
      html = html_response(conn, 200)
      assert_accessible(html, "Block show page")
    end

    test "transactions index page is accessible", %{conn: conn} do
      conn = get(conn, ~p"/transactions")
      html = html_response(conn, 200)
      assert_accessible(html, "Transactions index page")
    end

    test "transaction show page is accessible", %{conn: conn} do
      block = block_fixture()
      transaction = transaction_fixture(%{block_height: block.height})
      conn = get(conn, ~p"/transactions/#{transaction.txid}")
      html = html_response(conn, 200)
      assert_accessible(html, "Transaction show page")
    end

    test "sync page is accessible", %{conn: conn} do
      conn = get(conn, ~p"/sync")
      html = html_response(conn, 200)
      assert_accessible(html, "Sync page")
    end

    test "protocols page is accessible", %{conn: conn} do
      conn = get(conn, ~p"/protocols")
      html = html_response(conn, 200)
      assert_accessible(html, "Protocols page")
    end

    test "graph page is accessible", %{conn: conn} do
      conn = get(conn, ~p"/graph")
      html = html_response(conn, 200)
      assert_accessible(html, "Graph page")
    end

    test "highlights page is accessible", %{conn: conn} do
      conn = get(conn, ~p"/highlights")
      html = html_response(conn, 200)
      assert_accessible(html, "Highlights page")
    end

    test "search page is accessible", %{conn: conn} do
      conn = get(conn, ~p"/search")
      html = html_response(conn, 200)
      assert_accessible(html, "Search page")
    end

    test "builder page is accessible", %{conn: conn} do
      conn = get(conn, ~p"/builder")
      html = html_response(conn, 200)
      assert_accessible(html, "Builder page")
    end

    test "config page is accessible", %{conn: conn} do
      conn = get(conn, ~p"/config")
      html = html_response(conn, 200)
      assert_accessible(html, "Config page")
    end
  end
end
