defmodule BitblocksWeb.ElectionBallotAxeTest do
  @moduledoc """
  "Did my ballot count?" on `/elections/:outpoint` (#137), in a real browser
  at phone width (390 px): with an address's answer shown, axe finds nothing
  in light or dark mode, and the page doesn't scroll sideways.
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
    {:ok, session: session, s: scenario()}
  end

  defp checked(session, s, query) do
    session
    |> visit("/elections/#{s.election}")
    |> assert_has(css("#ballot-lookup"))
    |> fill_in(css("#ballot-query"), with: query)
    |> click(Wallaby.Query.button("Check my ballot"))
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

  test "an address's ballots are accessible at phone width in light mode", %{
    session: session,
    s: s
  } do
    session
    |> checked(s, s.one.address)
    |> assert_has(css("#ballot-answer-ballots"))
    |> assert_has(css("#answer-#{s.txids.second}-proof"))
    |> assert_no_violations()
  end

  test "an address's ballots are accessible at phone width in dark mode", %{
    session: session,
    s: s
  } do
    session
    |> checked(s, s.one.address)
    |> assert_has(css("#ballot-answer-ballots"))
    |> execute_script(@dark_mode_script)
    |> assert_has(css("html.dark"))
    |> assert_no_violations()
  end

  test "a ballot not on the roll and a malformed input are accessible", %{
    session: session,
    s: s
  } do
    session
    |> checked(s, s.txids.outsider)
    |> assert_has(css("#answer-#{s.txids.outsider}-headline"))
    |> assert_no_violations()
    |> fill_in(css("#ballot-query"), with: "not a txid")
    |> click(Wallaby.Query.button("Check my ballot"))
    |> assert_has(css("#ballot-lookup-error"))
    |> assert_no_violations()
  end

  test "the answer fits a phone", %{session: session, s: s} do
    session =
      session
      |> checked(s, s.one.address)
      |> assert_has(css("#ballot-answer-ballots"))

    assert overflow(session) <= 0, "/elections/:outpoint scrolls sideways at #{@width} px"
  end
end
