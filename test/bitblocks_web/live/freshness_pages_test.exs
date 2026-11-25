defmodule BitblocksWeb.FreshnessPagesTest do
  # The freshness line (BitblocksWeb.Freshness, DESIGN.md) on the pages a
  # reader lands on, read from the shared sync snapshot.
  # Writes the shared SyncProgress snapshot, so not async.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures

  alias Bitblocks.SyncProgress

  setup do
    :ets.insert(SyncProgress, {:snapshot, SyncProgress.empty_snapshot()})
    on_exit(fn -> :ets.insert(SyncProgress, {:snapshot, SyncProgress.empty_snapshot()}) end)
    :ok
  end

  defp put_overview(overview) do
    snapshot = SyncProgress.empty_snapshot()

    :ets.insert(
      SyncProgress,
      {:snapshot, %{snapshot | overview: Map.merge(snapshot.overview, overview)}}
    )
  end

  defp line(view, selector) do
    view
    |> element(selector)
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  describe "a block page" do
    test "far behind the tip, it names the block the index reaches and the gap", %{conn: conn} do
      block_fixture(%{height: 170, hash: "h170", sync_state: "completed"})
      put_overview(%{complete_through: 422_382, our_tip: 976_935})

      {:ok, view, _html} = live(conn, ~p"/blocks/170")

      assert line(view, "#block-freshness") ==
               "Current to block 422,382 · 554,553 blocks behind the chain"
    end

    test "with headers ahead of the index but not yet known, it doesn't guess", %{conn: conn} do
      block_fixture(%{height: 170, hash: "h170", sync_state: "completed"})
      put_overview(%{complete_through: 170, our_tip: nil})

      {:ok, view, _html} = live(conn, ~p"/blocks/170")

      assert line(view, "#block-freshness") == "Current to block 170 · chain tip not known"
    end

    test "before the snapshot knows a block, it says so", %{conn: conn} do
      block_fixture(%{height: 170, hash: "h170", sync_state: "header_only"})

      {:ok, view, _html} = live(conn, ~p"/blocks/170")

      assert line(view, "#block-freshness") == "Current to: not known yet"
    end
  end

  test "/files says how current the stored chain is, at the tip", %{conn: conn} do
    put_overview(%{complete_through: 975_001, our_tip: 975_001})

    {:ok, view, _html} = live(conn, ~p"/files")

    assert line(view, "#files-freshness") == "Current to block 975,001 · the chain tip"
  end

  test "the homepage links the block it is current to", %{conn: conn} do
    put_overview(%{complete_through: 600_000, our_tip: 975_001})

    html = conn |> get(~p"/") |> html_response(200)
    line = html |> Floki.parse_document!() |> Floki.find("#home-coverage") |> Floki.text()

    assert line |> String.replace(~r/\s+/, " ") =~
             "Current to block 600,000 · 375,001 blocks behind the chain"

    assert html =~ ~s(href="/blocks/600000")
  end
end
