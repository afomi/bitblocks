defmodule BitblocksWeb.ShapeLayerLiveTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders shape layer viewer with geometry", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/shape-layers")

    assert html =~ "Shape Layer NFTs"
    assert html =~ "GeoJSON"
    assert html =~ "Geometry"
    assert html =~ "Properties"
  end

  test "displays bounds and center for selected shape", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/shape-layers")

    assert html =~ "Center"
    assert html =~ "Bounds"
    assert html =~ "Block Height"
  end

  test "can select a different shape", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/shape-layers")

    rendered =
      view
      |> element("button[phx-value-index='1']")
      |> render_click()

    assert rendered =~ "Empire State Building"
    assert rendered =~ "Point"
  end

  test "renders SVG geometry for polygon shape", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/shape-layers")

    # Default shape (index 0) is a polygon
    assert html =~ "<polygon"
    assert html =~ "San Francisco"
  end
end
