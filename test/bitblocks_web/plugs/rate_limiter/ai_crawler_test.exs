defmodule BitblocksWeb.Plugs.RateLimiter.AiCrawlerTest do
  @moduledoc """
  AI crawlers share one budget per family across all their IPs, and past it
  get a 402 that points at paid access (#107).
  """
  # async: false — the limiter's ETS table and config are global.
  use BitblocksWeb.ConnCase, async: false

  alias Bitblocks.ApiKeys
  alias BitblocksWeb.Plugs.RateLimiter
  alias BitblocksWeb.Plugs.RateLimiter.AiCrawlers

  require Logger

  # As prod logs showed it on 2026-11-18.
  @meta_ua "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " <>
             "Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0 (compatible; meta-externalagent/1.1; " <>
             "+https://developers.facebook.com/docs/sharing/webmasters/crawler)"
  @gptbot_ua "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)"
  @oai_search_ua "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; OAI-SearchBot/1.0; +https://openai.com/searchbot"
  @chatgpt_user_ua "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot"
  @googlebot_ua "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
  @bingbot_ua "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm) Chrome/116.0.1938.76 Safari/537.36"
  @browser_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

  setup do
    case :ets.whereis(:rate_limiter) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:rate_limiter)
    end

    previous = Application.get_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter)

    Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter,
      max_requests: 100,
      ai_crawler_max_requests: 3
    )

    on_exit(fn -> Application.put_env(:bitblocks, BitblocksWeb.Plugs.RateLimiter, previous) end)
    :ok
  end

  defp request(path, ua, ip, headers \\ []) do
    build_conn()
    |> put_req_header("user-agent", ua)
    |> put_req_header("x-forwarded-for", ip)
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    end)
    |> get(path)
  end

  defp ip(n), do: "57.141.#{div(n, 256)}.#{rem(n, 256)}"

  describe "recognising crawlers" do
    test "names each family, and nothing else" do
      assert AiCrawlers.family(@meta_ua) == "meta"
      assert AiCrawlers.family(@gptbot_ua) == "openai"
      assert AiCrawlers.family(@oai_search_ua) == "openai"

      # A company's user-triggered fetcher is in its company's family.
      assert AiCrawlers.family(@chatgpt_user_ua) == "openai"
      assert AiCrawlers.family("Mozilla/5.0 (compatible; Claude-User/1.0)") == "anthropic"
      assert AiCrawlers.family("Mozilla/5.0 (compatible; Perplexity-User/1.0)") == "perplexity"
      assert AiCrawlers.family("meta-externalfetcher/1.1") == "meta"

      assert AiCrawlers.family(
               "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)"
             ) == "anthropic"

      assert AiCrawlers.family("CCBot/2.0 (https://commoncrawl.org/faq/)") == "common_crawl"

      assert AiCrawlers.family(
               "mozilla/5.0 (compatible; bytespider; spider-feedback@bytedance.com)"
             ) == "bytedance"

      for ua <- [@googlebot_ua, @bingbot_ua, @browser_ua, "facebookexternalhit/1.1", "", nil] do
        assert AiCrawlers.family(ua) == nil, "#{inspect(ua)} is not an AI crawler"
      end
    end

    test "covers the crawlers named in #107" do
      tokens = AiCrawlers.families() |> Enum.flat_map(fn {_, t} -> t end)

      for name <- ~w(meta-externalagent GPTBot ChatGPT-User OAI-SearchBot ClaudeBot anthropic-ai
                     CCBot Bytespider PerplexityBot Amazonbot Google-Extended Applebot-Extended
                     cohere-ai Diffbot) do
        assert name in tokens
        assert AiCrawlers.family("Mozilla/5.0 (compatible; #{name}/1.0)")
      end
    end
  end

  describe "over budget" do
    test "one family shares one budget across many IPs, then gets a 402 with the way in" do
      statuses = for n <- 1..3, do: request("/api/v1/blocks", @meta_ua, ip(n)).status
      assert statuses == [200, 200, 200]

      over = request("/api/v1/blocks", @meta_ua, ip(99))
      assert over.status == 402
      assert [retry_after] = get_resp_header(over, "retry-after")
      assert String.to_integer(retry_after) in 1..60
      assert get_resp_header(over, "x-ratelimit-limit") == ["3"]
      assert ["application/json" <> _] = get_resp_header(over, "content-type")

      body = Jason.decode!(over.resp_body)
      assert body["error"] == "ai_crawler_rate_limited"
      assert body["crawler_family"] == "meta"
      assert body["limit_per_minute"] == 3
      assert body["message"] =~ "rate-limited as an AI crawler"
      assert body["paid_access"]["get_a_key"] == "https://bitblocks.app/pricing#crawlers"
      assert body["paid_access"]["header"] == "Authorization: Bearer bbk_…"
      assert body["paid_access"]["contact"] == "mailto:" <> AiCrawlers.contact_email()
    end

    test "a page gets the same answer as plain text" do
      for n <- 1..3, do: assert(request("/about", @meta_ua, ip(n)).status == 200)

      over = request("/about", @meta_ua, ip(4))
      assert over.status == 402
      assert get_resp_header(over, "retry-after") != []
      assert ["text/plain" <> _] = get_resp_header(over, "content-type")
      assert over.resp_body =~ "rate-limited as an AI crawler (meta)"
      assert over.resp_body =~ "https://bitblocks.app/pricing#crawlers"
      assert over.resp_body =~ "Authorization: Bearer bbk_"
    end

    test "every bulk crawler of one company shares the budget, and another company has its own" do
      assert request("/about", @gptbot_ua, ip(1)).status == 200
      assert request("/about", @oai_search_ua, ip(2)).status == 200
      assert request("/about", @gptbot_ua, ip(3)).status == 200
      assert request("/about", @oai_search_ua, ip(4)).status == 402

      assert request("/about", @meta_ua, ip(5)).status == 200
    end

    test "a company's crawler and its user fetcher share one budget" do
      assert request("/about", @gptbot_ua, ip(1)).status == 200
      assert request("/about", @chatgpt_user_ua, ip(2)).status == 200
      assert request("/about", @gptbot_ua, ip(3)).status == 200

      over = request("/api/v1/blocks", @chatgpt_user_ua, ip(4))
      assert over.status == 402
      assert get_resp_header(over, "x-ratelimit-limit") == ["3"]
      assert Jason.decode!(over.resp_body)["crawler_family"] == "openai"
      assert RateLimiter.throttled_crawlers() == %{"openai" => 1}
    end

    test "is counted per family, logged below error, and reported by telemetry" do
      ref = make_ref()
      pid = self()

      :telemetry.attach(
        "ai-crawler-test-#{inspect(ref)}",
        [:bitblocks, :ai_crawler, :throttled],
        fn _event, measurements, metadata, _ -> send(pid, {ref, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("ai-crawler-test-#{inspect(ref)}") end)

      for n <- 1..3, do: request("/about", @meta_ua, ip(n))

      # The suite logs at :warning; the throttle line is :info.
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert request("/about", @meta_ua, ip(4)).status == 402
          assert request("/about", @meta_ua, ip(5)).status == 402
        end)

      assert log =~ "AI crawler throttled crawler:meta"
      refute log =~ "[error]"
      assert_received {^ref, %{count: 1}, %{family: "meta"}}
      assert RateLimiter.throttled_crawlers() == %{"meta" => 2}
    end
  end

  describe "not throttled as a crawler" do
    test "a crawler with a valid key has its key's budget" do
      {:ok, _key, token} = ApiKeys.create("crawler-co", 20)

      statuses =
        for n <- 1..10 do
          request("/api/v1/blocks", @meta_ua, ip(n), [{"authorization", "Bearer #{token}"}]).status
        end

      assert statuses == List.duplicate(200, 10)

      conn = request("/api/v1/blocks", @meta_ua, ip(11), [{"x-api-key", token}])
      assert conn.status == 200
      assert get_resp_header(conn, "x-ratelimit-limit") == ["20"]
      assert RateLimiter.throttled_crawlers() == %{}
    end

    test "a crawler with a bad key is refused within its family's budget" do
      for n <- 1..3 do
        assert request("/api/v1/blocks", @meta_ua, ip(n), [{"x-api-key", "bbk_nope"}]).status ==
                 401
      end

      assert request("/api/v1/blocks", @meta_ua, ip(4), [{"x-api-key", "bbk_nope"}]).status ==
               402
    end

    test "Googlebot, Bingbot and a browser keep the per-IP budget" do
      for ua <- [@googlebot_ua, @bingbot_ua, @browser_ua] do
        statuses = for _ <- 1..5, do: request("/about", ua, "66.249.66.1").status
        assert statuses == List.duplicate(200, 5), ua
      end

      assert RateLimiter.throttled_crawlers() == %{}
    end

    test "a crawler within its budget is still anonymous to the API gate" do
      Application.put_env(:bitblocks, :admin_auth, enabled: true)
      on_exit(fn -> Application.put_env(:bitblocks, :admin_auth, enabled: false) end)

      assert request("/api/v1/blocks", @meta_ua, ip(1)).status == 401
    end
  end
end
