defmodule BitblocksWeb.PhoneWidthTest do
  @moduledoc """
  The public pages at phone width (390 px), in a real browser: none scrolls
  sideways, so nothing a reader needs sits off the edge of the screen, and
  the menu opens. Chrome won't size a desktop window below 500 px, so the
  session emulates a phone's screen instead.
  """
  use BitblocksWeb.AccessibilityFeatureCase, async: false
  import Bitblocks.ChainFixtures

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

  setup %{session: desktop} do
    Wallaby.end_session(desktop)
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Bitblocks.Repo, self())
    {:ok, session} = Wallaby.start_session(metadata: metadata, capabilities: @phone)
    on_exit(fn -> Wallaby.end_session(session) end)
    {:ok, session: session}
  end

  setup do
    for h <- 0..7 do
      block_fixture(%{
        height: h,
        hash: String.pad_leading(Integer.to_string(h), 64, "0"),
        time: 1_700_000_000 + h * 600,
        num_tx: 2_508,
        sync_state: "completed"
      })
    end

    tx =
      transaction_fixture(%{
        block_hash: String.pad_leading("7", 64, "0"),
        block_height: 7
      })

    %{txid: tx.txid}
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

  for {name, path} <- [
        {"home", "/"},
        {"blocks", "/blocks"},
        {"a block", "/blocks/7"},
        {"types", "/types"},
        {"facts", "/facts"},
        {"about", "/about"},
        {"start", "/start"},
        {"reorgs", "/reorgs"}
      ] do
    test "#{name} fits a phone", %{session: session} do
      session =
        session
        |> visit(unquote(path))
        |> assert_has(css("main"))

      assert overflow(session) <= 0, "#{unquote(path)} scrolls sideways at #{@width} px"
    end
  end

  test "a transaction fits a phone", %{session: session, txid: txid} do
    session =
      session
      |> visit("/transactions/#{txid}")
      |> assert_has(css("main"))

    assert overflow(session) <= 0, "/transactions/:txid scrolls sideways at #{@width} px"
  end

  test "the menu button opens the menu on a phone", %{session: session} do
    session
    |> visit("/")
    |> click(Wallaby.Query.button("Open main menu"))
    |> assert_has(css("#nav-mobile #nav-blocks-mobile", visible: true))
  end
end
