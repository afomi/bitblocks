defmodule BitblocksWeb.StripeWebhookControllerTest do
  # POST /webhooks/stripe (https://github.com/afomi/bitblocks/issues/111): a
  # signed event over the exact body opens a download; unsigned, forged or
  # stale deliveries are refused; a replay changes nothing.
  use BitblocksWeb.ConnCase, async: false

  import Bitblocks.DownloadsFixtures

  alias Bitblocks.Downloads.{Purchase, Purchases}
  alias Bitblocks.Repo

  setup do
    with_price()
    with_checkout_configured()
    stub_checkout(self())
    stored_chain(["a block", "another block"])
    user = user!()

    {:ok, p} =
      Purchases.create(user, %{"from" => "0", "to" => "1", "data" => "raw", "format" => "bin"})

    {:ok, _} = Purchases.start_checkout(p, "https://example.test")
    {:ok, purchase: Repo.get!(Purchase, p.id)}
  end

  defp deliver(conn, body, signature) do
    conn
    |> put_req_header("content-type", "application/json")
    |> then(&if(signature, do: put_req_header(&1, "stripe-signature", signature), else: &1))
    |> post("/webhooks/stripe", body)
  end

  test "an unsigned POST is refused and changes nothing", %{conn: conn, purchase: p} do
    body = Jason.encode!(event("checkout.session.completed", completed_session(p)))

    conn = deliver(conn, body, nil)
    assert json_response(conn, 400) == %{"error" => "no_signature"}
    assert Repo.get!(Purchase, p.id).status == "checkout_open"
  end

  test "a forged signature is refused", %{conn: conn, purchase: p} do
    {body, _} = signed(event("checkout.session.completed", completed_session(p)))
    {_, forged} = signed(%{"id" => "evt_x"}, "whsec_not_ours")

    conn = deliver(conn, body, forged)
    assert json_response(conn, 400) == %{"error" => "bad_signature"}
    assert Repo.get!(Purchase, p.id).status == "checkout_open"
  end

  test "a signed checkout.session.completed opens the download, once", %{conn: conn, purchase: p} do
    {body, signature} = signed(event("checkout.session.completed", completed_session(p)))

    assert json_response(deliver(conn, body, signature), 200) == %{
             "received" => true,
             "outcome" => "paid"
           }

    paid = Repo.get!(Purchase, p.id)
    assert paid.status == "paid"

    replay = deliver(build_conn(), body, signature)
    assert json_response(replay, 200)["outcome"] == "duplicate"
    assert Repo.get!(Purchase, p.id) == paid
  end

  test "while Checkout is dormant, every delivery is a 503", %{conn: conn, purchase: p} do
    {body, signature} = signed(event("checkout.session.completed", completed_session(p)))
    without_checkout()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert json_response(deliver(conn, body, signature), 503) == %{
                 "error" => "not_configured"
               }
      end)

    # Logged, so a registered endpoint sending into a dormant app shows up (#143).
    assert log =~ "no webhook secret is set"
    assert Repo.get!(Purchase, p.id).status == "checkout_open"
  end

  test "the same endpoint moves a subscriber's key to the plan, signed only (#112)", %{
    conn: conn
  } do
    import Bitblocks.BillingFixtures

    with_plans()
    stub_stripe(self())
    user = user!()
    {:ok, key, _token} = Bitblocks.ApiKeys.issue_trial(user)
    {:ok, _} = Bitblocks.Billing.choose(user, "small", "https://example.test")
    [row] = Repo.all(Bitblocks.Billing.PlanSubscription)
    event = plan_event("checkout.session.completed", completed_plan_session(row))

    {body, _} = signed(event)
    {_, forged} = signed(event, "whsec_not_ours")
    assert json_response(deliver(conn, body, forged), 400) == %{"error" => "bad_signature"}
    assert Repo.get!(Bitblocks.ApiKeys.ApiKey, key.id).requests_per_minute == 60

    {body, signature} = signed(event)
    assert json_response(deliver(build_conn(), body, signature), 200)["outcome"] == "subscribed"
    assert Repo.get!(Bitblocks.ApiKeys.ApiKey, key.id).requests_per_minute == 300
  end

  test "the success redirect alone opens nothing", %{conn: conn, purchase: p} do
    conn = conn |> init_test_session(%{"user_id" => p.user_id}) |> get("/downloads/#{p.id}")
    assert html_response(conn, 200) =~ "Waiting for payment confirmation"
    assert Repo.get!(Purchase, p.id).status == "checkout_open"
  end
end
