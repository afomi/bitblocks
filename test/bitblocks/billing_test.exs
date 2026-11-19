defmodule Bitblocks.BillingTest do
  # Monthly plans (https://github.com/afomi/bitblocks/issues/112): plans as
  # config, Checkout in subscription mode for the plan's Stripe Price, and
  # only signed webhooks moving the buyer's own key to the plan's limit and
  # back, idempotent and in any order. Stripe is a Req.Test stub.
  # Not async: it sets env vars and app config.
  use Bitblocks.DataCase, async: false

  import Bitblocks.BillingFixtures

  import Bitblocks.DownloadsFixtures,
    only: [user!: 0, with_checkout_configured: 0, without_checkout: 0]

  alias Bitblocks.ApiKeys
  alias Bitblocks.Billing
  alias Bitblocks.Billing.PlanSubscription
  alias Bitblocks.Payments.StripeEvents
  alias Bitblocks.Repo
  alias Bitblocks.Usage.Rollup

  @trial ApiKeys.trial_requests_per_minute()

  setup do
    with_plans()
    with_checkout_configured()
    stub_stripe(self())
    user = user!()
    {:ok, key, token} = ApiKeys.issue_trial(user)
    {:ok, user: user, key: key, token: token}
  end

  defp chosen(user, plan_id \\ "small") do
    {:ok, _url} = Billing.choose(user, plan_id, "https://example.test")

    Repo.one!(
      from s in PlanSubscription,
        where: s.user_id == ^user.id,
        order_by: [desc: s.inserted_at],
        limit: 1
    )
  end

  defp subscribed(user, plan_id \\ "small") do
    row = chosen(user, plan_id)

    {:ok, "subscribed"} =
      StripeEvents.handle(plan_event("checkout.session.completed", completed_plan_session(row)))

    reload(row)
  end

  defp rpm(key), do: Repo.get!(Bitblocks.ApiKeys.ApiKey, key.id).requests_per_minute

  describe "plans as config" do
    test "none configured: no plans, nothing for sale" do
      with_plans([])
      assert Billing.plans() == []
      assert Billing.load_plans() == {:ok, []}
      refute Billing.for_sale?(true)
    end

    test "read from JSON, cheapest first" do
      Application.put_env(:bitblocks, Billing,
        plans_json: Jason.encode!(Enum.reverse(test_plans()))
      )

      assert Enum.map(Billing.plans(), & &1.id) == ["small", "large"]
    end

    test "one invalid plan turns every plan off, and says which" do
      bad = Map.put(hd(test_plans()), :stripe_price_id, "not-a-price")
      with_plans([bad | tl(test_plans())])

      assert Billing.plans() == []
      assert {:error, "plan 1: stripe_price_id is missing or invalid"} = Billing.load_plans()
      Application.put_env(:bitblocks, Billing, plans_json: "{nope")
      assert {:error, "BILLING_PLANS is not valid JSON"} = Billing.load_plans()
    end

    test "for sale only with plans and Stripe configured; in sandbox, admins only" do
      assert Billing.for_sale?(true)
      refute Billing.for_sale?(false)

      without_checkout()
      refute Billing.for_sale?(true)
    end
  end

  describe "choose/3" do
    test "opens Checkout in subscription mode for the plan's Price, the row its idempotency key",
         %{user: user} do
      {:ok, url} = Billing.choose(user, "small", "https://example.test")
      assert url == "https://checkout.stripe.com/c/pay/cs_test_plan"

      [row] = Repo.all(PlanSubscription)
      assert row.user_id == user.id
      assert row.status == "checkout_open"
      assert row.requests_per_minute == 300
      assert row.stripe_session_id == "cs_test_plan"

      assert_received {:stripe_request, "/v1/checkout/sessions", [idem], form}
      assert idem == row.id
      assert form["mode"] == "subscription"
      assert form["line_items[0][price]"] == "price_testsmall"
      assert form["client_reference_id"] == row.id
      assert form["subscription_data[metadata][plan_subscription_id]"] == row.id
      assert form["success_url"] == "https://example.test/pricing?plan_checkout=#{row.id}#plan"
      # The amount is the Price's, set in Stripe: none is sent.
      refute Enum.any?(Map.keys(form), &String.contains?(&1, "unit_amount"))
    end

    test "a second Choose on the same plan reopens the same Checkout", %{user: user} do
      {:ok, url} = Billing.choose(user, "small", "https://example.test")
      assert_received {:stripe_request, _, _, _}
      assert {:ok, ^url} = Billing.choose(user, "small", "https://example.test")
      refute_received {:stripe_request, _, _, _}
      assert Repo.aggregate(PlanSubscription, :count) == 1
    end

    test "refuses an unknown plan, no sign-in, no Stripe, and a second plan", %{user: user} do
      assert Billing.choose(user, "gold", "https://example.test") == {:error, :unknown_plan}
      assert Billing.choose(nil, "small", "https://example.test") == {:error, :not_signed_in}

      subscribed(user)

      assert Billing.choose(user, "large", "https://example.test") ==
               {:error, :already_subscribed}

      without_checkout()
      assert Billing.choose(user!(), "small", "https://example.test") == {:error, :not_configured}
    end
  end

  describe "webhooks move the key" do
    test "checkout.session.completed gives the buyer's key the plan's limit, key unchanged", %{
      user: user,
      key: key,
      token: token
    } do
      # Cached at the trial limit first, as a busy key would be.
      assert ApiKeys.verify(token).requests_per_minute == @trial

      row = subscribed(user)
      assert row.status == "subscribed"
      assert row.stripe_status == "active"
      assert row.stripe_customer_id =~ "cus_"

      assert rpm(key) == 300
      # The same token, the new limit, on the very next request.
      assert ApiKeys.verify(token).requests_per_minute == 300
      assert ApiKeys.verify(token).id == key.id
    end

    test "another user's key is never touched", %{user: user} do
      other = user!()
      {:ok, other_key, _} = ApiKeys.issue_trial(other)
      subscribed(user)
      assert rpm(other_key) == @trial
    end

    test "a key made later gets the plan too", %{user: user, key: key} do
      subscribed(user)
      {:ok, new_key, _} = ApiKeys.replace_trial(user)
      refute new_key.id == key.id
      assert new_key.requests_per_minute == 300
    end

    test "past due keeps the limit through Stripe's retries; unpaid ends it", %{
      user: user,
      key: key
    } do
      row = subscribed(user)
      t = System.system_time(:second)

      {:ok, "past_due"} =
        StripeEvents.handle(
          plan_event("customer.subscription.updated", subscription_object(row, "past_due"), t)
        )

      assert rpm(key) == 300
      assert Billing.state(reload(row)) == :past_due

      {:ok, "unpaid"} =
        StripeEvents.handle(
          plan_event("customer.subscription.updated", subscription_object(row, "unpaid"), t + 1)
        )

      assert rpm(key) == @trial
    end

    test "deleted returns the key to the trial limit", %{user: user, key: key, token: token} do
      row = subscribed(user)
      ApiKeys.verify(token)

      {:ok, "canceled"} =
        StripeEvents.handle(
          plan_event("customer.subscription.deleted", subscription_object(row, "canceled"))
        )

      assert rpm(key) == @trial
      assert ApiKeys.verify(token).requests_per_minute == @trial
      assert Billing.state(reload(row)) == :ended
      assert reload(row).canceled_at
    end

    test "invoice.payment_failed then invoice.paid: past due, then active again", %{
      user: user,
      key: key
    } do
      row = subscribed(user)
      t = System.system_time(:second)

      {:ok, "past_due"} =
        StripeEvents.handle(plan_event("invoice.payment_failed", invoice_object(row), t))

      assert reload(row).stripe_status == "past_due"
      assert rpm(key) == 300

      {:ok, "active"} =
        StripeEvents.handle(plan_event("invoice.paid", invoice_object(row), t + 1))

      assert reload(row).stripe_status == "active"
      assert reload(row).current_period_end
    end

    test "an older event arriving late changes nothing", %{user: user, key: key} do
      row = subscribed(user)
      t = System.system_time(:second)

      {:ok, "canceled"} =
        StripeEvents.handle(
          plan_event("customer.subscription.deleted", subscription_object(row, "canceled"), t)
        )

      {:ok, "stale"} =
        StripeEvents.handle(
          plan_event("customer.subscription.updated", subscription_object(row, "active"), t - 5)
        )

      {:ok, "stale"} = StripeEvents.handle(plan_event("invoice.paid", invoice_object(row), t - 3))

      assert reload(row).stripe_status == "canceled"
      assert rpm(key) == @trial
    end

    test "a subscription event before the Checkout event finds its row by metadata", %{
      user: user,
      key: key
    } do
      row = chosen(user)

      {:ok, "active"} =
        StripeEvents.handle(
          plan_event("customer.subscription.created", subscription_object(row, "active"))
        )

      assert reload(row).status == "subscribed"
      assert rpm(key) == 300

      # The Checkout event then never overrides what the subscription said.
      {:ok, outcome} =
        StripeEvents.handle(plan_event("checkout.session.completed", completed_plan_session(row)))

      assert outcome in ["no_change", "subscribed"]
      assert reload(row).stripe_status == "active"
      assert reload(row).current_period_end
    end

    test "a replayed event changes nothing; a test event in live mode is ignored", %{user: user} do
      row = chosen(user)
      event = plan_event("checkout.session.completed", completed_plan_session(row))
      assert {:ok, "subscribed"} = StripeEvents.handle(event)
      assert {:ok, "duplicate"} = StripeEvents.handle(event)

      other = user!()
      other_row = chosen(other)

      live_event =
        plan_event("checkout.session.completed", completed_plan_session(other_row))
        |> Map.put("livemode", true)

      assert {:ok, "wrong_mode"} = StripeEvents.handle(live_event)
      assert reload(other_row).status == "checkout_open"
    end

    test "a session not ours, or naming another row's session, opens nothing", %{user: user} do
      row = chosen(user)
      forged = completed_plan_session(row, %{"id" => "cs_someone_else"})

      assert {:ok, "unknown_plan_subscription"} =
               StripeEvents.handle(plan_event("checkout.session.completed", forged))

      assert reload(row).status == "checkout_open"
    end

    test "a plan changed in the portal moves to the new Price's plan and limits", %{
      user: user,
      key: key
    } do
      row = subscribed(user)

      moved =
        subscription_object(row, "active", %{
          "items" => %{
            "data" => [%{"price" => %{"id" => "price_testlarge", "unit_amount" => 5_678}}]
          }
        })

      {:ok, "active"} = StripeEvents.handle(plan_event("customer.subscription.updated", moved))

      assert reload(row).plan_id == "large"
      assert rpm(key) == 3_000
    end

    test "a download's Checkout event still goes to downloads" do
      assert StripeEvents.owner("checkout.session.completed", %{"mode" => "payment"}) ==
               :purchases

      assert StripeEvents.owner("checkout.session.completed", %{}) == :purchases

      assert StripeEvents.owner("checkout.session.completed", %{"mode" => "subscription"}) ==
               :billing

      assert StripeEvents.owner("invoice.paid", %{}) == :billing
      assert StripeEvents.owner("charge.refunded", %{}) == :purchases
    end
  end

  test "subscription.created after an update in the same second doesn't undo it", %{
    user: user,
    key: key
  } do
    row = chosen(user)
    t = System.system_time(:second)

    {:ok, "active"} =
      StripeEvents.handle(
        plan_event("customer.subscription.updated", subscription_object(row, "active"), t)
      )

    {:ok, "stale"} =
      StripeEvents.handle(
        plan_event("customer.subscription.created", subscription_object(row, "incomplete"), t)
      )

    assert reload(row).stripe_status == "active"
    assert rpm(key) == 300
  end

  describe "period_usage/2" do
    test "this period's requests and bytes through the user's keys, against the allowance", %{
      user: user,
      key: key
    } do
      row = subscribed(user)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      hour = DateTime.from_unix!(div(DateTime.to_unix(now), 3600) * 3600)

      Repo.insert!(%Rollup{
        hour: hour,
        caller_kind: "key",
        caller_id: to_string(key.id),
        endpoint_class: "read",
        requests: 850,
        response_bytes: 1_000
      })

      # Before the period: not counted.
      Repo.insert!(%Rollup{
        hour: DateTime.add(hour, -40 * 86_400),
        caller_kind: "key",
        caller_id: to_string(key.id),
        endpoint_class: "read",
        requests: 5_000
      })

      usage = Billing.period_usage(reload(row), now)
      assert usage.requests == 850
      assert usage.requests_percent == 85
      assert usage.level == :near

      Repo.insert!(%Rollup{
        hour: hour,
        caller_kind: "key",
        caller_id: to_string(key.id),
        endpoint_class: "stream",
        requests: 200
      })

      usage = Billing.period_usage(reload(row), now)
      assert usage.requests == 1_050
      assert usage.level == :over
      # Shown, not enforced: the key keeps the plan's rate.
      assert rpm(key) == 300
    end
  end

  describe "portal_url/2" do
    test "opens Stripe's customer portal for the user's own customer", %{user: user} do
      row = subscribed(user)

      assert {:ok, "https://billing.stripe.com/p/session/test_plan"} =
               Billing.portal_url(user, "https://example.test")

      assert_received {:stripe_request, "/v1/billing_portal/sessions", _, form}
      assert form["customer"] == row.stripe_customer_id
      assert form["return_url"] == "https://example.test/pricing#plan"
    end

    test "no customer yet: says so" do
      assert Billing.portal_url(user!(), "https://example.test") == {:error, :no_customer}
    end
  end
end
