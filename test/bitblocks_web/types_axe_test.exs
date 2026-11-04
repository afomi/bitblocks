defmodule BitblocksWeb.TypesAxeTest do
  use BitblocksWeb.AccessibilityFeatureCase, async: false
  import Bitblocks.ChainFixtures

  @moduletag :accessibility_axe

  # Toggle to dark with transitions off, so axe reads each colour after the flip.
  @dark_mode_script """
  const style = document.createElement('style');
  style.textContent = '*, *::before, *::after { transition: none !important; }';
  document.head.appendChild(style);
  document.documentElement.classList.remove('light');
  document.documentElement.classList.add('dark');
  """

  setup do
    # So the Metanet page renders its example list, not the empty state.
    transaction_fixture(%{txid: String.duplicate("ab", 32), protocols: ["Metanet"]})
    :ok
  end

  for {path, ready} <- [
        {"/types", "#group-cash"},
        {"/types/metanet", "#type-examples-list"},
        {"/types/op-return", "#type-examples-coming"}
      ] do
    test "#{path} is accessible in light mode", %{session: session} do
      session
      |> visit(unquote(path))
      |> assert_has(css(unquote(ready)))
      |> assert_no_violations()
    end

    test "#{path} is accessible in dark mode", %{session: session} do
      session
      |> visit(unquote(path))
      |> execute_script(@dark_mode_script)
      |> assert_has(css("html.dark"))
      |> assert_has(css(unquote(ready)))
      |> assert_no_violations()
    end
  end
end
