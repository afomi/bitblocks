defmodule BitblocksWeb.FilesAxeTest do
  @moduledoc """
  `/files` and its search (https://github.com/afomi/bitblocks/issues/175) at
  phone width (390 px), in a real browser: axe finds nothing in light or
  dark mode, and the page doesn't scroll sideways, with results, with none,
  and with an address the index doesn't hold.
  """
  use BitblocksWeb.AccessibilityFeatureCase, async: false

  alias Bitblocks.CFiles

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

  # Toggle to dark with transitions off, so axe reads each colour after the flip.
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

  setup do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for {name, type, kind, chunks} <- [
            {"a_rather_long_file_name_for_a_narrow_screen_cat_picture.png", "image/png", "b",
             nil},
            {"cat-video.mp4", "video/mp4", "bcat", 4}
          ] do
        %{
          sha256: :crypto.hash(:sha256, name),
          txid: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
          vout: 0,
          block_height: 640_000,
          kind: kind,
          chunks: chunks,
          media_type: type,
          encoding: nil,
          filename: name,
          size: 123_456,
          version: CFiles.version(),
          inserted_at: now,
          updated_at: now
        }
      end

    CFiles.write(rows)
    :ok
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

  for {name, path, ready} <- [
        {"the search box", "/files", "#files-search"},
        {"results", "/files?q=cat", "#files-results"},
        {"no match", "/files?q=zebra", "#files-no-match"},
        {"an address not indexed", "/files?q=#{String.duplicate("ab", 32)}",
         "#files-address-miss"}
      ] do
    test "#{name} fits a phone and is accessible in light mode", %{session: session} do
      session =
        session
        |> visit(unquote(path))
        |> assert_has(css(unquote(ready)))
        |> assert_has(css("#files-q"))
        |> assert_no_violations()

      assert overflow(session) <= 0, "#{unquote(path)} scrolls sideways at #{@width} px"
    end

    test "#{name} is accessible in dark mode", %{session: session} do
      session
      |> visit(unquote(path))
      |> execute_script(@dark_mode_script)
      |> assert_has(css("html.dark"))
      |> assert_has(css(unquote(ready)))
      |> assert_no_violations()
    end
  end
end
