defmodule Bitblocks.BillingFixtures do
  @moduledoc """
  Monthly plans in tests (https://github.com/afomi/bitblocks/issues/112):
  plans the test defines (no real price lives in the repo), Stripe's
  subscription events as the webhook decodes them, and a `Req.Test` stub
  for Checkout and the customer portal. No Stripe call is ever made.
  """

  alias Bitblocks.Billing.PlanSubscription
  alias Bitblocks.Payments.Stripe
  alias Bitblocks.Repo

  @plans [
    %{
      id: "small",
      name: "Small",
      price_cents: 1_234,
      stripe_price_id: "price_testsmall",
      requests_per_minute: 300,
      monthly_requests: 1_000,
      monthly_gib: 1
    },
    %{
      id: "large",
      name: "Large",
      price_cents: 5_678,
      stripe_price_id: "price_testlarge",
      requests_per_minute: 3_000,
      monthly_requests: 100_000,
      monthly_gib: 50
    }
  ]

  def test_plans, do: @plans

  @doc "Configures `plans` (the test plans by default) for the test; restored on exit."
  def with_plans(plans \\ @plans) do
    previous = Application.get_env(:bitblocks, Bitblocks.Billing)
    Application.put_env(:bitblocks, Bitblocks.Billing, plans: plans)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:bitblocks, Bitblocks.Billing, previous),
        else: Application.delete_env(:bitblocks, Bitblocks.Billing)
    end)
  end

  @doc """
  Stubs Stripe: a Checkout session (`cs_test_plan`) or a portal session
  (`bps_test_plan`), by path; sends each request to the test process as
  `{:stripe_request, path, idempotency_key, form}`.
  """
  def stub_stripe(test_pid) do
    Req.Test.stub(Stripe, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:stripe_request, conn.request_path, Plug.Conn.get_req_header(conn, "idempotency-key"),
         URI.decode_query(body)}
      )

      case conn.request_path do
        "/v1/billing_portal/sessions" ->
          Req.Test.json(conn, %{
            "id" => "bps_test_plan",
            "url" => "https://billing.stripe.com/p/session/test_plan"
          })

        _ ->
          Req.Test.json(conn, %{
            "id" => "cs_test_plan",
            "url" => "https://checkout.stripe.com/c/pay/cs_test_plan"
          })
      end
    end)
  end

  @doc "A Stripe event map with `created` (unix seconds), as the webhook decodes one."
  def plan_event(type, object, created \\ System.system_time(:second)) do
    %{
      "id" => "evt_" <> Integer.to_string(System.unique_integer([:positive])),
      "object" => "event",
      "type" => type,
      "created" => created,
      "livemode" => false,
      "data" => %{"object" => object}
    }
  end

  @doc "The checkout.session.completed object for a plan's open Checkout."
  def completed_plan_session(%PlanSubscription{} = s, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => s.stripe_session_id,
        "object" => "checkout.session",
        "mode" => "subscription",
        "client_reference_id" => s.id,
        "status" => "complete",
        "payment_status" => "paid",
        "subscription" => "sub_" <> String.replace(s.id, "-", ""),
        "customer" => "cus_test" <> String.slice(String.replace(s.id, "-", ""), 0, 8)
      },
      attrs
    )
  end

  @doc "A subscription object for a row, as `customer.subscription.*` carries it."
  def subscription_object(%PlanSubscription{} = s, status, attrs \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "id" => "sub_" <> String.replace(s.id, "-", ""),
        "object" => "subscription",
        "customer" => "cus_test" <> String.slice(String.replace(s.id, "-", ""), 0, 8),
        "status" => status,
        "cancel_at_period_end" => false,
        "current_period_start" => now - 86_400,
        "current_period_end" => now + 29 * 86_400,
        "metadata" => %{"plan_subscription_id" => s.id},
        "items" => %{
          "data" => [
            %{"price" => %{"id" => s.stripe_price_id, "unit_amount" => s.price_cents}}
          ]
        }
      },
      attrs
    )
  end

  @doc "An invoice object for a row's subscription."
  def invoice_object(%PlanSubscription{} = s, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "in_" <> Integer.to_string(System.unique_integer([:positive])),
        "object" => "invoice",
        "subscription" => "sub_" <> String.replace(s.id, "-", ""),
        "lines" => %{
          "data" => [%{"period" => %{"end" => System.system_time(:second) + 30 * 86_400}}]
        }
      },
      attrs
    )
  end

  def reload(%PlanSubscription{id: id}), do: Repo.get!(PlanSubscription, id)
end
