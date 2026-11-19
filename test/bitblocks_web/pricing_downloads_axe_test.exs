defmodule BitblocksWeb.PricingDownloadsAxeTest do
  # /pricing#downloads with an estimate, its arithmetic and the size bands on
  # screen (https://github.com/afomi/bitblocks/issues/111), checked by axe in
  # light and dark mode.
  use BitblocksWeb.AccessibilityFeatureCase, async: false
  import Bitblocks.ChainFixtures

  @moduletag :accessibility_axe

  @gib 1_073_741_824

  @dark_mode_script """
  const style = document.createElement('style');
  style.textContent = '*, *::before, *::after { transition: none !important; }';
  document.head.appendChild(style);
  document.documentElement.classList.remove('light');
  document.documentElement.classList.add('dark');
  """

  setup do
    for {size, h} <- Enum.with_index([div(@gib, 4), @gib, nil]) do
      block_fixture(%{height: h, size: size, sync_state: "completed"})
    end

    previous = Application.get_env(:bitblocks, Bitblocks.Downloads)
    Application.put_env(:bitblocks, Bitblocks.Downloads, price_usd_per_gib: "1.00")
    Bitblocks.Downloads.clear_size_bands()

    on_exit(fn ->
      Bitblocks.Downloads.clear_size_bands()

      if previous,
        do: Application.put_env(:bitblocks, Bitblocks.Downloads, previous),
        else: Application.delete_env(:bitblocks, Bitblocks.Downloads)
    end)
  end

  defp with_estimate(session) do
    session
    |> visit("/pricing#downloads")
    |> assert_has(css("#downloads-sizes-table"))
    |> click(css("#downloads-band-0 button"))
    |> assert_has(css("#downloads-quote-price-why"))
    |> fill_in(css("#downloads-to"), with: "1")
    |> assert_has(css("#downloads-quote-arithmetic", text: "1.25 GiB x $1.00 per GiB = $1.25"))
  end

  test "the estimate is accessible in light mode", %{session: session} do
    session
    |> with_estimate()
    |> assert_no_violations()
  end

  test "the estimate is accessible in dark mode", %{session: session} do
    session
    |> with_estimate()
    |> execute_script(@dark_mode_script)
    |> assert_has(css("html.dark"))
    |> assert_no_violations()
  end
end
