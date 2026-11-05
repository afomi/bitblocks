defmodule BitblocksWeb.AccessibilityAxeTest do
  use BitblocksWeb.AccessibilityFeatureCase, async: false
  import Bitblocks.ChainFixtures

  @moduletag :accessibility_axe

  describe "accessibility scanning with axe-core" do
    test "home page is accessible", %{session: session} do
      session
      |> visit("/")
      |> assert_no_violations()
    end

    test "status page is accessible", %{session: session} do
      session
      |> visit("/status")
      |> assert_no_violations()
    end

    test "blocks index page is accessible", %{session: session} do
      session
      |> visit("/blocks")
      |> assert_no_violations()
    end

    test "block show page is accessible", %{session: session} do
      block = block_fixture()

      session
      |> visit("/blocks/#{block.height}")
      |> assert_no_violations()
    end

    test "transactions index page is accessible", %{session: session} do
      session
      |> visit("/transactions")
      |> assert_no_violations()
    end

    test "transaction show page is accessible", %{session: session} do
      block = block_fixture()
      transaction = transaction_fixture(%{block_height: block.height})

      session
      |> visit("/transactions/#{transaction.txid}")
      |> assert_no_violations()
    end

    test "sync page is accessible", %{session: session} do
      session
      |> visit("/syncing")
      |> assert_no_violations()
    end

    test "protocols page is accessible", %{session: session} do
      session
      |> visit("/protocols")
      |> assert_no_violations()
    end

    test "graph page is accessible", %{session: session} do
      session
      |> visit("/graph")
      |> assert_no_violations()
    end

    test "highlights page is accessible", %{session: session} do
      session
      |> visit("/highlights")
      |> assert_no_violations()
    end

    test "search page is accessible", %{session: session} do
      session
      |> visit("/search")
      |> assert_no_violations()
    end

    test "config page is accessible", %{session: session} do
      session
      |> visit("/config")
      |> assert_no_violations()
    end

    test "metanet page is accessible in light mode", %{session: session} do
      session
      |> visit("/metanet")
      |> assert_has(css("#metanet-roots"))
      |> assert_no_violations()
    end

    test "metanet page is accessible in dark mode", %{session: session} do
      session
      |> visit("/metanet")
      |> execute_script(
        "document.documentElement.classList.remove('light'); document.documentElement.classList.add('dark');"
      )
      |> assert_has(css("html.dark"))
      |> assert_has(css("#metanet-roots"))
      |> assert_no_violations()
    end

    # Toggle to dark and switch off transitions first, so axe reads each
    # colour after the flip rather than part way through a transition-colors fade.
    @dark_mode_script """
    const style = document.createElement('style');
    style.textContent = '*, *::before, *::after { transition: none !important; }';
    document.head.appendChild(style);
    document.documentElement.classList.remove('light');
    document.documentElement.classList.add('dark');
    """

    # Pages restyled to the site style (DESIGN.md). Each runs in light mode
    # and again with the theme toggled to dark. The three.js pages keep their
    # canvas dark in both modes; only the chrome around it changes, and that
    # chrome is what axe checks here.
    #
    # The test Chrome runs with --disable-gpu --disable-software-rasterizer,
    # so three.js cannot create a WebGL context and throws on mount. For those
    # pages only, Wallaby's js_errors is off for the test, so the chrome can be
    # scanned without the scene. Wait for chrome, never the canvas container:
    # it is an empty flex-1 div that only gets a height once WebGL draws, so on
    # CI (no WebGL) it is never "visible".
    for {path, ready, webgl?} <- [
          {"/", "#home-search-form", false},
          {"/about", "#how-it-is-built", false},
          {"/tx-graph", "#tx-flow-range", true},
          {"/shape-layers", "svg[viewBox='0 0 400 300']", false},
          {"/chain-scrubber", "#chain-scrubber-controls", true},
          {"/annotations", "#annotation-form", false},
          {"/peers", "h1", true},
          {"/ecosystem", "h1", true},
          {"/wall", "#wall-info", true},
          {"/reward_wall", "#reward-wall-controls", true}
        ] do
      test "#{path} is accessible in light mode", %{session: session} do
        if unquote(webgl?), do: ignore_js_errors()

        session
        |> visit(unquote(path))
        |> assert_has(css(unquote(ready)))
        |> assert_no_violations()
      end

      test "#{path} is accessible in dark mode", %{session: session} do
        if unquote(webgl?), do: ignore_js_errors()

        session
        |> visit(unquote(path))
        |> execute_script(@dark_mode_script)
        |> assert_has(css("html.dark"))
        |> assert_has(css(unquote(ready)))
        |> assert_no_violations()
      end
    end

    # The sync's block table (stages as text and icon), with a completed, a
    # failing and a waiting block.
    for dark? <- [false, true],
        {path, table} <- [{"/syncing", "sync-table"}] do
      test "#{path} block table is accessible in #{if dark?, do: "dark", else: "light"} mode", %{
        session: session
      } do
        seed_sync_table()

        session = visit(session, unquote(path))
        session = if unquote(dark?), do: execute_script(session, @dark_mode_script), else: session

        session
        |> assert_has(css("##{unquote(table)}-row-2"))
        |> assert_no_violations()
      end
    end

    test "reorgs page is accessible with no reorgs recorded", %{session: session} do
      session
      |> visit("/reorgs")
      |> assert_no_violations()
    end

    test "reorgs page is accessible with recorded reorgs, in light mode", %{session: session} do
      record_reorgs()

      session
      |> visit("/reorgs")
      |> assert_has(css("#reorg-notice"))
      |> assert_no_violations()
    end

    test "reorgs page is accessible with recorded reorgs, in dark mode", %{session: session} do
      record_reorgs()

      session
      |> visit("/reorgs")
      |> execute_script(
        "document.documentElement.classList.remove('light'); document.documentElement.classList.add('dark');"
      )
      |> assert_has(css("html.dark"))
      |> assert_has(css("#reorg-notice"))
      |> assert_no_violations()
    end
  end

  # This module is async: false, so the env change is restored before the next test.
  defp ignore_js_errors do
    previous = Application.get_env(:wallaby, :js_errors, true)
    Application.put_env(:wallaby, :js_errors, false)
    on_exit(fn -> Application.put_env(:wallaby, :js_errors, previous) end)
  end

  defp seed_sync_table do
    for h <- 0..1, do: block_fixture(%{height: h, num_tx: 1, sync_state: "completed"})
    block_fixture(%{height: 2, hash: "axe_failing", num_tx: 3, sync_state: "failed"})
    block_fixture(%{height: 3, num_tx: 2, sync_state: "header_only"})

    {:ok, _} =
      Oban.insert(
        Bitblocks.Workers.FetchTransactionsWorker.new(%{block_hash: "axe_failing"},
          meta: %{slot: 1}
        )
      )

    Bitblocks.SyncProgress.refresh()
  end

  # One fresh reorg per outcome, so the banner and both timeline labels render.
  defp record_reorgs do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      Bitblocks.Reorgs.record_observed(
        %{fork_height: 800_000, fork_point: 799_998, orphan_count: 2, outcome: "resolved"},
        now
      )

    {:ok, _} =
      Bitblocks.Reorgs.record_observed(
        %{fork_height: 800_010, fork_point: nil, orphan_count: nil, outcome: "needs_attention"},
        now
      )
  end
end
