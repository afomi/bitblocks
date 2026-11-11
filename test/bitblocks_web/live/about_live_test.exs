defmodule BitblocksWeb.AboutLiveTest do
  # Writes the shared SyncProgress snapshot, so not async.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bitblocks.SyncProgress

  # Start from an empty snapshot, whatever an earlier test left in the table.
  setup do
    :ets.insert(SyncProgress, {:snapshot, SyncProgress.empty_snapshot()})
    :ok
  end

  defp put_coverage(overview) do
    snapshot = SyncProgress.empty_snapshot()

    :ets.insert(
      SyncProgress,
      {:snapshot, %{snapshot | overview: Map.merge(snapshot.overview, overview)}}
    )

    on_exit(fn -> :ets.insert(SyncProgress, {:snapshot, SyncProgress.empty_snapshot()}) end)
  end

  test "/about shows each layer with the live number it stands behind", %{conn: conn} do
    put_coverage(%{
      node_tip: 957_301,
      headers_stored: 957_302,
      complete_through: 912_345,
      our_tip: 957_301
    })

    {:ok, view, html} = live(conn, "/about")

    for id <- ~w(layer-node layer-records layer-sync layer-commands layer-web) do
      assert html =~ ~s(id="#{id}")
    end

    assert view |> element("#layer-node") |> render() =~ "957,301"
    assert view |> element("#layer-records") |> render() =~ "957,302"
    assert view |> element("#layer-sync") |> render() =~ "912,345"
  end

  test "/about follows the sync snapshot broadcast", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/about")
    refute view |> element("#layer-sync") |> render() =~ "Complete through block"

    overview = %{SyncProgress.empty_snapshot().overview | complete_through: 10}
    send(view.pid, {:sync_snapshot, %{SyncProgress.empty_snapshot() | overview: overview}})

    assert view |> element("#layer-sync") |> render() =~ "Complete through block"
  end

  test "/about names the endpoint and command behind each page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/about")

    assert html =~ "Behind the pages"
    assert html =~ "GET /api/v1/status/derivations"
    assert html =~ "Bitblocks.Release.sync_status()"
    assert html =~ "Hydrate a wallet"
  end

  test "the homepage states coverage from the snapshot, and hides it before the first one", %{
    conn: conn
  } do
    refute conn |> get(~p"/") |> html_response(200) =~ ~s(id="home-coverage")

    put_coverage(%{complete_through: 912_345, our_tip: 957_301})
    html = build_conn() |> get(~p"/") |> html_response(200)

    assert html =~ ~s(id="home-coverage")
    assert html =~ ~s(href="/blocks/912345")
    assert html =~ "957,301"
  end

  test "the homepage draws coverage as a bar that never claims more than is done", %{conn: conn} do
    refute conn |> get(~p"/") |> html_response(200) =~ ~s(id="home-coverage-bar")

    put_coverage(%{complete_through: 327_460, our_tip: 975_061})
    html = build_conn() |> get(~p"/") |> html_response(200)

    assert html =~ ~s(id="home-coverage-bar")
    assert html =~ "33%"
    assert html =~ ~s(style="width: 33%")
    assert html =~ "33% of the chain is indexed, from block 0 through block 327,460."
    assert BitblocksWeb.PageHTML.coverage_share(975_061, 975_061) == 100
    assert BitblocksWeb.PageHTML.coverage_share(0, 975_061) == 0
  end
end
