defmodule BitblocksWeb.FreshnessAxeTest do
  @moduledoc """
  The freshness line (`BitblocksWeb.Freshness`, DESIGN.md) in a real browser
  at phone width (390 px): on the homepage, a block page and `/files`, in
  light and dark mode, with no axe violations and no sideways scroll, while
  the index is far behind the tip (the longest line it draws).
  """
  use BitblocksWeb.AccessibilityFeatureCase, async: false
  import Bitblocks.ChainFixtures

  alias Bitblocks.SyncProgress

  @moduletag :accessibility_axe

  @width 390

  @phone %{
    chromeOptions: %{
      args: [
        "--headless=new",
        "--no-sandbox",
        "--disable-dev-shm-usage",
        "--disable-gpu",
        "--disable-software-rasterizer"
      ],
      mobileEmulation: %{deviceMetrics: %{width: 390, height: 844, pixelRatio: 2}}
    }
  }

  @dark_mode_script """
  const style = document.createElement('style');
  style.textContent = '*, *::before, *::after { transition: none !important; }';
  document.head.appendChild(style);
  document.documentElement.classList.remove('light');
  document.documentElement.classList.add('dark');
  """

  setup %{session: desktop} do
    Wallaby.end_session(desktop)
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Bitblocks.Repo, self())
    {:ok, session} = Wallaby.start_session(metadata: metadata, capabilities: @phone)
    on_exit(fn -> Wallaby.end_session(session) end)

    block_fixture(%{height: 170, hash: "h170", sync_state: "completed"})
    snapshot = SyncProgress.empty_snapshot()

    overview =
      Map.merge(snapshot.overview, %{complete_through: 422_382, our_tip: 976_935})

    :ets.insert(SyncProgress, {:snapshot, %{snapshot | overview: overview}})
    on_exit(fn -> :ets.insert(SyncProgress, {:snapshot, SyncProgress.empty_snapshot()}) end)

    {:ok, session: session}
  end

  # How far the line pokes past the viewport, and past its own box.
  defp overflow(session, selector) do
    test_pid = self()

    execute_script(
      session,
      """
      const e = document.querySelector(arguments[0]);
      const r = e.getBoundingClientRect();
      return [Math.ceil(r.right), document.documentElement.clientWidth, e.scrollWidth - e.clientWidth];
      """,
      [selector],
      fn result -> send(test_pid, {:widths, result}) end
    )

    assert_receive {:widths, [right, client, own]}
    assert client == @width, "the session should be #{@width} px wide, got #{client}"
    max(right - client, own)
  end

  for {path, selector} <- [
        {"/", "#home-coverage"},
        {"/blocks/170", "#block-freshness"},
        {"/files", "#files-freshness"}
      ] do
    @path path
    @selector selector

    test "#{path}: the line is accessible in light mode and fits a phone", %{session: session} do
      session =
        session
        |> visit(@path)
        |> assert_has(css(@selector, text: "554,553 blocks behind the chain"))
        |> assert_no_violations()

      assert overflow(session, @selector) <= 0,
             "the line on #{@path} runs past #{@width} px"
    end

    test "#{path}: the line is accessible in dark mode", %{session: session} do
      session
      |> visit(@path)
      |> assert_has(css(@selector))
      |> execute_script(@dark_mode_script)
      |> assert_has(css("html.dark"))
      |> assert_no_violations()
    end
  end
end
