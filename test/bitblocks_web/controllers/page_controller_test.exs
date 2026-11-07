defmodule BitblocksWeb.PageControllerTest do
  use BitblocksWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Find a transaction or block"
    assert response =~ "Transaction types"
    assert response =~ "Node status"
  end

  test "the homepage leads with search, as a form that submits without JS", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    [form] = html |> Floki.parse_document!() |> Floki.find("#home-search-form")

    assert Floki.attribute(form, "action") == ["/search"]
    assert Floki.attribute(form, "method") == ["get"]
    assert form |> Floki.find("input[name=query]") |> length() == 1
    assert form |> Floki.find("button[type=submit]") |> length() == 1
  end

  test "the homepage drops the duplicate wordmark and links nothing admin-only", %{conn: conn} do
    doc = conn |> get(~p"/") |> html_response(200) |> Floki.parse_document!()

    refute doc |> Floki.find("h1") |> Floki.text() =~ "Bitblocks"
    refute doc |> Floki.find("main a[href='/graph']") |> Enum.any?()
  end

  # #44: /status leads with the same answer as /api/v1/status. Whether the
  # test node reads up or down depends on RpcCache, so either is accepted;
  # the wording for each is pinned in health_line_test.exs.
  test "/status leads with the health sentence and never an empty node card", %{conn: conn} do
    doc = conn |> get(~p"/status") |> html_response(200) |> Floki.parse_document!()
    line = doc |> Floki.find("#status-health") |> Floki.text()

    assert line =~ "The sync is" or line =~ "The sync has stalled"
    assert line =~ "Our node is up" or line =~ "Node unreachable" or line =~ "warming up"

    if line =~ "Node unreachable" do
      assert doc |> Floki.find("#status-node-down") |> Floki.text() =~ "Node unreachable"
    end
  end

  describe "the banner" do
    test "states the indexed height and how long ago that block was", %{conn: conn} do
      Bitblocks.ChainFixtures.block_fixture(%{
        height: 0,
        sync_state: "completed",
        time: System.system_time(:second) - 3 * 3_600
      })

      Bitblocks.SyncProgress.refresh()

      text =
        conn
        |> get(~p"/")
        |> html_response(200)
        |> Floki.parse_document!()
        |> Floki.find("#banner-text")
        |> Floki.text()
        |> String.replace(~r/\s+/, " ")

      assert text =~ "Every transaction is stored through block 0, mined 3 hours ago."
    end

    test "names no milestone or month", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      for stale <- ["June 2026", "November 2026", "700,000", "900,000"] do
        refute html =~ stale
      end
    end

    test "reads whole units", _context do
      assert BitblocksWeb.IndexNotice.span(30) == "moments"
      assert BitblocksWeb.IndexNotice.span(60) == "1 minute"
      assert BitblocksWeb.IndexNotice.span(86_400 * 2) == "2 days"
      assert BitblocksWeb.IndexNotice.span(86_400 * 365 * 13) == "13 years"
    end
  end

  test "the homepage names the endpoints a program would call", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(id="use-the-data")
    assert html =~ "GET /api/v1/txs/:txid/proof"
    assert html =~ "GET /api/v1/script/:scripthash/history"
    assert html =~ "GET /api/v1/stream/blocks"
  end
end
