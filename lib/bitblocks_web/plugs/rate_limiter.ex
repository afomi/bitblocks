defmodule BitblocksWeb.Plugs.RateLimiter do
  @moduledoc """
  Simple ETS-backed rate limiter: each caller gets a budget by who is asking.

  Tracks request counts in a sliding window. Returns 429 Too Many Requests
  when the limit is exceeded, with a Retry-After header.

  ## Configuration

      config :bitblocks, BitblocksWeb.Plugs.RateLimiter,
        window_ms: 60_000,            # 1 minute window
        max_requests: 30,             # logged out, per IP
        signed_in_max_requests: 600,  # logged in, per user
        admin_max_requests: 3_000,    # admin, per user
        ai_crawler_max_requests: 10,  # an AI crawler, per family
        ai_fetcher_max_requests: 30   # an AI user-triggered fetcher, per family

  Static assets bypass this plug.

  ## Who is asking

  A valid API key first, then the session's user, then the IP:

  | Caller | Counted by | Budget a minute |
  | --- | --- | --- |
  | API key | the key | its `requests_per_minute` |
  | Admin | the user | `RATE_LIMIT_ADMIN_PER_MINUTE`, 3,000 |
  | Logged in | the user | `RATE_LIMIT_SIGNED_IN_PER_MINUTE`, 600 |
  | Logged out | the IP | `RATE_LIMIT_PER_MINUTE`, 30 |
  | AI crawler, no key | its family | `RATE_LIMIT_AI_CRAWLER_PER_MINUTE`, 10 |
  | AI user-triggered fetcher, no key | its family | `RATE_LIMIT_AI_FETCHER_PER_MINUTE`, 30 |

  Counting by user means people behind one address don't share a budget. A
  session whose user is gone, or a forged cookie, which reads as no session,
  gets the IP's budget. Admin is `users.admin`.

  The tier is read once and cached (`:tier_cache_ms`, 60 s), so the limiter
  adds no query per request, and a grant or revoke reaches it within that time.

  This covers HTTP requests, including a LiveView's first render. Events over
  an open LiveView socket don't pass through the endpoint's plugs, so they
  aren't counted; a LiveView that needs a budget calls `allow?/2`.

  ## AI crawlers

  A caller with no key and no session whose user agent names an AI crawler
  (`RateLimiter.AiCrawlers`) is counted by its family, `crawler:<family>`, not
  its IP: one company's crawler shares one budget across all its addresses,
  replicated across the cluster like every other bucket. Over budget it gets a
  402 Payment Required with `Retry-After` and a short body (JSON under
  `/api/`, plain text elsewhere) naming the paid way in: a key, as
  `/pricing#crawlers` describes, sent as `Authorization: Bearer bbk_…`. A keyed
  request is never counted as a crawler; it has its key's budget.

  A company's user-triggered fetcher (`ChatGPT-User`, `Claude-User`, …; kind
  `:fetcher` in `AiCrawlers`) is a family of its own, `<company>_user`, with
  `RATE_LIMIT_AI_FETCHER_PER_MINUTE` (30), so a person asking an assistant to
  read one page isn't refused because that company's bulk crawler spent its
  budget. Over it, the same 402.

  402 rather than 429, because the way to more requests is to pay, not to
  wait; `Retry-After` still says when the free budget opens again. Each
  refusal is logged at info, emits `[:bitblocks, :ai_crawler, :throttled]`
  (`%{count: 1}`, `%{family: f}`), and adds to `throttled_crawlers/0`, this
  node's count since boot.

  Over budget, `/pricing`, `/contact` and `/terms` are still served
  (`AiCrawlers.always_open?/1`): they are where the 402 sends it.

  ## Paying with x402

  With `Bitblocks.Payments.X402` enabled, the same 402 also carries a
  `PAYMENT-REQUIRED` offer (the configured price in USDC, on the configured
  network, to our deposit address) for a route the crawler could read for
  free (`AiCrawlers.payable?/1`). A retry with a `PAYMENT-SIGNATURE` header:

    * first meets its own budgets, per IP and per family
      (`X402_PAID_PER_IP_PER_MINUTE`, `X402_PAID_PER_FAMILY_PER_MINUTE`),
      since each costs a facilitator call; over either, a 429;
    * paid: the request is served, with `PAYMENT-RESPONSE`, as the anonymous
      caller it is (telemetry `[:bitblocks, :ai_crawler, :paid]`);
    * refused (wrong amount, wrong payTo, a replay, a failed verify): the 402
      with a fresh offer;
    * facilitator or replay guard unavailable: a 503 with no content.

  A request with a bad key is never offered one; it gets its 401.

  ## API keys

  A request carrying `Authorization: Bearer bbk_…` or `x-api-key: bbk_…` is
  counted against that key's `requests_per_minute` instead of its IP (see
  `Bitblocks.ApiKeys`). An unknown or revoked key is a 401, never a silent
  fallback to the anonymous budget.

  ## Cluster awareness (T1/T12)

  The counter is node-local ETS. When the app runs as a cluster, each admitted
  request is broadcast to peers via `RateLimiter.Replicator`, so every node's
  sliding window reflects cluster-wide traffic and the cap isn't multiplied by
  the instance count. Eventually consistent; see the Replicator docs.
  """

  import Plug.Conn
  require Logger

  alias Bitblocks.Payments.X402, as: X402Pay
  alias BitblocksWeb.Plugs.RateLimiter.{AiCrawlers, Replicator}

  @table :rate_limiter
  @default_window_ms 60_000
  # Prod sets these from the environment (config/runtime.exs); keyed callers use
  # their key's own budget (Bitblocks.ApiKeys).
  @default_max_requests 30
  @default_signed_in_max_requests 600
  @default_admin_max_requests 3_000
  @default_tier_cache_ms 60_000
  @default_ai_crawler_max_requests 10
  @default_ai_fetcher_max_requests 30

  def init(opts), do: opts

  def call(conn, _opts) do
    ensure_table()

    ip = BitblocksWeb.Utils.IpHelper.get_ip_address(conn)
    now = System.system_time(:millisecond)
    window_ms = config(:window_ms, @default_window_ms)
    anonymous = config(:max_requests, @default_max_requests)

    case api_token(conn) do
      nil ->
        {conn, user_id} = session_user_id(conn)

        {bucket, max_requests, tier} = budget(conn, user_id, ip, now, anonymous)
        limit(conn, bucket, now, window_ms, max_requests, tier)

      token ->
        case Bitblocks.ApiKeys.verify(token) do
          # A keyed caller has its own budget, whatever its IP (qart's server
          # serves many visitors from one address).
          %{id: id, requests_per_minute: rpm} = key ->
            conn
            |> assign(:api_key, key)
            |> limit("key:#{id}", now, window_ms, rpm, :api_key)

          # A bad key is refused loudly rather than treated as anonymous, but
          # only within the IP's budget (a crawler's, its family's), so random
          # keys can't hammer the DB.
          nil ->
            {bucket, max_requests, tier} = anonymous_budget(conn, ip, anonymous)
            # Answered 401 below, so never offered a payment it couldn't use.
            conn = put_private(conn, :rate_limiter_bad_key, true)

            case limit(conn, bucket, now, window_ms, max_requests, tier) do
              %Plug.Conn{halted: true} = halted ->
                halted

              conn ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(401, Jason.encode!(%{error: "Invalid API key (unknown or revoked)"}))
                |> halt()
            end
        end
    end
  end

  # `Authorization: Bearer bbk_…` or `x-api-key: bbk_…`.
  defp api_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        String.trim(token)

      _ ->
        case get_req_header(conn, "x-api-key") do
          [token | _] when token != "" -> String.trim(token)
          _ -> nil
        end
    end
  end

  defp budget(conn, user_id, ip, now, anonymous) do
    case tier(user_id, now) do
      :admin ->
        {"user:#{user_id}", config(:admin_max_requests, @default_admin_max_requests), :admin}

      :signed_in ->
        max_requests = config(:signed_in_max_requests, @default_signed_in_max_requests)
        {"user:#{user_id}", max_requests, :signed_in}

      :anonymous ->
        anonymous_budget(conn, ip, anonymous)
    end
  end

  # No key and no session: an AI crawler's family shares one budget across
  # its addresses; anyone else has the IP's.
  defp anonymous_budget(conn, ip, anonymous) do
    case conn |> get_req_header("user-agent") |> List.first() |> AiCrawlers.family() do
      nil ->
        {ip, anonymous, :anonymous}

      family ->
        {"crawler:#{family}", crawler_budget(AiCrawlers.kind(family)), {:ai_crawler, family}}
    end
  end

  # The session's user id, once the endpoint's Plug.Session has run. A signed
  # cookie that doesn't verify reads as an empty session.
  defp session_user_id(%Plug.Conn{private: %{plug_session_fetch: _}} = conn) do
    conn = fetch_session(conn)
    {conn, get_session(conn, "user_id")}
  end

  defp session_user_id(conn), do: {conn, nil}

  defp tier(nil, _now), do: :anonymous

  # Misses are cached too: the id comes from a signed session, so only we can
  # name one, and a deleted user shouldn't cost a query per request.
  defp tier(user_id, now) do
    case :ets.lookup(@table, {:tier, user_id}) do
      [{_, tier, expires}] when expires > now ->
        tier

      _ ->
        tier = read_tier(user_id)
        expires = now + config(:tier_cache_ms, @default_tier_cache_ms)
        :ets.insert(@table, {{:tier, user_id}, tier, expires})
        tier
    end
  rescue
    # The database is unreachable: the IP's budget, never a higher one.
    DBConnection.ConnectionError -> :anonymous
  end

  defp read_tier(user_id) do
    case Bitblocks.Accounts.get_user(user_id) do
      %{admin: true} -> :admin
      %{} -> :signed_in
      nil -> :anonymous
    end
  end

  defp limit(conn, bucket, now, window_ms, max_requests, tier) do
    case check_rate(bucket, now, window_ms, max_requests) do
      {:ok, count} ->
        conn
        |> assign_tier(tier)
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(max_requests))
        |> put_resp_header(
          "x-ratelimit-remaining",
          Integer.to_string(max(0, max_requests - count))
        )

      {:error, retry_after_ms} ->
        retry_after_s = max(1, div(retry_after_ms, 1000))
        refuse(conn, bucket, tier, max_requests, retry_after_s)
    end
  end

  # A person's one request through an assistant gets more room than a bulk
  # crawl, in a bucket of its own.
  defp crawler_budget(:fetcher),
    do: config(:ai_fetcher_max_requests, @default_ai_fetcher_max_requests)

  defp crawler_budget(_crawler),
    do: config(:ai_crawler_max_requests, @default_ai_crawler_max_requests)

  # A crawler within its budget is still an anonymous caller to the routes
  # (RequireCaller reads :caller_tier).
  defp assign_tier(conn, {:ai_crawler, family}) do
    conn
    |> assign(:caller_tier, :anonymous)
    |> assign(:ai_crawler, family)
  end

  defp assign_tier(conn, tier), do: assign(conn, :caller_tier, tier)

  # A crawler over its budget: the pages that tell it how to pay stay open;
  # with x402 on, a route it could read for free is offered for sale, and a
  # payment for it is taken; otherwise the plain 402.
  defp refuse(conn, bucket, {:ai_crawler, family} = tier, max_requests, retry_after_s) do
    cond do
      AiCrawlers.always_open?(conn) ->
        conn
        |> assign_tier(tier)
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(max_requests))
        |> put_resp_header("x-ratelimit-remaining", "0")

      X402Pay.enabled?() and not Map.has_key?(conn.private, :rate_limiter_bad_key) and
          AiCrawlers.payable?(conn) ->
        case get_req_header(conn, X402.payment_header()) do
          [] ->
            conn
            |> X402.put_challenge(X402Pay.challenge(conn))
            |> crawler_402(bucket, family, max_requests, retry_after_s)

          _header ->
            pay(conn, bucket, tier, max_requests, retry_after_s)
        end

      true ->
        crawler_402(conn, bucket, family, max_requests, retry_after_s)
    end
  end

  defp refuse(conn, bucket, tier, max_requests, retry_after_s) do
    Logger.warning("Rate limited #{bucket} tier=#{tier} limit=#{max_requests}")

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(max_requests))
    |> put_resp_header("x-ratelimit-remaining", "0")
    |> send_resp(429, "Too Many Requests. Retry after #{retry_after_s} seconds.")
    |> halt()
  end

  # A crawler's paid retry. Each well-formed payment header costs a
  # facilitator /verify call, so paid attempts have budgets of their own, per
  # IP and per family, checked before x402_ex sees the header.
  defp pay(conn, bucket, {:ai_crawler, family} = tier, max_requests, retry_after_s) do
    ip = BitblocksWeb.Utils.IpHelper.get_ip_address(conn)
    now = System.system_time(:millisecond)
    window_ms = config(:window_ms, @default_window_ms)

    with {:ok, _} <- check_rate("x402:ip:#{ip}", now, window_ms, X402Pay.paid_per_ip_per_minute()),
         {:ok, _} <-
           check_rate("x402:#{bucket}", now, window_ms, X402Pay.paid_per_family_per_minute()) do
      case X402Pay.handle(conn) do
        {:ok, conn, _settlement} ->
          record_paid(family)
          Logger.info("AI crawler paid #{bucket} path=#{conn.request_path} ip=#{ip}")

          conn
          |> assign_tier(tier)
          |> assign(:x402_paid, true)

        {:payment_required, challenge} ->
          conn
          |> X402.put_challenge(challenge)
          |> crawler_402(bucket, family, max_requests, retry_after_s)

        {:payment_required, challenge, reason} ->
          Logger.info("AI crawler payment refused #{bucket} reason=#{reason} ip=#{ip}")

          conn
          |> X402.put_challenge(challenge)
          |> crawler_402(bucket, family, max_requests, retry_after_s)

        # The facilitator or our guard is unavailable: nothing is served. A
        # 503 after x402_ex's settle wait may still have been paid; it records
        # the settlement when it lands (the reconciler books it), and the
        # same header retried is refused as replayed, so no one pays twice.
        {:error, reason} ->
          Logger.warning("AI crawler payment unavailable #{bucket} reason=#{reason}")

          conn
          |> send_resp(503, "")
          |> halt()
      end
    else
      {:error, retry_after_ms} ->
        retry_s = max(1, div(retry_after_ms, 1000))
        Logger.info("AI crawler paid attempts limited #{bucket} ip=#{ip}")

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_s))
        |> send_resp(429, "Too many payment attempts. Retry after #{retry_s} seconds.")
        |> halt()
    end
  end

  defp crawler_402(conn, bucket, family, max_requests, retry_after_s) do
    record_throttle(family)

    Logger.info(
      "AI crawler throttled #{bucket} limit=#{max_requests} path=#{conn.request_path} " <>
        "ip=#{BitblocksWeb.Utils.IpHelper.get_ip_address(conn)}"
    )

    {content_type, body} = crawler_body(conn, family, max_requests, retry_after_s)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(max_requests))
    |> put_resp_header("x-ratelimit-remaining", "0")
    |> put_resp_content_type(content_type)
    |> send_resp(402, body)
    |> halt()
  end

  # JSON for the API, a few lines of plain text for everything else.
  defp crawler_body(%Plug.Conn{path_info: ["api" | _]}, family, max_requests, retry_after_s) do
    {"application/json",
     Jason.encode!(%{
       error: "ai_crawler_rate_limited",
       message:
         "You are rate-limited as an AI crawler (#{family}): #{max_requests} requests a minute, " <>
           "shared by every address your crawler uses.",
       crawler_family: family,
       limit_per_minute: max_requests,
       retry_after_seconds: retry_after_s,
       paid_access: %{
         message:
           "Paid access with an API key gets its own budget, and is never throttled as a crawler.",
         get_a_key: AiCrawlers.page_url(),
         contact: "mailto:" <> AiCrawlers.contact_email(),
         header: "Authorization: Bearer bbk_…"
       }
     })}
  end

  defp crawler_body(_conn, family, max_requests, retry_after_s) do
    {"text/plain",
     """
     402 Payment Required

     You are rate-limited as an AI crawler (#{family}): #{max_requests} requests a minute, shared by every address your crawler uses.
     The free budget opens again in #{retry_after_s} seconds.

     Paid access with an API key gets its own budget, and is never throttled as a crawler.
     How to get a key: #{AiCrawlers.page_url()}
     Contact: #{AiCrawlers.contact_email()}
     Send it as: Authorization: Bearer bbk_…

     robots.txt disallows /transactions, /blocks and /api/ for every crawler; the API is the way to the chain.
     """}
  end

  defp record_throttle(family) do
    key = {:crawler_throttled, family}
    :ets.update_counter(@table, key, 1, {key, 0})
    :telemetry.execute([:bitblocks, :ai_crawler, :throttled], %{count: 1}, %{family: family})
  end

  defp record_paid(family) do
    :telemetry.execute([:bitblocks, :ai_crawler, :paid], %{count: 1}, %{family: family})
  end

  @doc """
  AI crawler requests refused on this node since it started, by family, as
  `%{"meta" => 28_412}`. Empty until one is refused.
  """
  @spec throttled_crawlers() :: %{String.t() => non_neg_integer()}
  def throttled_crawlers do
    ensure_table()

    @table
    |> :ets.match({{:crawler_throttled, :"$1"}, :"$2"})
    |> Map.new(fn [family, count] -> {family, count} end)
  end

  defp check_rate(ip, now, window_ms, max_requests) do
    window_start = now - window_ms

    case :ets.lookup(@table, ip) do
      [{^ip, timestamps}] ->
        # Drop timestamps outside the window
        recent = Enum.filter(timestamps, &(&1 > window_start))
        count = length(recent) + 1

        if count > max_requests do
          # Oldest request in window determines when the window opens up
          oldest = Enum.min(recent)
          retry_after = oldest + window_ms - now
          {:error, retry_after}
        else
          :ets.insert(@table, {ip, [now | recent]})
          replicate(ip, now, max_requests)
          {:ok, count}
        end

      [] ->
        :ets.insert(@table, {ip, [now]})
        replicate(ip, now, max_requests)
        {:ok, 1}
    end
  end

  @doc """
  Counts one use of `bucket` against `max_requests` in the window, for work
  that doesn't pass through this plug, such as a LiveView event. True when
  it's within the budget.
  """
  def allow?(bucket, max_requests) do
    ensure_table()
    now = System.system_time(:millisecond)

    match?(
      {:ok, _},
      check_rate(bucket, now, config(:window_ms, @default_window_ms), max_requests)
    )
  end

  # Tell peer nodes about this admitted request so the cap is cluster-wide.
  # Best-effort and only when the replicator is running (no-op single-node/test).
  defp replicate(bucket, now, limit) do
    if Process.whereis(Replicator), do: Replicator.record(bucket, now, limit)
    :ok
  end

  @doc """
  Creates the counters table. Called from `Bitblocks.Application.start/2` so a
  long-lived process owns it; an ETS table dies with its owner.
  """
  def create_table, do: ensure_table()

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        # Two callers can race between whereis/new; the loser's :ets.new raises
        # "table already exists". Treat that as success — the table is there.
        try do
          :ets.new(@table, [:set, :public, :named_table])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp config(key, default) do
    Application.get_env(:bitblocks, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
