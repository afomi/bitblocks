defmodule BitblocksWeb.PageControllerTest do
  use BitblocksWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Find a transaction or block"
    assert response =~ "Bitcoin Protocols"
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

  test "the homepage names the endpoints a program would call", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(id="use-the-data")
    assert html =~ "GET /api/v1/txs/:txid/proof"
    assert html =~ "GET /api/v1/script/:scripthash/history"
    assert html =~ "GET /api/v1/stream/blocks"
  end
end
