defmodule BitblocksWeb.DownloadAxeTest do
  # /downloads/:id with the files, links, script and "Resume" on screen
  # (https://github.com/afomi/bitblocks/issues/111), checked by axe in light
  # and dark mode, signed in as the buyer.
  use BitblocksWeb.AccessibilityFeatureCase, async: false

  import Bitblocks.ChainFixtures
  import Bitblocks.DownloadsFixtures

  @moduletag :accessibility_axe

  @dark_mode_script """
  const style = document.createElement('style');
  style.textContent = '*, *::before, *::after { transition: none !important; }';
  document.head.appendChild(style);
  document.documentElement.classList.remove('light');
  document.documentElement.classList.add('dark');
  """

  setup do
    blocks =
      for h <- 0..2 do
        block_fixture(%{
          height: h,
          hash: String.pad_leading(Integer.to_string(h), 64, "0"),
          size: 1_000 + h,
          sync_state: "completed"
        })
      end

    user = user!()
    {:ok, user: user, purchase: ready_purchase!(user, blocks)}
  end

  defp open_download(session, user, purchase) do
    session
    |> visit("/about")
    |> Wallaby.Browser.set_cookie(session_cookie_key(), session_cookie(user))
    |> visit("/downloads/#{purchase.id}")
    |> assert_has(css("#download-files-table"))
    |> assert_has(css("#download-script"))
  end

  test "a ready download is accessible in light mode", %{session: s, user: u, purchase: p} do
    s
    |> open_download(u, p)
    |> assert_no_violations()
  end

  test "a ready download is accessible in dark mode", %{session: s, user: u, purchase: p} do
    s
    |> open_download(u, p)
    |> execute_script(@dark_mode_script)
    |> assert_has(css("html.dark"))
    |> assert_no_violations()
  end
end
