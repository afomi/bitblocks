defmodule BitblocksWeb.PricingLiveTest do
  use BitblocksWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "prices by consumption, with no unlimited plan", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/pricing")

    assert has_element?(view, "#pricing-free", "600/min")
    assert has_element?(view, "#pricing-consumption", "per request")
    refute html =~ "unlimited"
    refute html =~ "/mo"
  end
end
