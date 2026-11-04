defmodule BitblocksWeb.ChainScrubberLiveTest do
  @moduledoc """
  The /chain-scrubber page (#48): admin-gated and out of the sitemap, tells
  you when tiles aren't built, jumps to a typed height, answers a rest with
  the capped tx read, and pushes the annotation layer.
  """
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.ChainFixtures
  import Bitblocks.ChainTileFixtures

  alias Bitblocks.ChainTiles
  alias Bitblocks.ChainTiles.Cache
  alias Bitblocks.Reorgs

  setup do
    Cache.clear()
    on_exit(fn -> Cache.clear() end)
    :ok
  end

  describe "access" do
    setup do
      previous = Application.get_env(:bitblocks, :admin_auth)
      Application.put_env(:bitblocks, :admin_auth, enabled: true)
      on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, previous) end)
      :ok
    end

    test "an anonymous visitor gets the admin auth challenge", %{conn: conn} do
      conn = get(conn, "/chain-scrubber")
      assert conn.status == 401
      assert conn.halted
      assert [_challenge | _] = get_resp_header(conn, "www-authenticate")
    end

    test "the page is not in the sitemap", %{conn: conn} do
      body = conn |> get("/sitemap.xml") |> response(200)
      refute body =~ "/chain-scrubber"
      refute "/chain-scrubber" in BitblocksWeb.SitemapController.public_paths()
    end
  end

  test "renders with a not-built notice before the first full build", %{conn: conn} do
    insert_blocks(0..5)
    {:ok, _view, html} = live(conn, "/chain-scrubber")

    assert html =~ "Chain scrubber"
    assert html =~ "Tiles are not built yet"
    assert html =~ ~s(phx-hook="ChainScrubber")
    assert html =~ ~s(data-tip-height="5")
    assert html =~ "log10"
  end

  test "renders the manifest's tip and build once tiles exist", %{conn: conn} do
    insert_blocks(0..1_100)
    {:ok, _} = ChainTiles.build(mode: :full)

    {:ok, _view, html} = live(conn, "/chain-scrubber")
    refute html =~ "Tiles are not built yet"
    assert html =~ ~s(data-tip-height="1100")
    assert html =~ "Tiles built"
    assert html =~ "Last build: full"
  end

  test "from and to frame the opening view on a stretch of the chain", %{conn: conn} do
    insert_blocks(0..500)

    {:ok, _view, html} = live(conn, "/chain-scrubber?from=100&to=200")
    assert html =~ ~s(data-view-from="100")
    assert html =~ ~s(data-view-to="200")

    # Out of range or reversed bounds fall back to the whole chain.
    {:ok, _view, html} = live(conn, "/chain-scrubber?from=300&to=900")
    assert html =~ ~s(data-view-from="0")
    assert html =~ ~s(data-view-to="500")

    {:ok, _view, html} = live(conn, "/chain-scrubber?from=200&to=100")
    assert html =~ ~s(data-view-from="0")
    assert html =~ ~s(data-view-to="500")
  end

  test "typing a height jumps to that block", %{conn: conn} do
    insert_blocks(0..1_100)
    {:ok, _} = ChainTiles.build(mode: :full)
    {:ok, view, _html} = live(conn, "/chain-scrubber")

    html = view |> element("form[phx-submit=jump]") |> render_submit(%{"height" => "1,024"})
    assert_push_event(view, "jump", %{height: 1024})
    assert html =~ ~s(value="1024")

    html = view |> element("form[phx-submit=jump]") |> render_submit(%{"height" => "99999"})
    assert html =~ "Enter a height between 0 and 1100"
    refute_push_event(view, "jump", %{height: 99_999})

    html = view |> element("form[phx-submit=jump]") |> render_submit(%{"height" => "abc"})
    assert html =~ "Enter a height between 0 and 1100"
  end

  test "parse_height accepts separators and rejects anything outside 0..tip" do
    alias BitblocksWeb.ChainScrubberLive

    assert ChainScrubberLive.parse_height("812,345", 900_000) == 812_345
    assert ChainScrubberLive.parse_height(" 812_345 ", 900_000) == 812_345
    assert ChainScrubberLive.parse_height(0, 10) == 0
    assert ChainScrubberLive.parse_height("-1", 10) == nil
    assert ChainScrubberLive.parse_height("11", 10) == nil
    assert ChainScrubberLive.parse_height("1.5", 10) == nil
    assert ChainScrubberLive.parse_height(nil, 10) == nil
  end

  test "resting on a block pushes its capped tx read", %{conn: conn} do
    insert_blocks(0..1_100)
    block = block_fixture(%{height: 1_101, num_tx: 2, sync_state: "completed"})
    transaction_fixture(%{block_hash: block.hash, block_height: 1_101, coinbase: true})
    transaction_fixture(%{block_hash: block.hash, block_height: 1_101})
    {:ok, _} = ChainTiles.build(mode: :full)
    {:ok, view, _html} = live(conn, "/chain-scrubber")

    html = render_hook(view, "rest", %{"height" => 1_101})
    assert_push_event(view, "rest_data", %{kind: "marks", height: 1_101, sample: 2})
    assert html =~ "Rest: block 1101 marks"

    render_hook(view, "rest", %{"height" => 7})
    assert_push_event(view, "rest_data", %{kind: "marks", height: 7, sample: 0})

    html = render_hook(view, "rest", %{"height" => 5_000})
    refute html =~ "Rest: block 5000"
  end

  test "a recorded reorg and a classified loss are pushed as annotations on mount", %{conn: conn} do
    insert_blocks(0..10)

    {:ok, _} =
      Reorgs.record_observed(%{
        fork_height: 7,
        fork_point: 6,
        orphan_count: 1,
        outcome: "resolved",
        summary: "block 7 orphaned"
      })

    {:ok, view, html} = live(conn, "/chain-scrubber")

    assert_push_event(view, "annotations", %{items: items})

    assert Enum.any?(
             items,
             &(&1.kind == "reorg" and &1.height == 7 and &1.evidence_url == "/reorgs")
           )

    assert Enum.any?(items, &(&1.kind == "loss" and &1.height == 875_850))
    assert html =~ "1 reorgs, 30 classified losses"
  end

  test "the scene names what its diamonds are, and has a place to say it on hover", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/chain-scrubber")

    for kind <- ~w(reorg loss fork upgrade halving milestone mint world note),
        do: assert(has_element?(view, "#chain-scrubber-legend li", kind))

    assert has_element?(view, ~s(#chain-scrubber-marker-tip[aria-hidden="true"]))
  end
end
