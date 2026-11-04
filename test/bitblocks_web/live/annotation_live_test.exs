defmodule BitblocksWeb.AnnotationLiveTest do
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bitblocks.Annotations

  test "adds an annotation by date", %{conn: conn} do
    {:ok, view, html} = live(conn, "/annotations")
    assert html =~ "No annotations yet."

    view
    |> form("#annotation-form",
      annotation: %{kind: "world", title: "Mt. Gox halts withdrawals", when: "2014-02-07"}
    )
    |> render_submit()

    [a] = Annotations.list()
    assert a.occurred_at == ~U[2014-02-07 00:00:00Z]
    assert has_element?(view, "#annotation-#{a.id}", "Mt. Gox halts withdrawals")
    assert has_element?(view, "#annotation-notice")
  end

  test "shows what's missing instead of saving", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/annotations")

    html =
      view |> form("#annotation-form", annotation: %{kind: "note", title: "x"}) |> render_submit()

    assert html =~ "set a height, a txid or a date"
    assert Annotations.list() == []
  end

  test "edits and deletes", %{conn: conn} do
    {:ok, a} = Annotations.create(%{kind: "halving", title: "First halving", height: 210_000})
    {:ok, view, _html} = live(conn, "/annotations")

    view |> element("#annotation-#{a.id} button", "Edit") |> render_click()

    view
    |> form("#annotation-form", annotation: %{title: "First halving: 50 to 25"})
    |> render_submit()

    assert Annotations.get(a.id).title == "First halving: 50 to 25"

    view |> element("#annotation-#{a.id} button", "Delete") |> render_click()
    assert Annotations.get(a.id) == nil
    refute has_element?(view, "#annotation-#{a.id}")
  end

  test "adds the curated events once", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/annotations")
    view |> element("button", "Add curated events") |> render_click()
    count = length(Annotations.list())
    assert count > 10
    assert render(view) =~ "Genesis block"
    view |> element("button", "Add curated events") |> render_click()
    assert length(Annotations.list()) == count
  end
end
