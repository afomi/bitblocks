defmodule BitblocksWeb.Plugs.RateLimiter.X402Test do
  @moduledoc """
  An AI crawler over its budget can pay for the request with x402
  (Bitblocks.Payments.X402, docs/STRIPE.md). The facilitator and Stripe are
  Req.Test stubs: no network calls.
  """
  # async: false — the limiter's ETS table, app config and env vars are global.
  use BitblocksWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Bitblocks.ApiKeys
  alias Bitblocks.Payments.X402, as: Pay
  alias Bitblocks.Payments.X402Guard
  alias Bitblocks.Repo

  @meta_ua "Mozilla/5.0 (compatible; meta-externalagent/1.1; +https://developers.facebook.com/docs/sharing/webmasters/crawler)"
  # Obviously fake values: no real address, hash or key.
  @pay_to "0x000000000000000000000000000000000000dEaD"
  @payer "0x000000000000000000000000000000000000bEEF"
  @tx "0x000000000000000000000000000000000000000000000000000000000000dead"
  @facilitator __MODULE__.Facilitator
  @stripe __MODULE__.Stripe

  setup do
    case :ets.whereis(:rate_limiter) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:rate_limiter)
    end

    limiter = Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter)
    pay = Application.get_env(:bitblocks, Pay)
    key = System.get_env("STRIPE_SANDBOX_SECRET_KEY")

    Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter,
      max_requests: 100,
      ai_crawler_max_requests: 1,
      ai_fetcher_max_requests: 1
    )

    enable()
    # A bare prefix, no key: x402_ex checks only the prefix before calling the stub.
    System.put_env("STRIPE_SANDBOX_SECRET_KEY", "rk_test_")

    on_exit(fn ->
      Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, limiter)
      Application.put_env(:bitblocks, Pay, pay)

      if key,
        do: System.put_env("STRIPE_SANDBOX_SECRET_KEY", key),
        else: System.delete_env("STRIPE_SANDBOX_SECRET_KEY")
    end)

    test = self()

    Req.Test.stub(@facilitator, fn conn ->
      send(test, {:facilitator, conn.request_path})

      case conn.request_path do
        "/facilitator/verify" ->
          Req.Test.json(conn, %{"isValid" => true, "payer" => @payer})

        "/facilitator/settle" ->
          Req.Test.json(conn, %{
            "success" => true,
            "transaction" => @tx,
            "network" => "eip155:84532",
            "payer" => @payer
          })
      end
    end)

    Req.Test.stub(@stripe, fn conn ->
      send(test, {:stripe, conn.request_path, Plug.Conn.get_req_header(conn, "idempotency-key")})
      Req.Test.json(conn, %{"id" => "pi_test_x402"})
    end)

    :ok
  end

  defp enable(overrides \\ []) do
    Application.put_env(
      :bitblocks,
      Pay,
      Keyword.merge(
        [
          enabled: true,
          network: "eip155:84532",
          pay_to: @pay_to,
          price_atomic: 10_000,
          facilitator: "x402org",
          facilitator_opts: [req_options: [plug: {Req.Test, @facilitator}]],
          stripe_opts: [req_options: [plug: {Req.Test, @stripe}]],
          deposit_req_options: [plug: {Req.Test, @stripe}],
          paid_per_ip_per_minute: 30,
          paid_per_family_per_minute: 600
        ],
        overrides
      )
    )
  end

  defp request(path, headers \\ [], ip \\ "57.141.0.1") do
    build_conn()
    |> put_req_header("user-agent", @meta_ua)
    |> put_req_header("x-forwarded-for", ip)
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    end)
    |> get(path)
  end

  # Spends the family's budget of 1.
  defp over_budget, do: assert(request("/about").status == 200)

  # A PaymentPayload for `path`, matching our offer unless changed by `fun`.
  defp payment(path, fun \\ & &1, nonce \\ 1) do
    offer = Pay.offer(Plug.Test.conn(:get, path))

    %{
      "x402Version" => 2,
      "resource" => %{"url" => offer.resource, "description" => offer.description},
      "accepted" => X402.Offer.requirements(offer),
      "payload" => %{
        "signature" => "0x" <> String.duplicate("ab", 65),
        "authorization" => %{
          "from" => @payer,
          "to" => offer.pay_to,
          "value" => offer.amount,
          "validAfter" => "1740672089",
          "validBefore" => "1740672154",
          "nonce" => "0x" <> String.pad_leading(Integer.to_string(nonce, 16), 64, "0")
        }
      }
    }
    |> fun.()
    |> X402.Codec.encode()
  end

  defp paid(path, header, ip \\ "57.141.0.1") do
    with_log(fn -> request(path, [{"payment-signature", header}], ip) end) |> elem(0)
  end

  defp challenge(conn) do
    assert [header] = get_resp_header(conn, "payment-required")
    assert {:ok, decoded} = X402.Codec.decode(header)
    decoded
  end

  defp rows,
    do:
      Repo.all(
        from p in "x402_payments",
          select: map(p, [:key, :kind, :app, :pay_to, :amount, :tx_hash, :payment_intent_id]),
          order_by: p.id
      )

  describe "no payment header" do
    test "the 402 keeps its body and links, and carries a valid PAYMENT-REQUIRED offer" do
      over_budget()
      conn = request("/about")

      assert conn.status == 402
      assert conn.resp_body =~ "rate-limited as an AI crawler (meta)"
      assert conn.resp_body =~ "https://bitblocks.app/pricing#crawlers"

      offer = challenge(conn)
      assert offer["x402Version"] == 2
      assert offer["resource"]["url"] == BitblocksWeb.Endpoint.url() <> "/about"
      assert [accept] = offer["accepts"]
      assert accept["scheme"] == "exact"
      assert accept["network"] == "eip155:84532"
      assert accept["amount"] == "10000"
      assert accept["payTo"] == @pay_to
      assert accept["asset"] == "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
      refute_received {:facilitator, _}
    end

    test "under /api/ the JSON body is unchanged too" do
      over_budget()
      conn = request("/api/v1/blocks")

      assert conn.status == 402
      assert Jason.decode!(conn.resp_body)["error"] == "ai_crawler_rate_limited"
      assert challenge(conn)["resource"]["url"] =~ "/api/v1/blocks"
    end
  end

  describe "a paid retry" do
    test "is served with PAYMENT-RESPONSE, claimed in x402_payments and recorded in Stripe" do
      over_budget()
      conn = paid("/about", payment("/about"))

      assert conn.status == 200
      assert [response] = get_resp_header(conn, "payment-response")
      assert {:ok, %{"success" => true, "transaction" => @tx}} = X402.Codec.decode(response)
      assert get_resp_header(conn, "payment-required") == []

      assert_received {:facilitator, "/facilitator/verify"}
      assert_received {:facilitator, "/facilitator/settle"}
      assert_received {:stripe, "/v1/payment_intents", [@tx]}

      assert [auth, tx] = rows()
      assert auth.kind == "authorization"
      assert String.starts_with?(auth.key, "auth:")
      assert tx.kind == "transaction"
      assert tx.key == "tx:eip155:84532:" <> @tx
      assert tx.app == "bitblocks"
      assert tx.amount == "10000"
      assert tx.payment_intent_id == "pi_test_x402"
    end

    test "for the wrong amount is refused with a fresh offer, before the facilitator" do
      over_budget()

      header =
        payment("/about", fn p ->
          p
          |> put_in(["accepted", "amount"], "1")
          |> put_in(["payload", "authorization", "value"], "1")
        end)

      conn = paid("/about", header)

      assert conn.status == 402
      assert challenge(conn)["accepts"] |> hd() |> Map.get("amount") == "10000"
      assert get_resp_header(conn, "payment-response") == []
      refute_received {:facilitator, _}
      assert rows() == []
    end

    test "to the wrong payTo is refused" do
      over_budget()
      other = "0x0000000000000000000000000000000000000001"

      header =
        payment("/about", fn p ->
          p
          |> put_in(["accepted", "payTo"], other)
          |> put_in(["payload", "authorization", "to"], other)
        end)

      conn = paid("/about", header)

      assert conn.status == 402
      assert challenge(conn)["accepts"] |> hd() |> Map.get("payTo") == @pay_to
      refute_received {:facilitator, _}
      assert rows() == []
    end

    test "replayed is refused, and settles nothing twice" do
      over_budget()
      header = payment("/about")

      assert paid("/about", header).status == 200
      assert_received {:facilitator, "/facilitator/settle"}

      replay = paid("/about", header)
      assert replay.status == 402
      assert challenge(replay)
      refute_received {:facilitator, "/facilitator/settle"}
      assert length(rows()) == 2
    end

    test "with the facilitator down gets a 503 with no content" do
      Req.Test.stub(@facilitator, &Req.Test.transport_error(&1, :econnrefused))
      over_budget()

      conn = paid("/about", payment("/about"))

      assert conn.status == 503
      assert conn.resp_body == ""
      assert get_resp_header(conn, "payment-response") == []
      assert rows() == []
    end

    test "has its own budget per IP, checked before the facilitator" do
      enable(paid_per_ip_per_minute: 1)
      over_budget()

      assert paid("/about", payment("/about", & &1, 1)).status == 200
      assert_received {:facilitator, "/facilitator/verify"}
      assert_received {:facilitator, "/facilitator/settle"}

      conn = paid("/about", payment("/about", & &1, 2))
      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") != []
      refute_received {:facilitator, _}

      # Another address of the same family has its own. (Its own transaction
      # too: one hash reported for two authorizations is refused.)
      other_tx = "0x" <> String.duplicate("0", 60) <> "beef"

      Req.Test.stub(@facilitator, fn conn ->
        case conn.request_path do
          "/facilitator/verify" ->
            Req.Test.json(conn, %{"isValid" => true, "payer" => @payer})

          "/facilitator/settle" ->
            Req.Test.json(conn, %{
              "success" => true,
              "transaction" => other_tx,
              "network" => "eip155:84532",
              "payer" => @payer
            })
        end
      end)

      assert paid("/about", payment("/about", & &1, 3), "57.141.0.2").status == 200
    end
  end

  describe "an anonymous caller past the shared budget, end to end" do
    # Any browser, any address: no crawler family, so only the site-wide
    # budget (1 here) stands between it and the 402.
    @browser_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    setup do
      Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter,
        max_requests: 100,
        anonymous_site_max_requests: 1
      )

      :ok
    end

    defp anon(path, headers \\ [], ip \\ "203.0.113.1") do
      {conn, _log} =
        with_log(fn ->
          build_conn()
          |> put_req_header("user-agent", @browser_ua)
          |> put_req_header("x-forwarded-for", ip)
          |> then(fn conn ->
            Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
          end)
          |> get(path)
        end)

      conn
    end

    defp spend_site_budget, do: assert(anon("/about", [], "203.0.113.200").status == 200)

    test "402 with PAYMENT-REQUIRED, a paid retry served with PAYMENT-RESPONSE, claimed once, a replay refused" do
      spend_site_budget()

      # 1. Past the shared budget, from an address that has made no request.
      refused = anon("/about")
      assert refused.status == 402
      assert refused.resp_body =~ "Everyone reading Bitblocks without a key shares 1 requests"
      offer = challenge(refused)
      assert offer["resource"]["url"] == BitblocksWeb.Endpoint.url() <> "/about"
      assert [%{"payTo" => @pay_to, "network" => "eip155:84532"}] = offer["accepts"]
      refute_received {:facilitator, _}

      # 2. The same request, paid.
      header = payment("/about")
      served = anon("/about", [{"payment-signature", header}])

      assert served.status == 200
      assert [response] = get_resp_header(served, "payment-response")
      assert {:ok, %{"success" => true, "transaction" => @tx}} = X402.Codec.decode(response)
      assert get_resp_header(served, "payment-required") == []
      assert_received {:facilitator, "/facilitator/verify"}
      assert_received {:facilitator, "/facilitator/settle"}
      assert_received {:stripe, "/v1/payment_intents", [@tx]}

      # 3. Claimed exactly once in x402_payments.
      assert [auth, tx] = rows()
      assert auth.kind == "authorization"
      assert tx.key == "tx:eip155:84532:" <> @tx
      assert tx.payment_intent_id == "pi_test_x402"

      # 4. The same payment again is refused with a fresh offer, and settles nothing.
      replay = anon("/about", [{"payment-signature", header}], "203.0.113.2")
      assert replay.status == 402
      assert challenge(replay)
      assert get_resp_header(replay, "payment-response") == []
      refute_received {:facilitator, "/facilitator/settle"}
      assert length(rows()) == 2
    end

    test "a refused payment (the wrong amount) gets the 402 again, before the facilitator" do
      spend_site_budget()

      header =
        payment("/about", fn p ->
          p
          |> put_in(["accepted", "amount"], "1")
          |> put_in(["payload", "authorization", "value"], "1")
        end)

      conn = anon("/about", [{"payment-signature", header}])

      assert conn.status == 402
      assert challenge(conn)["accepts"] |> hd() |> Map.get("amount") == "10000"
      refute_received {:facilitator, _}
      assert rows() == []
    end

    test "an unavailable facilitator gets a 503 with no content, and nothing is claimed" do
      Req.Test.stub(@facilitator, &Req.Test.transport_error(&1, :econnrefused))
      spend_site_budget()

      conn = anon("/about", [{"payment-signature", payment("/about")}])

      assert conn.status == 503
      assert conn.resp_body == ""
      assert rows() == []
    end

    test "the HTML 402 offers x402 to agents last, and the API's JSON says it is offered" do
      spend_site_budget()

      html = anon("/about", [{"accept", "text/html"}])
      assert html.status == 402
      assert html.resp_body =~ ~s(id="way-x402")
      assert get_resp_header(html, "payment-required") != []

      json = anon("/api/v1/blocks")
      assert json.status == 402
      assert Jason.decode!(json.resp_body)["ways_in"]["pay_per_request"]["offered"] == true
    end
  end

  describe "not offered" do
    test "when x402 is off: today's plain 402, unchanged" do
      enable(enabled: false)
      over_budget()

      conn = request("/about", [{"payment-signature", payment("/about")}])

      assert conn.status == 402
      assert get_resp_header(conn, "payment-required") == []
      assert conn.resp_body =~ "rate-limited as an AI crawler (meta)"
      refute_received {:facilitator, _}
    end

    test "when enabled without a deposit address" do
      enable(pay_to: nil)
      refute Pay.enabled?()
      assert Pay.status() == :no_pay_to
      over_budget()

      assert get_resp_header(request("/about"), "payment-required") == []
    end

    test "for a route the payment couldn't open (the API behind its sign-in gate)" do
      Application.put_env(:bitblocks, :admin_auth, enabled: true)
      on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, enabled: false) end)
      over_budget()

      conn = request("/api/v1/blocks", [{"payment-signature", payment("/api/v1/blocks")}])

      assert conn.status == 402
      assert get_resp_header(conn, "payment-required") == []
      refute_received {:facilitator, _}
    end

    test "for a request with a bad key, which gets its 401" do
      over_budget()

      conn =
        request("/about", [{"x-api-key", "bbk_nope"}, {"payment-signature", payment("/about")}])

      assert conn.status == 402
      assert get_resp_header(conn, "payment-required") == []
      refute_received {:facilitator, _}
    end
  end

  describe "never charged" do
    test "a crawler with a valid bbk_ key has its key's budget" do
      {:ok, _key, token} = ApiKeys.create("crawler-co", 20)
      over_budget()

      for _ <- 1..5 do
        conn = request("/about", [{"authorization", "Bearer #{token}"}])
        assert conn.status == 200
        assert get_resp_header(conn, "payment-required") == []
      end
    end

    test "/pricing is never blocked, with x402 on or off" do
      over_budget()
      assert request("/about").status == 402

      for _ <- 1..3, do: assert(request("/pricing").status == 200)

      enable(enabled: false)
      assert request("/pricing").status == 200
      refute_received {:facilitator, _}
    end
  end

  describe "/pricing#crawlers" do
    test "gives the price, network and how to pay while x402 is on" do
      {:ok, view, _html} = live(build_conn(), "/pricing")

      assert has_element?(view, "#crawlers-x402-heading", "Paying with x402")
      assert has_element?(view, "#crawlers-x402-price", "0.01 USDC")
      assert has_element?(view, "#crawlers-x402-network", "Base Sepolia")
      assert has_element?(view, "#crawlers-x402", "PAYMENT-SIGNATURE")
    end

    test "shows no price while x402 is off" do
      enable(enabled: false)
      {:ok, view, _html} = live(build_conn(), "/pricing")

      refute has_element?(view, "#crawlers-x402")
      assert has_element?(view, "#crawlers-contact")
    end
  end

  describe "reconciling with Stripe" do
    test "records a settled payment that has no PaymentIntent" do
      meta = %{
        kind: :transaction,
        app: "bitblocks",
        network: "eip155:84532",
        asset: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
        pay_to: @pay_to,
        payer: @payer,
        amount: "10000",
        resource: BitblocksWeb.Endpoint.url() <> "/about",
        tx_hash: @tx,
        auth_key: "auth:x",
        dispute: nil
      }

      assert :ok = X402Guard.claim("tx:eip155:84532:" <> @tx, meta, [])
      assert X402Guard.claim("tx:eip155:84532:" <> @tx, meta, []) == {:error, :replayed}
      assert [%{payment_intent_id: nil}] = rows()

      output =
        capture_io(fn ->
          capture_log(fn ->
            assert {:ok, %{recorded: [{@tx, "pi_test_x402"}], failed: []}} =
                     Bitblocks.Release.x402_reconcile()
          end)
        end)

      assert output =~ "1 recorded, 0 failed"
      assert_received {:stripe, "/v1/payment_intents", [@tx]}
      assert [%{payment_intent_id: "pi_test_x402"}] = rows()

      # Nothing left: a second run records nothing.
      capture_io(fn -> assert {:ok, %{recorded: []}} = Bitblocks.Release.x402_reconcile() end)
    end

    test "does nothing while x402 is off" do
      enable(enabled: false)
      assert Pay.reconcile() == {:ok, :disabled}
      assert :ok = Bitblocks.Workers.X402ReconcileWorker.perform(%Oban.Job{args: %{}})
      refute_received {:stripe, _, _}
    end
  end

  describe "Release.x402_status/0" do
    test "says plainly what is missing, naming variables and never a key" do
      enable(enabled: false, pay_to: nil)
      System.delete_env("STRIPE_SANDBOX_SECRET_KEY")

      output = capture_io(fn -> assert Bitblocks.Release.x402_status() == :disabled end)

      assert output =~ "x402: off (disabled)"
      assert output =~ "X402_ENABLED is not true"
      assert output =~ "X402_PAY_TO is not set"
      assert output =~ "Release.x402_create_deposit_address/1"
      assert output =~ "STRIPE_SANDBOX_SECRET_KEY is not set"
    end

    test "names nothing missing once it is on, and prints no key" do
      output = capture_io(fn -> assert Bitblocks.Release.x402_status() == :ok end)

      assert output =~ "x402: on"
      assert output =~ "missing:     nothing"
      assert output =~ "payments:    0 settled, 0 not yet in Stripe"
      refute output =~ "rk_test_"
    end

    test "warns that Base mainnet can't settle through the testnet facilitator" do
      enable(network: "eip155:8453")
      previous = System.get_env("STRIPE_SECRET_KEY")
      System.put_env("STRIPE_SECRET_KEY", "rk_live_")

      on_exit(fn ->
        if previous,
          do: System.put_env("STRIPE_SECRET_KEY", previous),
          else: System.delete_env("STRIPE_SECRET_KEY")
      end)

      output = capture_io(fn -> Bitblocks.Release.x402_status() end)
      assert output =~ "Base mainnet needs the CDP facilitator"
    end
  end

  describe "the deposit address" do
    test "a dry run calls nothing and names no key" do
      output =
        capture_io(fn ->
          assert {:dry_run, plan} = Bitblocks.Release.x402_create_deposit_address(network: "base")
          assert plan.key_env == "STRIPE_SANDBOX_SECRET_KEY"
          assert plan.stripe_version == "2026-07-29.preview"
        end)

      assert output =~ "Dry run"
      refute output =~ "rk_test_"
      refute_received {:stripe, _, _}
    end

    test "apply: true posts network=base and prints only the address" do
      address = "0x" <> String.duplicate("0", 36) <> "f00d"
      test = self()

      Req.Test.stub(@stripe, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(
          test,
          {:deposit, conn.request_path, body, Plug.Conn.get_req_header(conn, "stripe-version")}
        )

        Req.Test.json(conn, %{"address" => address, "network" => "base"})
      end)

      output =
        capture_io(fn ->
          assert {:ok, ^address} =
                   Bitblocks.Release.x402_create_deposit_address(network: "base", apply: true)
        end)

      assert output == address <> "\n"

      assert_received {:deposit, "/v1/crypto/deposit_addresses", "network=base",
                       ["2026-07-29.preview"]}
    end

    test "a Stripe refusal names no key" do
      Req.Test.stub(@stripe, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{
          "error" => %{
            "type" => "invalid_request_error",
            "message" => "Invalid API Key provided: rk_test_"
          }
        })
      end)

      output =
        capture_io(fn ->
          assert {:error, {:stripe_error, 401, {"invalid_request_error", nil}}} =
                   Bitblocks.Release.x402_create_deposit_address(apply: true)
        end)

      refute output =~ "rk_test"
    end
  end
end
