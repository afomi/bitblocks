defmodule BitblocksWeb.Plugs.RateLimiterBsv402Test do
  @moduledoc """
  The 402 past a shared budget, paid in BSV as BRC-121 describes
  (docs/BSV_402.md, slice 2): the terms on the 402, a paid retry checked
  against our headers, claimed once, sent to our (stubbed) node and served
  with what was paid, each refusal with its reason, and the 503.

  The payment's coin is the genesis coinbase, so its BUMP proves against a
  real header (`Bitblocks.RealHeaders`). The keys are the vectors' test keys.
  """
  # async: false: the limiter's ETS table, app config, env vars and RpcStub are global.
  use BitblocksWeb.ConnCase, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Bitblocks.Bsv402Fixtures, as: F
  alias Bitblocks.Interop.Brc42
  alias Bitblocks.Payments.{Bsv402, BsvPayment}
  alias Bitblocks.Payments.X402, as: X402Pay
  alias Bitblocks.{RealHeaders, Repo}
  alias BitblocksWeb.RpcStub

  @meta_ua "Mozilla/5.0 (compatible; meta-externalagent/1.1; +https://developers.facebook.com/docs/sharing/webmasters/crawler)"
  @env "BSV402_TEST_IDENTITY_KEY"
  @price 100

  # Block 0's only transaction, so its txid is the genesis merkle root.
  @genesis_coinbase Base.decode16!(
                      "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000",
                      case: :lower
                    )

  setup do
    case :ets.whereis(:rate_limiter) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:rate_limiter)
    end

    limiter = Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter)
    bsv = Application.get_env(:bitblocks, Bsv402)
    x402 = Application.get_env(:bitblocks, X402Pay)
    env = System.get_env(@env)

    Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter,
      max_requests: 100,
      ai_crawler_max_requests: 1
    )

    System.put_env(@env, Base.encode16(F.server_private(), case: :lower))
    enable()
    RpcStub.setup()

    on_exit(fn ->
      Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, limiter)
      Application.put_env(:bitblocks, Bsv402, bsv)
      Application.put_env(:bitblocks, X402Pay, x402)
      if env, do: System.put_env(@env, env), else: System.delete_env(@env)
      RpcStub.clear()
    end)

    RealHeaders.insert(0)
    :ok
  end

  defp enable(enabled \\ true) do
    Application.put_env(:bitblocks, Bsv402,
      enabled: enabled,
      price_sats: Integer.to_string(@price),
      identity_key_env: @env
    )
  end

  defp server_key, do: F.server_private() |> Brc42.public_key() |> Base.encode16(case: :lower)

  defp now, do: Integer.to_string(System.system_time(:millisecond))

  # A payment from the genesis coinbase, proven by block 0, for now.
  defp payment(opts \\ []) do
    {coin, opts} = Keyword.pop(opts, :coin, @genesis_coinbase)
    F.payment(coin, 0, @price, Keyword.put_new(opts, :time, now()))
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

  # Spends the crawler family's budget of 1.
  defp over_budget, do: assert(request("/about").status == 200)

  defp node_takes_it, do: RpcStub.stub_sendrawtransaction(String.duplicate("ab", 32))

  defp paid_request(path, paid, ip \\ "57.141.0.1") do
    {conn, _log} = with_log(fn -> request(path, paid.headers, ip) end)
    conn
  end

  describe "the 402" do
    test "carries no BSV terms while it's off" do
      enable(false)
      over_budget()

      conn = request("/api/v1/blocks/latest")

      assert conn.status == 402
      assert get_resp_header(conn, "x-bsv-sats") == []
      assert get_resp_header(conn, "x-bsv-server") == []
      refute Map.has_key?(json_response(conn, 402)["ways_in"], "pay_in_bsv")
    end

    test "carries no BSV terms while it's on but missing its price" do
      Application.put_env(:bitblocks, Bsv402,
        enabled: true,
        price_sats: nil,
        identity_key_env: @env
      )

      over_budget()

      assert get_resp_header(request("/about"), "x-bsv-sats") == []
    end

    test "carries BRC-121's terms, our price and our identity key, when on" do
      over_budget()
      conn = request("/about", [{"accept", "text/html"}])

      assert conn.status == 402
      assert get_resp_header(conn, "x-bsv-sats") == [Integer.to_string(@price)]
      assert get_resp_header(conn, "x-bsv-server") == [server_key()]
      assert get_resp_header(conn, "payment-required") == []
      assert html_response(conn, 402) =~ ~s(id="way-bsv")
    end

    test "says how to pay in its JSON, beside the key and the plans" do
      over_budget()
      body = json_response(request("/api/v1/blocks/latest"), 402)

      assert %{"protocol" => "BRC-121", "headers" => headers} = body["ways_in"]["pay_in_bsv"]
      assert headers == ~w(x-bsv-beef x-bsv-sender x-bsv-nonce x-bsv-time x-bsv-vout)
    end

    test "offers x402's USDC alongside, when that's on too" do
      Application.put_env(:bitblocks, X402Pay,
        enabled: true,
        network: "eip155:84532",
        pay_to: "0x000000000000000000000000000000000000dEaD",
        price_atomic: 10_000,
        paid_per_ip_per_minute: 30,
        paid_site_per_minute: 600
      )

      over_budget()
      conn = request("/about")

      assert [_offer] = get_resp_header(conn, "payment-required")
      assert get_resp_header(conn, "x-bsv-sats") == [Integer.to_string(@price)]
    end

    test "a route the free budget doesn't open is never offered" do
      over_budget()
      conn = request("/api/v1/ops/sync")

      assert get_resp_header(conn, "x-bsv-sats") == []
    end
  end

  describe "a paid retry" do
    test "is served once, with what was paid, and metered under the payer's key" do
      over_budget()
      node_takes_it()
      paid = payment()

      conn = paid_request("/about", paid)

      assert conn.status == 200
      assert get_resp_header(conn, "x-bsv-payment-satoshis-paid") == [Integer.to_string(@price)]
      assert get_resp_header(conn, "x-bsv-txid") == [paid.txid]
      sender = Base.encode16(F.sender_public(), case: :lower)
      assert Bitblocks.Usage.caller(conn) == {"bsv", sender}

      assert [hex] = RpcStub.calls(:sendrawtransaction) |> Enum.map(&hd/1)
      assert hex == Base.encode16(paid.payment, case: :lower)

      row = Repo.get_by!(BsvPayment, txid: paid.txid)
      assert row.status == "accepted"
      assert row.satoshis == @price
      assert row.request_hash == Bsv402.request_hash("GET", "/about", "")
    end

    test "is served even though the anonymous site budget is spent" do
      Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter,
        max_requests: 100,
        anonymous_site_max_requests: 1
      )

      browser = fn headers ->
        build_conn()
        |> put_req_header("x-forwarded-for", "203.0.113.9")
        |> then(fn conn ->
          Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
        end)
        |> get("/about")
      end

      assert browser.([]).status == 200
      {refused, _} = with_log(fn -> browser.([]) end)
      assert refused.status == 402
      assert get_resp_header(refused, "x-bsv-sats") == [Integer.to_string(@price)]

      node_takes_it()
      {conn, _} = with_log(fn -> browser.(payment().headers) end)
      assert conn.status == 200
    end

    test "its replay for another request is refused; the same request again is served, not charged twice" do
      over_budget()
      node_takes_it()
      paid = payment()

      assert paid_request("/about", paid).status == 200

      replay = paid_request("/api/v1/blocks/latest", paid)
      assert replay.status == 402
      assert get_resp_header(replay, "x-bsv-refused") == ["replayed"]
      assert get_resp_header(replay, "x-bsv-sats") == [Integer.to_string(@price)]
      assert json_response(replay, 402)["payment_refused"]["reason"] == "replayed"

      again = paid_request("/about", paid)
      assert again.status == 200
      assert get_resp_header(again, "x-bsv-txid") == [paid.txid]

      assert Repo.aggregate(BsvPayment, :count) == 1
      assert length(RpcStub.calls(:sendrawtransaction)) == 1
    end

    test "already known to our node is taken" do
      over_budget()

      RpcStub.stub_sendrawtransaction(
        {:error, %{"code" => -26, "message" => "257: txn-already-known"}}
      )

      assert paid_request("/about", payment()).status == 200
    end
  end

  describe "a payment refused" do
    setup do
      over_budget()
      node_takes_it()
      :ok
    end

    defp refused(paid, path) do
      conn = paid_request(path, paid)
      assert conn.status == 402
      assert get_resp_header(conn, "x-bsv-sats") == [Integer.to_string(@price)]
      assert get_resp_header(conn, "x-bsv-server") == [server_key()]
      assert Repo.aggregate(BsvPayment, :count) == 0
      [reason] = get_resp_header(conn, "x-bsv-refused")
      reason
    end

    test "underpaid" do
      assert refused(payment(sats: @price - 1), "/about") == "underpaid"
    end

    test "to an output that isn't ours" do
      assert refused(payment(pay_to: F.other_server_public()), "/about") == "not_our_output"
    end

    test "an unproven BEEF: the coin's root isn't block 0's" do
      assert refused(payment(coin: F.coin("not in block 0")), "/about") == "unproven"
    end

    test "an unknown block: a BUMP at a height we hold no header for" do
      assert refused(payment(bump_height: 7), "/about") == "unknown_block"
    end

    test "stale" do
      old = Integer.to_string(System.system_time(:millisecond) - 31_000)
      assert refused(payment(time: old), "/about") == "stale"
    end

    test "refused by our node, as a double spend: nothing kept, and the reason in the body" do
      RpcStub.stub_sendrawtransaction(
        {:error, %{"code" => -26, "message" => "258: txn-mempool-conflict"}}
      )

      conn = paid_request("/api/v1/blocks/latest", payment())
      assert conn.status == 402
      assert get_resp_header(conn, "x-bsv-refused") == ["broadcast_rejected"]
      assert json_response(conn, 402)["payment_refused"]["reason"] == "broadcast_rejected"
      assert Repo.aggregate(BsvPayment, :count) == 0
    end

    test "our node unreachable: a 503, nothing served and nothing taken" do
      RpcStub.stub_sendrawtransaction({:error, {:connection_error, :econnrefused}})

      conn = paid_request("/about", payment())
      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["5"]
      assert get_resp_header(conn, "x-bsv-refused") == ["broadcast_unavailable"]
      assert Repo.aggregate(BsvPayment, :count) == 0
    end

    test "too large for a header: a 413" do
      huge =
        F.coin("huge", [
          {0, <<0x00, 0x6A, 0x4D, 12_000::little-16>> <> :binary.copy(<<0>>, 12_000)}
        ])

      conn = paid_request("/about", payment(coin: huge))
      assert conn.status == 413
      assert get_resp_header(conn, "x-bsv-refused") == ["too_large"]
    end
  end

  describe "paid attempts" do
    test "share x402's per-IP cap, checked before the payment is read" do
      Application.put_env(:bitblocks, X402Pay,
        enabled: false,
        paid_per_ip_per_minute: 1,
        paid_site_per_minute: 600
      )

      over_budget()
      node_takes_it()

      assert paid_request("/about", payment(sats: @price - 1)).status == 402

      conn = paid_request("/about", payment())
      assert conn.status == 429
      assert [_] = get_resp_header(conn, "retry-after")
      assert RpcStub.calls(:sendrawtransaction) == []
    end
  end

  describe "the vectors" do
    test "are published, open, at /interop/bsv402/v0.json" do
      conn = get(build_conn(), "/interop/bsv402/v0.json")

      assert json_response(conn, 200)["version"] == "bsv402/v0"
      assert [_etag] = get_resp_header(conn, "etag")
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end

  describe "/pricing#crawlers" do
    test "says how to pay in BSV, at our price and to our key, while it's on" do
      {:ok, view, _html} = live(build_conn(), "/pricing")

      assert has_element?(view, "#crawlers-bsv-heading", "Paying in BSV")
      assert has_element?(view, "#crawlers-bsv-price", "#{@price} satoshis")
      assert has_element?(view, "#crawlers-bsv-server", server_key())
      assert has_element?(view, "#crawlers-way-bsv")
    end

    test "says nothing of BSV while it's off" do
      enable(false)
      {:ok, view, _html} = live(build_conn(), "/pricing")

      refute has_element?(view, "#crawlers-bsv")
      refute has_element?(view, "#crawlers-way-bsv")
    end
  end
end
