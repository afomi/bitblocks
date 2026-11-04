defmodule BitblocksWeb.ReorgLiveTest do
  # The LiveView process has to see rows inserted by the test.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bitblocks.Reorgs
  alias BitblocksWeb.ReorgNotice

  test "a failed reorg query leaves the notice off the page" do
    assert ReorgNotice.current(fn -> raise "relation \"reorgs\" does not exist" end) == nil
  end

  test "the timeline explains itself when nothing has been recorded", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/reorgs")

    assert html =~ "Chain reorganizations"
    assert html =~ "No reorganization has been recorded yet."
    refute html =~ "id=\"reorg-notice\""
  end

  test "a recorded reorg is an annotation on the timeline", %{conn: conn} do
    {:ok, reorg} =
      Reorgs.record_observed(
        %{
          fork_height: 800_000,
          fork_point: 799_998,
          orphan_count: 2,
          outcome: "resolved"
        },
        DateTime.utc_now() |> DateTime.truncate(:second)
      )

    {:ok, _view, html} = live(conn, ~p"/reorgs")

    assert html =~ "id=\"reorg-#{reorg.id}\""
    assert html =~ "800000"
    assert html =~ "799998"
    assert html =~ "2 blocks"
    assert html =~ "id=\"reorg-notice\""
    refute html =~ "No reorganization has been recorded yet."
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

  test "an old resolved reorg stays on the timeline and leaves the banner", %{conn: conn} do
    {:ok, reorg} =
      Reorgs.record_observed(
        %{fork_height: 654_321, fork_point: 654_311, orphan_count: 10, outcome: "resolved"},
        ~U[2020-01-01 00:00:00Z]
      )

    {:ok, _view, html} = live(conn, ~p"/reorgs")

    assert html =~ "id=\"reorg-#{reorg.id}\""
    assert html =~ "654321"
    refute html =~ "id=\"reorg-notice\""
  end

  test "a fork a later run resolved reads as resolved, not as needing a person", %{conn: conn} do
    first = ~U[2026-11-03 23:50:00Z]

    {:ok, stale} =
      Reorgs.record_observed(%{fork_height: 957_302, outcome: "needs_attention"}, first)

    {:ok, resolved} =
      Reorgs.record_observed(
        %{fork_height: 957_302, fork_point: 957_300, orphan_count: 1, outcome: "resolved"},
        ~U[2026-11-04 00:56:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/reorgs")

    refute has_element?(view, "#reorg-#{stale.id}", "Needs a person")
    assert has_element?(view, "#reorg-#{stale.id}", "Resolved later")
    assert has_element?(view, ~s(#reorg-#{stale.id} a[href="#reorg-#{resolved.id}"]))
    assert has_element?(view, "#reorg-#{resolved.id}", "Headers realigned")
  end

  test "a fork nothing resolved still needs a person", %{conn: conn} do
    {:ok, open} =
      Reorgs.record_observed(
        %{fork_height: 900_000, outcome: "needs_attention"},
        ~U[2026-11-04 00:00:00Z]
      )

    {:ok, _} =
      Reorgs.record_observed(
        %{fork_height: 800_000, fork_point: 799_999, orphan_count: 1, outcome: "resolved"},
        ~U[2026-11-04 01:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/reorgs")
    assert has_element?(view, "#reorg-#{open.id}", "Needs a person")
  end
end
