defmodule BitblocksWeb.PaymentRequiredAxeTest do
  # The 402 page a browser gets past the shared anonymous budget
  # (BitblocksWeb.PaymentRequiredHTML), checked by axe in light and dark mode.
  use BitblocksWeb.AccessibilityFeatureCase, async: false

  @moduletag :accessibility_axe

  @dark_mode_script """
  const style = document.createElement('style');
  style.textContent = '*, *::before, *::after { transition: none !important; }';
  document.head.appendChild(style);
  document.documentElement.classList.remove('light');
  document.documentElement.classList.add('dark');
  """

  setup do
    :ets.delete_all_objects(:rate_limiter)
    previous = Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter)

    Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter,
      max_requests: 100_000,
      anonymous_site_max_requests: 1
    )

    on_exit(fn -> Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, previous) end)
  end

  defp refused(session) do
    session
    |> visit("/about")
    |> visit("/blocks")
    |> assert_has(css("#payment-required-ways"))
  end

  test "the 402 page is accessible in light mode", %{session: session} do
    session
    |> refused()
    |> assert_no_violations()
  end

  test "the 402 page is accessible in dark mode", %{session: session} do
    session
    |> refused()
    |> execute_script(@dark_mode_script)
    |> assert_has(css("html.dark"))
    |> assert_no_violations()
  end
end
