defmodule BitblocksWeb.PricingCheckoutLiveTest do
  # "Pay" on /pricing#downloads (https://github.com/afomi/bitblocks/issues/111):
  # dormant until Checkout is configured (the quote keeps "Contact us"), test
  # mode for admins only, refused for a range we can't serve, and a click
  # that sends the browser to Stripe for the price stored on the server.
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.DownloadsFixtures
  import Ecto.Query, only: [from: 2]

  alias Bitblocks.Downloads.Purchase
  alias Bitblocks.Repo

  setup do
    with_price()
    stored_chain(["zero", "one", "two"])
    {:ok, user: user!()}
  end

  defp signed_in(conn, user), do: init_test_session(conn, %{"user_id" => user.id})

  defp quote!(view, from, to) do
    view
    |> form("#downloads-form",
      quote: %{"from" => from, "to" => to, "data" => "raw", "format" => "bin"}
    )
    |> render_submit()
  end

  test "dormant with no Stripe keys: no Pay, and Contact us stays", %{conn: conn, user: user} do
    without_checkout()
    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/pricing")
    quote!(view, "0", "2")

    assert has_element?(view, "#downloads-quote-price", "$10.00")
    refute has_element?(view, "#downloads-pay")
    refute has_element?(view, "#downloads-checkout")
    assert has_element?(view, "#downloads-contact", "Contact us")
    assert render(view) =~ "Paying online is coming."
  end

  test "configured: Pay opens Stripe Checkout for the stored price", %{conn: conn, user: user} do
    with_checkout_configured()
    stub_checkout(self())
    Req.Test.set_req_test_to_shared()

    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/pricing")
    quote!(view, "0", "2")

    assert has_element?(view, "#downloads-pay", "Pay $10.00")
    assert has_element?(view, "#downloads-contact", "Contact us")

    assert {:error, {:redirect, %{to: "https://checkout.stripe.com/c/pay/cs_test_downloads"}}} =
             view |> element("#downloads-pay") |> render_click()

    [purchase] = Repo.all(Purchase)
    assert purchase.user_id == user.id
    assert purchase.status == "checkout_open"
    assert purchase.price_cents == 1_000

    assert_received {:stripe_request, _, [key], form}
    assert key == purchase.id
    assert form["line_items[0][price_data][unit_amount]"] == "1000"
  end

  test "a range with blocks not in the file store says so instead of Pay", %{
    conn: conn,
    user: user
  } do
    with_checkout_configured()

    Repo.update_all(from(b in Bitblocks.Chain.Block, where: b.height in [1, 2]),
      set: [raw_object_stored_at: nil]
    )

    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/pricing")
    quote!(view, "0", "2")

    refute has_element?(view, "#downloads-pay")
    assert has_element?(view, "#downloads-not-purchasable", "2 blocks in this range")
    assert has_element?(view, "#downloads-contact", "Contact us")
  end

  test "signed out: Sign in to pay, coming back to the same range", %{conn: conn} do
    with_checkout_configured()
    {:ok, view, _html} = live(conn, ~p"/pricing")
    quote!(view, "0", "1")

    refute has_element?(view, "#downloads-pay")
    assert has_element?(view, "#downloads-sign-in-to-pay[href*='return_to']", "Sign in to pay")
  end

  test "test mode shows Pay to admins only", %{conn: conn, user: user} do
    with_checkout_configured()
    previous = Application.get_env(:bitblocks, :admin_auth)
    Application.put_env(:bitblocks, :admin_auth, enabled: true)
    on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, previous) end)

    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/pricing")
    quote!(view, "0", "2")
    refute has_element?(view, "#downloads-pay")
    assert has_element?(view, "#downloads-contact", "Contact us")

    admin =
      Repo.insert!(%Bitblocks.Accounts.User{github_id: 987_654_321, login: "admin1", admin: true})

    {:ok, view, _html} = build_conn() |> signed_in(admin) |> live(~p"/pricing")
    quote!(view, "0", "2")
    assert has_element?(view, "#downloads-pay")
  end

  test "a cancelled checkout comes back to its range", %{conn: conn, user: user} do
    with_checkout_configured()

    {:ok, view, _html} =
      conn |> signed_in(user) |> live(~p"/pricing?from=1&to=2&data=raw&format=bin")

    assert has_element?(view, "#downloads-from[value='1']")
    assert has_element?(view, "#downloads-to[value='2']")
  end
end
