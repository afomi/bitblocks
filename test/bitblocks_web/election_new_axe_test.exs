defmodule BitblocksWeb.ElectionNewAxeTest do
  @moduledoc """
  `/elections/new` (https://github.com/afomi/bitblocks/issues/136) in a real
  browser at phone width (390 px): the empty form, the form with its errors,
  and the records it builds, in light and dark mode, with no axe violations
  and no sideways scroll. The admin gate is off in the suite.
  """
  use BitblocksWeb.AccessibilityFeatureCase, async: false
  import Bitblocks.ChainFixtures
  import Bitblocks.ElectionFixtures, only: [key: 0]

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
    block_fixture(%{height: 975_000})
    {:ok, session: session, members: for(_ <- 1..3, do: key().address)}
  end

  defp filled(session, members, opts \\ []) do
    session
    |> visit("/elections/new")
    |> assert_has(css("#election-form"))
    |> fill_in(css("#election_name"), with: "PBA Board 2026")
    |> fill_in(css("#election_number_elected"), with: Keyword.get(opts, :seats, "3"))
    |> fill_in(css("#election_candidates"),
      with: "Ada Okafor\nBea Lindqvist\nChen Wei\nDara Byrne\nEli Moreau"
    )
    |> fill_in(css("#election_members"), with: Enum.join(members, "\n"))
    |> click(Wallaby.Query.button("About a week"))
    |> assert_has(css("#election-window"))
    |> click(Wallaby.Query.button("Show the records"))
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

  test "the empty form is accessible at phone width", %{session: session} do
    session
    |> visit("/elections/new")
    |> assert_has(css("#election-tip"))
    |> assert_no_violations()
  end

  test "the form's errors are accessible", %{session: session, members: members} do
    session
    |> filled(members, seats: "0")
    |> assert_has(css("#number_elected-error"))
    |> assert_no_violations()
  end

  test "the records are accessible in light mode", %{session: session, members: members} do
    session
    |> filled(members)
    |> assert_has(css("#record-roll-sign"))
    |> fill_in(css("#election-roll-outpoint"), with: String.duplicate("cd", 32))
    |> assert_has(css("#record-election-sign"))
    |> assert_no_violations()
  end

  test "the records are accessible in dark mode", %{session: session, members: members} do
    session
    |> filled(members)
    |> assert_has(css("#record-roll-sign"))
    |> execute_script(@dark_mode_script)
    |> assert_has(css("html.dark"))
    |> assert_no_violations()
  end

  test "the records fit a phone", %{session: session, members: members} do
    session =
      session
      |> filled(members)
      |> fill_in(css("#election-roll-outpoint"), with: String.duplicate("cd", 32))
      |> assert_has(css("#record-election-sign"))

    assert overflow(session) <= 0, "/elections/new scrolls sideways at #{@width} px"
  end
end
