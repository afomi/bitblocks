defmodule BitblocksWeb.PricingPlansLiveTest do
  # Monthly plans on /pricing (https://github.com/afomi/bitblocks/issues/112):
  # absent while dormant, so the page reads as before; "Choose" sends the
  # browser to Stripe for the server's Price; "Your plan" shows the plan, its
  # renewal, this period's use against the allowance, and "Manage billing".
  use BitblocksWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bitblocks.BillingFixtures

  import Bitblocks.DownloadsFixtures,
    only: [user!: 0, with_checkout_configured: 0, without_checkout: 0]

  alias Bitblocks.Billing.PlanSubscription
  alias Bitblocks.Payments.StripeEvents
  alias Bitblocks.Repo

  defp signed_in(conn, user), do: init_test_session(conn, %{"user_id" => user.id})

  test "dormant with no plans: no plans section and no Choose, the plans card still coming", %{
    conn: conn
  } do
    with_checkout_configured()
    user = user!()
    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/pricing")

    refute has_element?(view, "#plans")
    refute has_element?(view, "button", "Choose")
    refute has_element?(view, "#plan")
    assert has_element?(view, "#pricing-consumption", "Coming soon")
  end

  test "dormant with plans but no Stripe keys: nothing shown", %{conn: conn} do
    with_plans()
    without_checkout()
    {:ok, view, _html} = conn |> signed_in(user!()) |> live(~p"/pricing")

    refute has_element?(view, "#plans")
    refute has_element?(view, "button", "Choose")
  end

  describe "configured" do
    setup do
      with_plans()
      with_checkout_configured()
      stub_stripe(self())
      Req.Test.set_req_test_to_shared()
      {:ok, user: user!()}
    end

    test "shows each plan's price, rate and allowance; Choose opens Checkout", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/pricing")

      assert has_element?(view, "#plan-small", "$12.34")
      assert has_element?(view, "#plan-small", "300/min")
      assert has_element?(view, "#plan-large", "50 GiB")

      assert {:error, {:redirect, %{to: "https://checkout.stripe.com/c/pay/cs_test_plan"}}} =
               view |> element("#plan-small-choose") |> render_click()

      [row] = Repo.all(PlanSubscription)
      assert row.user_id == user.id
      assert row.plan_id == "small"
    end

    test "signed out: Sign in to choose, no Choose", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/pricing")
      assert has_element?(view, "#plan-small-sign-in", "Sign in to choose")
      refute has_element?(view, "#plan-small-choose")
    end

    test "back from Checkout: waiting, then Your plan once the webhook lands", %{
      conn: conn,
      user: user
    } do
      {:ok, _, _} = Bitblocks.ApiKeys.issue_trial(user)
      {:ok, _} = Bitblocks.Billing.choose(user, "small", "https://example.test")
      [row] = Repo.all(PlanSubscription)

      {:ok, view, _html} =
        conn |> signed_in(user) |> live(~p"/pricing?plan_checkout=#{row.id}")

      assert has_element?(view, "#plan-pending", "Waiting for Stripe")

      {:ok, "subscribed"} =
        StripeEvents.handle(plan_event("checkout.session.completed", completed_plan_session(row)))

      {:ok, "active"} =
        StripeEvents.handle(
          plan_event("customer.subscription.updated", subscription_object(reload(row), "active"))
        )

      assert has_element?(view, "#plan-status", "Active")
      assert has_element?(view, "#plan-rate", "300/min")
      assert has_element?(view, "#plan-renews")
      assert has_element?(view, "#plan-usage-requests", "0 of 1,000")
      assert has_element?(view, "#plan-usage-requests [role=meter][aria-valuenow='0']")
      refute has_element?(view, "#plan-small-choose")
      assert has_element?(view, "#plans-subscribed")

      assert {:error, {:redirect, %{to: "https://billing.stripe.com/p/session/test_plan"}}} =
               view |> element("#plan-manage") |> render_click()
    end

    test "a cancelled plan says so and the key is back to the trial", %{conn: conn, user: user} do
      {:ok, _} = Bitblocks.Billing.choose(user, "small", "https://example.test")
      [row] = Repo.all(PlanSubscription)

      {:ok, _} =
        StripeEvents.handle(plan_event("checkout.session.completed", completed_plan_session(row)))

      {:ok, "canceled"} =
        StripeEvents.handle(
          plan_event("customer.subscription.deleted", subscription_object(row, "canceled"))
        )

      {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/pricing")
      assert has_element?(view, "#plan-ended", "back to the trial")
      assert has_element?(view, "#plan-rate", "60/min")
      assert has_element?(view, "#plan-small-choose")
    end
  end
end
