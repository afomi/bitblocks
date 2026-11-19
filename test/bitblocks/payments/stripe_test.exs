defmodule Bitblocks.Payments.StripeTest do
  # Checkout configuration and webhook signatures for paid downloads
  # (https://github.com/afomi/bitblocks/issues/111). No network: the signature
  # is checked against Stripe's published scheme, computed here.
  # Not async: it sets environment variables.
  use ExUnit.Case, async: false

  import Bitblocks.DownloadsFixtures

  alias Bitblocks.Payments.Stripe

  @secret "whsec_test_signing"
  @body ~s({"id":"evt_1","type":"checkout.session.completed","livemode":false,"data":{"object":{}}})

  describe "status/0" do
    test "dormant with no key or no webhook secret" do
      without_checkout()
      assert Stripe.status() == :no_key
      refute Stripe.configured?()

      System.put_env("STRIPE_SANDBOX_SECRET_KEY", "rk_test_x")
      assert Stripe.status() == :no_webhook_secret

      System.put_env("STRIPE_SANDBOX_WEBHOOK_SECRET", "not-a-secret")
      assert Stripe.status() == :webhook_secret_malformed
    end

    test "a live key in sandbox mode is refused" do
      without_checkout()
      System.put_env("STRIPE_SANDBOX_SECRET_KEY", "sk_live_x")
      System.put_env("STRIPE_SANDBOX_WEBHOOK_SECRET", @secret)
      assert Stripe.status() == :key_mode_mismatch
    end

    test "configured with a test key and a webhook secret" do
      with_checkout_configured()
      assert Stripe.configured?()
      assert Stripe.mode() == "sandbox"
      refute Stripe.livemode?()
    end

    test "no session is created while dormant" do
      without_checkout()

      assert {:error, {:not_configured, :no_key}} =
               Stripe.create_checkout_session(%{}, "purchase-id")
    end
  end

  describe "verify_webhook/3" do
    test "accepts Stripe's signature over the exact body" do
      now = 1_800_000_000
      header = Stripe.sign(@body, @secret, now)

      assert {:ok, %{"id" => "evt_1"}} =
               Stripe.verify_webhook(@body, header, secret: @secret, now: now)
    end

    test "accepts any one matching v1 among several (a secret being rolled)" do
      now = 1_800_000_000
      "t=" <> _ = header = Stripe.sign(@body, @secret, now)

      header =
        "t=#{now},v1=#{String.duplicate("0", 64)}," <>
          (header |> String.split(",") |> List.last())

      assert {:ok, _} = Stripe.verify_webhook(@body, header, secret: @secret, now: now)
    end

    test "refuses a changed body, a wrong secret, or no signature" do
      now = 1_800_000_000
      header = Stripe.sign(@body, @secret, now)

      assert {:error, :bad_signature} =
               Stripe.verify_webhook(@body <> " ", header, secret: @secret, now: now)

      assert {:error, :bad_signature} =
               Stripe.verify_webhook(@body, header, secret: "whsec_other", now: now)

      assert {:error, :no_signature} =
               Stripe.verify_webhook(@body, nil, secret: @secret, now: now)

      assert {:error, :no_signature} =
               Stripe.verify_webhook(@body, "t=#{now}", secret: @secret, now: now)

      assert {:error, :no_signature} =
               Stripe.verify_webhook(@body, "garbage", secret: @secret, now: now)
    end

    test "refuses a delivery signed outside the five-minute tolerance, so it can't be replayed later" do
      t = 1_800_000_000
      header = Stripe.sign(@body, @secret, t)

      assert {:ok, _} = Stripe.verify_webhook(@body, header, secret: @secret, now: t + 300)

      assert {:error, :timestamp_outside_tolerance} =
               Stripe.verify_webhook(@body, header, secret: @secret, now: t + 301)

      assert {:error, :timestamp_outside_tolerance} =
               Stripe.verify_webhook(@body, header, secret: @secret, now: t - 301)
    end

    test "with no signing secret, nothing verifies" do
      assert {:error, :not_configured} = Stripe.verify_webhook(@body, "t=1,v1=00", secret: nil)
    end

    test "a signed body that isn't an event is refused" do
      now = 1_800_000_000
      body = ~s({"hello":"world"})

      assert {:error, :invalid_payload} =
               Stripe.verify_webhook(body, Stripe.sign(body, @secret, now),
                 secret: @secret,
                 now: now
               )
    end
  end

  test "checkout_form/1 is one card payment of the stored amount, in USD" do
    form =
      Stripe.checkout_form(%{
        amount_cents: 250,
        name: "Blocks 0 to 9",
        success_url: "https://example.test/downloads/x",
        cancel_url: "https://example.test/pricing",
        client_reference_id: "x",
        metadata: %{purchase_id: "x"}
      })

    assert {"mode", "payment"} in form
    assert {"payment_method_types[0]", "card"} in form
    assert {"line_items[0][quantity]", "1"} in form
    assert {"line_items[0][price_data][unit_amount]", "250"} in form
    assert {"line_items[0][price_data][currency]", "usd"} in form
    assert {"metadata[purchase_id]", "x"} in form
  end

  test "subscription_checkout_form/1 names the plan's Price and no amount" do
    form =
      Stripe.subscription_checkout_form(%{
        price_id: "price_x",
        success_url: "https://example.test/pricing#plan",
        cancel_url: "https://example.test/pricing#plans",
        client_reference_id: "row",
        customer: "cus_x",
        metadata: %{plan_subscription_id: "row"}
      })

    assert {"mode", "subscription"} in form
    assert {"line_items[0][price]", "price_x"} in form
    assert {"customer", "cus_x"} in form
    assert {"subscription_data[metadata][plan_subscription_id]", "row"} in form
    refute Enum.any?(form, fn {k, _} -> String.contains?(k, "amount") end)
  end

  test "a portal session goes only to Stripe's billing host, and needs a customer" do
    with_checkout_configured()

    Req.Test.stub(Stripe, fn conn ->
      Req.Test.json(conn, %{"id" => "bps_1", "url" => "https://evil.example/p"})
    end)

    assert Stripe.create_portal_session("cus_x", "https://example.test") ==
             {:error, :invalid_response}

    assert Stripe.create_portal_session(nil, "https://example.test") == {:error, :no_customer}
  end
end
