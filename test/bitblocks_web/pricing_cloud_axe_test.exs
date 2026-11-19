defmodule BitblocksWeb.PricingCloudAxeTest do
  # /pricing#cloud with a filter described and estimated
  # (https://github.com/afomi/bitblocks/issues/113), and the consulting line
  # (https://github.com/afomi/bitblocks/issues/114), checked by axe in light
  # and dark mode.
  use BitblocksWeb.AccessibilityFeatureCase, async: false
  import Bitblocks.ChainFixtures

  @moduletag :accessibility_axe

  @dark_mode_script """
  const style = document.createElement('style');
  style.textContent = '*, *::before, *::after { transition: none !important; }';
  document.head.appendChild(style);
  document.documentElement.classList.remove('light');
  document.documentElement.classList.add('dark');
  """

  setup do
    for h <- 0..2, do: block_fixture(%{height: h, sync_state: "completed"})
    for h <- [1, 2], do: transaction_fixture(%{block_height: h, protocols: ["MAP"]})
    :ok
  end

  defp with_estimate(session) do
    session
    |> visit("/pricing#cloud")
    |> assert_has(css("#cloud-form"))
    |> click(css("#cloud-choose-database"))
    |> fill_in(css("#cloud-filter-protocols"), with: "MAP")
    |> assert_has(css("#cloud-filter-json", text: ~s({"protocols":["MAP"]})))
    |> click(css("#cloud-estimate-button"))
    |> assert_has(css("#cloud-estimate-covers"))
    |> assert_has(css("#consulting-contact"))
  end

  test "the cloud quote and consulting are accessible in light mode", %{session: session} do
    session
    |> with_estimate()
    |> assert_no_violations()
  end

  test "the cloud quote and consulting are accessible in dark mode", %{session: session} do
    session
    |> with_estimate()
    |> execute_script(@dark_mode_script)
    |> assert_has(css("html.dark"))
    |> assert_no_violations()
  end
end
