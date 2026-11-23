defmodule BitblocksWeb.Plugs.RateLimiter.AnonymousSiteTest do
  @moduledoc """
  Every caller with no key and no session shares one site-wide budget,
  whatever its IP or user agent, and past it gets the 402 a crawler gets: a
  doorway to a key, never a wall in front of the way in.
  """
  # async: false: the limiter's ETS table and config are global.
  use BitblocksWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Bitblocks.Accounts.User
  alias Bitblocks.ApiKeys
  alias Bitblocks.Repo
  alias BitblocksWeb.Plugs.RateLimiter

  @browser_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
  @meta_ua "Mozilla/5.0 (compatible; meta-externalagent/1.1; +https://developers.facebook.com/docs/sharing/webmasters/crawler)"

  setup do
    :ets.delete_all_objects(:rate_limiter)
    previous = Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter)
    put_limits(max_requests: 100, anonymous_site_max_requests: 3)
    on_exit(fn -> Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, previous) end)
  end

  defp put_limits(limits),
    do: Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, limits)

  # A distributed crawl: a new address for every request.
  defp ip(n), do: "198.51.#{div(n, 256)}.#{rem(n, 256)}"

  defp request(path, ip, opts \\ []) do
    conn =
      build_conn()
      |> put_req_header("user-agent", Keyword.get(opts, :ua, @browser_ua))
      |> put_req_header("x-forwarded-for", ip)

    conn =
      Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {k, v}, c ->
        put_req_header(c, k, v)
      end)

    conn =
      case Keyword.get(opts, :user_id) do
        nil -> conn
        id -> init_test_session(conn, %{"user_id" => id})
      end

    {conn, _log} =
      with_log(fn -> dispatch(conn, @endpoint, Keyword.get(opts, :method, :get), path) end)

    conn
  end

  defp spend(n \\ 3), do: for(i <- 1..n, do: assert(request("/about", ip(i)).status == 200))

  defp user! do
    id = System.unique_integer([:positive])
    Repo.insert!(%User{github_id: id, login: "user#{id}"})
  end

  describe "one budget for everyone without a key" do
    test "requests from many addresses share it, and past it get a 402" do
      spend()

      over = request("/about", ip(99))
      assert over.status == 402
      assert [retry_after] = get_resp_header(over, "retry-after")
      assert String.to_integer(retry_after) in 1..60
      assert get_resp_header(over, "x-ratelimit-limit") == ["3"]
      assert get_resp_header(over, "x-ratelimit-remaining") == ["0"]
      assert RateLimiter.throttled_anonymous() == 1
    end

    test "named AI crawlers count against it too" do
      put_limits(max_requests: 100, ai_crawler_max_requests: 100, anonymous_site_max_requests: 2)

      assert request("/about", ip(1), ua: @meta_ua).status == 200
      assert request("/about", ip(2), ua: @meta_ua).status == 200
      assert request("/about", ip(3)).status == 402
      assert request("/about", ip(4), ua: @meta_ua).status == 402
    end

    test "the per-IP budget still guards one address on its own" do
      put_limits(max_requests: 2, anonymous_site_max_requests: 100)

      assert request("/about", ip(1)).status == 200
      assert request("/about", ip(1)).status == 200
      assert request("/about", ip(1)).status == 429
      assert request("/about", ip(2)).status == 200
    end

    test "0 turns it off" do
      put_limits(max_requests: 100, anonymous_site_max_requests: 0)

      statuses = for n <- 1..10, do: request("/about", ip(n)).status
      assert statuses == List.duplicate(200, 10)
    end

    test "is reported by telemetry" do
      ref = make_ref()
      pid = self()

      :telemetry.attach(
        "anonymous-site-#{inspect(ref)}",
        [:bitblocks, :anonymous, :throttled],
        fn _event, measurements, _meta, _ -> send(pid, {ref, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("anonymous-site-#{inspect(ref)}") end)

      spend()
      assert request("/about", ip(4)).status == 402
      assert_received {^ref, %{count: 1}}
    end
  end

  describe "never counted against it" do
    test "a signed-in user, whose requests leave it untouched" do
      user = user!()

      for n <- 1..5 do
        assert request("/about", ip(n), user_id: user.id).status == 200
      end

      spend()
      assert request("/about", ip(4)).status == 402
      assert request("/about", ip(4), user_id: user.id).status == 200
    end

    test "a key holder" do
      {:ok, _key, token} = ApiKeys.create("reader", 50)
      spend()

      for n <- 1..5 do
        conn = request("/api/v1/blocks", ip(n), headers: [{"authorization", "Bearer #{token}"}])
        assert conn.status == 200
      end
    end
  end

  describe "the doorway stays open past it" do
    test "pricing, sign-in, the key routes, start, status and webhooks are never refused" do
      spend()
      assert request("/about", ip(4)).status == 402

      for {method, path} <- [
            get: "/pricing",
            get: "/sign-in",
            get: "/auth/github",
            get: "/start",
            get: "/start/api",
            get: "/api/v1/status",
            get: "/api/v1/keys/challenge",
            post: "/api/v1/keys",
            post: "/webhooks/stripe"
          ] do
        conn = request(path, ip(10), method: method)
        refute conn.status == 402, "#{method} #{path} was refused"
      end
    end

    test "and doorway requests don't spend it" do
      for n <- 1..5, do: assert(request("/pricing", ip(n)).status == 200)
      spend()
    end
  end

  describe "the 402 is a doorway" do
    test "a browser gets a short page with the ways in, in order" do
      spend()

      conn = request("/blocks", ip(4), headers: [{"accept", "text/html,application/xhtml+xml"}])

      assert conn.status == 402
      assert ["text/html" <> _] = get_resp_header(conn, "content-type")
      body = conn.resp_body

      assert body =~ "Reading at scale takes a key"
      assert body =~ "Everyone reading Bitblocks without a key shares 3 requests a minute"
      assert body =~ ~s(href="/sign-in?return_to=%2Fblocks")
      assert body =~ ~s(href="/start")
      assert body =~ ~s(href="/pricing#crawlers")
      # x402 is off in tests, so no offer is described.
      refute body =~ ~s(id="way-x402")

      [sign_in, key, plans] =
        for id <- ~w(way-sign-in way-free-key way-plans) do
          {pos, _} = :binary.match(body, ~s(id="#{id}"))
          pos
        end

      assert sign_in < key and key < plans
    end

    test "the API gets the JSON a crawler gets, plus the ways in" do
      spend()

      conn = request("/api/v1/blocks", ip(4))
      assert conn.status == 402
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "anonymous_rate_limited"
      assert body["budget"] == "anonymous_site"
      assert body["crawler_family"] == nil
      assert body["limit_per_minute"] == 3
      assert body["paid_access"]["get_a_key"] == "https://bitblocks.app/pricing#crawlers"
      assert body["paid_access"]["header"] == "Authorization: Bearer bbk_…"

      ways = body["ways_in"]
      assert ways["sign_in"] =~ "/sign-in"
      assert ways["free_key"] =~ "/start"
      assert ways["key_challenge"] =~ "/api/v1/keys/challenge"
      assert ways["plans"] == "https://bitblocks.app/pricing#crawlers"

      assert ways["pay_per_request"] == %{
               "protocol" => "x402",
               "offered" => false,
               "header" => "PAYMENT-SIGNATURE",
               "about" => "https://x402.org"
             }
    end

    test "anything else gets the same ways in as plain text" do
      spend()

      conn = request("/about", ip(4))
      assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
      assert conn.resp_body =~ "Reading at scale takes a key."
      assert conn.resp_body =~ "1. Sign in with GitHub"
      assert conn.resp_body =~ "2. Get a free API key by signing a challenge"
      assert conn.resp_body =~ "3. Plans for heavy use: https://bitblocks.app/pricing#crawlers"
      refute conn.resp_body =~ "x402"
    end
  end

  describe "/pricing#crawlers, where every 402 links" do
    test "says reading at scale takes a key, gives the shared budget, and the ways in, in order" do
      {:ok, view, html} = live(build_conn(), "/pricing")

      assert has_element?(view, "#crawlers-heading", "Reading at scale takes a key")
      assert has_element?(view, "#crawlers-site-budget", "3")
      assert has_element?(view, "#crawlers-ip-budget", "100")
      assert has_element?(view, "#crawlers-way-sign-in a[href='/sign-in']", "Sign in with GitHub")
      assert has_element?(view, "#crawlers-way-free-key a[href='/start']", "Get a free key")
      assert has_element?(view, "#crawlers-way-plans", "Heavy use is paid")
      # x402 is off in tests.
      refute has_element?(view, "#crawlers-way-x402")

      positions =
        for id <- ~w(crawlers-way-sign-in crawlers-way-free-key crawlers-way-plans) do
          {pos, _} = :binary.match(html, ~s(id="#{id}"))
          pos
        end

      assert positions == Enum.sort(positions)
    end

    test "leaves the shared budget out while it is off" do
      put_limits(max_requests: 100, anonymous_site_max_requests: 0)
      {:ok, view, _html} = live(build_conn(), "/pricing")
      refute has_element?(view, "#crawlers-site-budget")
    end
  end
end
