defmodule BitblocksWeb.ElectionArchiveAxeTest do
  @moduledoc """
  "Build the archive" on `/elections/:outpoint` (#136, step 5), in a real
  browser at phone width (390 px): disabled before the close is six blocks
  deep, ready after, and built with its file list, axe finds nothing in light
  or dark mode, and the page doesn't scroll sideways. The admin gate is off
  in the suite, so the section shows.
  """
  use BitblocksWeb.AccessibilityFeatureCase, async: false
  import Bitblocks.ElectionFixtures

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
    {:ok, session: session}
  end

  defp overflow(session) do
    test_pid = self()

    execute_script(
      session,
      "return [document.documentElement.scrollWidth, document.documentElement.clientWidth];",
      fn result -> send(test_pid, {:widths, result}) end
    )

    assert_receive {:widths, [scroll, client]}
    assert client == @width, "the session should be #{@width} px wide, got #{client}"
    scroll - client
  end

  defp built(session, s) do
    session
    |> visit("/elections/#{s.election}")
    |> assert_has(css(~s(#archive-status[data-status="ready"])))
    |> click(Wallaby.Query.button("Build the archive"))
    |> assert_has(css("#archive-built"))
  end

  describe "before the close is six blocks deep" do
    setup do
      %{s: scenario(through: 18)}
    end

    test "the disabled button and its reason are accessible in light and dark mode", %{
      session: session,
      s: s
    } do
      session
      |> visit("/elections/#{s.election}")
      |> assert_has(css(~s(#archive-status[data-status="refused"]), text: "3 blocks to go"))
      |> assert_has(css("#archive-build fieldset[disabled]"))
      |> assert_no_violations()
      |> execute_script(@dark_mode_script)
      |> assert_has(css("html.dark"))
      |> assert_no_violations()
    end
  end

  describe "once the close is six blocks deep" do
    setup do
      %{s: scenario()}
    end

    test "the ready button is accessible", %{session: session, s: s} do
      session
      |> visit("/elections/#{s.election}")
      |> assert_has(css(~s(#archive-status[data-status="ready"])))
      |> assert_no_violations()
    end

    test "the built archive is accessible in light mode", %{session: session, s: s} do
      session
      |> built(s)
      |> assert_has(css("#archive-download"))
      |> assert_no_violations()
    end

    test "the built archive is accessible in dark mode", %{session: session, s: s} do
      session
      |> built(s)
      |> execute_script(@dark_mode_script)
      |> assert_has(css("html.dark"))
      |> assert_no_violations()
    end

    test "the built archive fits a phone", %{session: session, s: s} do
      session = built(session, s)
      assert overflow(session) <= 0, "/elections/:outpoint scrolls sideways at #{@width} px"
    end
  end
end
