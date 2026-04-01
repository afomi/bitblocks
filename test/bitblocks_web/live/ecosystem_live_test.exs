defmodule BitblocksWeb.EcosystemLiveTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders ecosystem view with service nodes", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/ecosystem")

    assert html =~ "BSV Ecosystem"
    assert html =~ "Services:"
    assert html =~ "Connections:"
  end

  test "renders legend with category colors", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/ecosystem")

    assert html =~ "Network"
    assert html =~ "Data"
    assert html =~ "Identity"
    assert html =~ "Token/Asset"
    assert html =~ "Infrastructure"
    assert html =~ "Deprecated"
  end

  test "loads ecosystem data after connect", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/ecosystem")

    # After the :load_ecosystem message processes, node_count should be > 0
    rendered = render(view)
    assert rendered =~ "Services:"
    # Static nodes include at least BSV, Bitcom, MAP, etc.
    refute rendered =~ "Services: <strong class=\"text-neutral-200\">0</strong>"
  end
end
