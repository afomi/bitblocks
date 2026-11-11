defmodule BitblocksWeb.ReorgLiveTest do
  # The LiveView process has to see rows inserted by the test.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bitblocks.Reorgs
  alias BitblocksWeb.ReorgNotice

  test "a failed reorg query leaves the notice off the page" do
    assert ReorgNotice.current(fn -> raise "relation \"reorgs\" does not exist" end) == nil
  end

  test "the page explains what a reorganization is and what happens", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/reorgs")

    assert html =~ "Chain reorganizations"
    assert html =~ "the branch with the most work"
    assert has_element?(view, "#reorg-what-happens", "confirmation")
    refute html =~ "id=\"reorg-notice\""
  end

  test "the page is instructional only: recorded reorgs are not listed", %{conn: conn} do
    {:ok, reorg} =
      Reorgs.record_observed(
        %{fork_height: 654_321, fork_point: 654_311, orphan_count: 10, outcome: "resolved"},
        ~U[2020-01-01 00:00:00Z]
      )

    {:ok, _view, html} = live(conn, ~p"/reorgs")

    refute html =~ "id=\"reorg-#{reorg.id}\""
    refute html =~ "654321"
  end

  test "a fresh reorg is announced on other pages", %{conn: conn} do
    {:ok, _} =
      Reorgs.record_observed(
        %{
          fork_height: 800_010,
          fork_point: nil,
          orphan_count: nil,
          outcome: "needs_attention"
        },
        DateTime.utc_now() |> DateTime.truncate(:second)
      )

    {:ok, _view, html} = live(conn, ~p"/guide")

    assert html =~ "id=\"reorg-notice\""
    assert html =~ "800010"
    assert html =~ "A chain reorganization needs a person."
    assert html =~ ~s(href="/reorgs")
  end
end
