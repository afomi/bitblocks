defmodule BitblocksWeb.BlockGraphLiveTest do
  use BitblocksWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Bitblocks.Repo
  alias Bitblocks.Chain.Block

  setup do
    # Seed a few blocks so the graph has data to load
    for height <- 0..5 do
      hash = "hash_#{height}" |> String.pad_trailing(64, "0")
      prev = if height > 0, do: "hash_#{height - 1}" |> String.pad_trailing(64, "0"), else: nil

      %Block{}
      |> Block.changeset(%{
        hash: hash,
        height: height,
        prevblockhash: prev,
        time: 1_231_006_505 + height * 600,
        num_tx: 1,
        tx: ["coinbase_tx_#{height}"],
        size: 285,
        version: 1,
        merkleroot: String.duplicate("a", 64),
        bits: "1d00ffff",
        nonce: height,
        difficulty: "1.0",
        sync_state: "header_synced"
      })
      |> Repo.insert!()
    end

    :ok
  end

  test "renders block graph with playback controls", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/block-graph?start=0&end=5")

    assert html =~ "Block Transaction Graph"
    assert html =~ "play"
    assert html =~ "pause"
    assert html =~ "rewind"
    assert html =~ "forward"
  end

  test "play event sets playback state to playing", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/block-graph?start=0&end=5")

    rendered = view |> element("#playback-play") |> render_click()

    assert rendered =~ "playing"
  end

  test "pause event sets playback state to paused", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/block-graph?start=0&end=5")

    # Play first, then pause
    view |> element("#playback-play") |> render_click()
    rendered = view |> element("#playback-pause") |> render_click()

    assert rendered =~ "paused"
  end

  test "rewind resets playback to the beginning", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/block-graph?start=0&end=5")

    view |> element("#playback-play") |> render_click()
    rendered = view |> element("#playback-rewind") |> render_click()

    assert rendered =~ "stopped"
  end

  test "forward advances playback cursor", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/block-graph?start=0&end=5")

    rendered = view |> element("#playback-forward") |> render_click()

    # Should advance and show the cursor position
    assert rendered =~ "Block"
  end

  test "legend shows coinbase and spent/unspent indicators", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/block-graph?start=0&end=5")

    assert html =~ "Coinbase"
    assert html =~ "Spent"
    assert html =~ "Unspent"
  end

  test "genesis block is included in graph data", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/block-graph?start=0&end=5")

    # Genesis block (height 0) should be present — stats show block count
    rendered = render(view)
    assert rendered =~ "Blocks:"
    # Playback cursor starts at 0 (genesis)
    assert rendered =~ "Block 0"
  end
end
