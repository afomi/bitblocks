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
        ai_crawler_max_requests: 10,  # an AI company's crawlers and fetchers, per family
        anonymous_site_max_requests: 300 # no key, no session: everyone, site-wide

  Static assets bypass this plug.

  ## Who is asking

  A valid API key first, then the session's user, then the IP:

  | Caller | Counted by | Budget a minute |
  | --- | --- | --- |
  | API key | the key | its `requests_per_minute` |
  | Admin | the user | `RATE_LIMIT_ADMIN_PER_MINUTE`, 3,000 |
  | Logged in | the user | `RATE_LIMIT_SIGNED_IN_PER_MINUTE`, 600 |
  | Logged out | the IP | `RATE_LIMIT_PER_MINUTE`, 30 |
  | AI crawler or fetcher, no key | its company's family | `RATE_LIMIT_AI_CRAWLER_PER_MINUTE`, 10 |
  | Every caller with no key and no session, together | the site | `RATE_LIMIT_ANONYMOUS_SITE_PER_MINUTE`, 300 |

  The last row runs alongside the others: a logged-out request, crawler or
  not, meets its own bucket (the IP's, or its family's) and then the shared
  one (see "The shared anonymous budget" below).

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

  A company's user-triggered fetcher (`ChatGPT-User`, `Claude-User`, …) is in
  the same family as its crawlers and shares their one budget. A person's one
  question through an assistant is protected by the shared anonymous budget
  (the room it leaves) and by the free key at `/start`, which the assistant's
  company, or the person, can take; not by a bucket of its own.
  `RATE_LIMIT_AI_FETCHER_PER_MINUTE` is deprecated: read only when
  `RATE_LIMIT_AI_CRAWLER_PER_MINUTE` is unset (`config/runtime.exs`), and safe
  to drop from the secret.

  402 rather than 429, because the way to more requests is a key or a
  payment, not waiting; `Retry-After` still says when the free budget opens
  again. Each refusal is logged at info, emits
  `[:bitblocks, :ai_crawler, :throttled]` (`%{count: 1}`, `%{family: f}`), and
  adds to `throttled_crawlers/0`, this node's count since boot.

  ## The shared anonymous budget

  A distributed crawl with ordinary browser user agents, a couple of requests
  from each of 135k addresses, never meets a per-IP or per-family budget. So
  everyone with no key and no session also shares one site-wide bucket,
  `anonymous:site` (`RATE_LIMIT_ANONYMOUS_SITE_PER_MINUTE`, default 300, about
  four times the normal human peak of 80 a minute; 0 turns it off). It is
  checked after the caller's own bucket, so the per-IP budget stays the guard
  against one address, and past it the answer is the same 402 a crawler gets,
  x402 offer included. Signed-in users and key holders are never counted
  against it. Refusals emit `[:bitblocks, :anonymous, :throttled]` and add to
  `throttled_anonymous/0`.

  The count is the same ETS sliding window as every other bucket: under a
  burst, concurrent requests can each read the window before the others
  write, so it may admit somewhat more than its budget. The pool guard and the
  WAF sit behind it; it needn't be exact to put a key in front of scale.

  ## The doorway

  The 402 is a doorway, not a wall (`BitblocksWeb.PaymentRequiredHTML`): JSON
  under `/api/`, a short page for a browser, plain text otherwise, each giving
  the ways in, in order: sign in with GitHub, a free key by signing a
  challenge (`/start`), plans (`/pricing#crawlers`), and for agents, paying
  for the request with x402 when that's on.

  Past a shared budget, the doorway pages are still served (`always_open?/1`):
  `/pricing`, `/contact`, `/terms`, `/sign-in`, `/auth/*`, `/start*`,
  `/api/v1/status*`, `/api/v1/keys*` and `/webhooks/*`. They don't spend the
  shared anonymous budget; a crawler family's still counts them.

  ## Paying with x402

  With `Bitblocks.Payments.X402` enabled, the same 402 (a crawler family's,
  or the shared anonymous budget's) also carries a `PAYMENT-REQUIRED` offer
  (the configured price in USDC, on the configured network, to our deposit
  address) for a route the caller could read for free
  (`AiCrawlers.payable?/1`). A retry with a `PAYMENT-SIGNATURE` header:

    * first meets two paid-attempt caps, since each attempt costs a
      facilitator call: one per IP (`X402_PAID_PER_IP_PER_MINUTE`) and one
      site-wide (`X402_PAID_SITE_PER_MINUTE`), shared with BSV payments
      (below); over either, a 429
      (`X402_PAID_PER_FAMILY_PER_MINUTE` is deprecated, read only when
      `X402_PAID_SITE_PER_MINUTE` is unset);
    * paid: the request is served, with `PAYMENT-RESPONSE`, as the anonymous
      caller it is (telemetry `[:bitblocks, :ai_crawler, :paid]`, or
      `[:bitblocks, :anonymous, :paid]`);
    * refused (wrong amount, wrong payTo, a replay, a failed verify): the 402
      with a fresh offer;
    * facilitator or replay guard unavailable: a 503 with no content.

  A request with a bad key is never offered one; it gets its 401.

  ## Paying in BSV

  With `Bitblocks.Payments.Bsv402` enabled (`BSV402_ENABLED`, with its key
  and price), the same 402 also carries BRC-121's terms, `x-bsv-sats` and
  `x-bsv-server`, for a route the caller could read for free, beside the
  x402 offer when that's on. A retry with `x-bsv-beef` (and the other four
  `x-bsv-*` headers):

    * meets the same two paid-attempt caps as x402, per IP and site-wide;
    * paid: served as the anonymous caller it is, with
      `x-bsv-payment-satoshis-paid` and `x-bsv-txid`, metered under
      `bsv:<sender key>` (`Bitblocks.Usage.caller/1`), telemetry
      `[:bitblocks, :bsv402, :paid]`; the same payment for the same request
      inside its 30 seconds is served again, not charged twice;
    * refused (underpaid, not our output, stale, unproven, replayed, our
      node refused it, a sender denied after a dropped or conflicted payment): the 402 again with the terms, and `x-bsv-refused`
      naming the reason;
    * too large: a 413; our node or database unavailable: a 503 with
      `Retry-After`, nothing served and nothing taken.

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

  alias Bitblocks.Payments.Bsv402
  alias Bitblocks.Payments.X402, as: X402Pay
  alias BitblocksWeb.PaymentRequiredHTML
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
  # Everyone with no key and no session, together. Normal human peaks were
  # about 80 a minute (400 in 5 minutes), so this leaves room for a busy hour.
  @default_anonymous_site_max_requests 300
  @site_bucket "anonymous:site"

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

        # Who to meter the request under (Bitblocks.Usage), with no query.
        conn =
          if tier in [:admin, :signed_in], do: assign(conn, :caller_user_id, user_id), else: conn

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

  # No key and no session: an AI company's crawlers and fetchers share one
  # budget across their addresses; anyone else has the IP's.
  defp anonymous_budget(conn, ip, anonymous) do
    case conn |> get_req_header("user-agent") |> List.first() |> AiCrawlers.family() do
      nil ->
        {ip, anonymous, :anonymous}

      family ->
        max_requests = config(:ai_crawler_max_requests, @default_ai_crawler_max_requests)
        {"crawler:#{family}", max_requests, {:ai_crawler, family}}
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
        |> shared_budget(tier, now, window_ms)

      {:error, retry_after_ms} ->
        refuse(conn, bucket, tier, max_requests, retry_seconds(retry_after_ms))
    end
  end

  defp retry_seconds(ms), do: max(1, div(ms, 1000))

  # Everyone with no key and no session, crawler or not, whatever the IP, also
  # shares one site-wide budget. A request within its own bucket (the IP's, or
  # its crawler family's) is counted here too, and past this budget gets the
  # same 402 a crawler does. The doorway pages are outside it, and a bad key
  # is answered 401 whatever this says.
  defp shared_budget(conn, tier, now, window_ms) when tier == :anonymous or is_tuple(tier) do
    max_requests = anonymous_site_max_requests()

    cond do
      max_requests in [nil, 0] ->
        conn

      Map.has_key?(conn.private, :rate_limiter_bad_key) or always_open?(conn) ->
        conn

      true ->
        case check_rate(@site_bucket, now, window_ms, max_requests) do
          {:ok, _count} ->
            conn

          {:error, retry_after_ms} ->
            refuse(
              conn,
              @site_bucket,
              :anonymous_site,
              max_requests,
              retry_seconds(retry_after_ms)
            )
        end
    end
  end

  defp shared_budget(conn, _tier, _now, _window_ms), do: conn

  @doc """
  Requests a minute that every caller with no key and no session shares,
  site-wide (`RATE_LIMIT_ANONYMOUS_SITE_PER_MINUTE`); 0 or nil turns it off.
  """
  @spec anonymous_site_max_requests() :: non_neg_integer() | nil
  def anonymous_site_max_requests,
    do: config(:anonymous_site_max_requests, @default_anonymous_site_max_requests)

  # The doorway: the pages that say how to get a key, sign in, take one or pay
  # for one, and the status and webhook routes other systems depend on. Never
  # refused by a shared budget (a crawler family's, or the anonymous site's);
  # still counted against a crawler family's, and against the IP's.
  @doorway [
    ["pricing"],
    ["contact"],
    ["terms"],
    ["sign-in"],
    ["auth"],
    ["start"],
    ["api", "v1", "status"],
    ["api", "v1", "keys"],
    ["webhooks"]
  ]

  @doc """
  True for a doorway page, never refused by a shared budget: `/pricing`,
  `/contact`, `/terms`, `/sign-in`, `/auth/*`, `/start*`, `/api/v1/status*`,
  `/api/v1/keys*` and `/webhooks/*`.
  """
  @spec always_open?(Plug.Conn.t()) :: boolean()
  def always_open?(%Plug.Conn{path_info: path}) do
    Enum.any?(@doorway, fn prefix -> Enum.take(path, length(prefix)) == prefix end)
  end

  # A crawler within its budget is still an anonymous caller to the routes
  # (RequireCaller reads :caller_tier).
  defp assign_tier(conn, {:ai_crawler, family}) do
    conn
    |> assign(:caller_tier, :anonymous)
    |> assign(:ai_crawler, family)
  end

  defp assign_tier(conn, :anonymous_site), do: assign(conn, :caller_tier, :anonymous)
  defp assign_tier(conn, tier), do: assign(conn, :caller_tier, tier)

  # Over a shared budget (a crawler family's, or the anonymous site's): the
  # doorway pages stay open; a route the caller could read for free is
  # offered for sale (x402 in USDC, BRC-121 in BSV, whichever are on), and a
  # payment for it is taken; otherwise the plain 402.
  defp refuse(conn, bucket, tier, max_requests, retry_after_s)
       when tier == :anonymous_site or is_tuple(tier) do
    cond do
      always_open?(conn) ->
        conn
        |> assign_tier(tier)
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(max_requests))
        |> put_resp_header("x-ratelimit-remaining", "0")

      offering?(conn, :bsv) and get_req_header(conn, "x-bsv-beef") != [] ->
        pay(conn, :bsv, bucket, tier, max_requests, retry_after_s)

      offering?(conn, :x402) and get_req_header(conn, X402.payment_header()) != [] ->
        pay(conn, :x402, bucket, tier, max_requests, retry_after_s)

      true ->
        payment_required(conn, bucket, tier, max_requests, retry_after_s)
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

  # Whether this request may be offered, and take, a payment on this rail: the
  # rail is on, the key wasn't bad (that is a 401), and the route is open to
  # a caller with no key, so a payment never buys a 401 or a 404.
  defp offering?(conn, rail) do
    on? =
      case rail do
        :x402 -> X402Pay.enabled?()
        :bsv -> Bsv402.enabled?()
      end

    on? and not Map.has_key?(conn.private, :rate_limiter_bad_key) and AiCrawlers.payable?(conn)
  end

  # A paid retry. Each one costs work beyond a lookup (a facilitator call for
  # x402; a BEEF climb and a node call for BSV), so paid attempts on either
  # rail share two caps, per IP and site-wide, checked before the payment is
  # read at all.
  defp pay(conn, rail, bucket, tier, max_requests, retry_after_s) do
    ip = BitblocksWeb.Utils.IpHelper.get_ip_address(conn)
    now = System.system_time(:millisecond)
    window_ms = config(:window_ms, @default_window_ms)

    with {:ok, _} <- check_rate("paid:ip:#{ip}", now, window_ms, X402Pay.paid_per_ip_per_minute()),
         {:ok, _} <- check_rate("paid:site", now, window_ms, X402Pay.paid_site_per_minute()) do
      case rail do
        :x402 -> pay_x402(conn, bucket, tier, max_requests, retry_after_s, ip)
        :bsv -> pay_bsv(conn, bucket, tier, max_requests, retry_after_s, ip)
      end
    else
      {:error, retry_after_ms} ->
        retry_s = retry_seconds(retry_after_ms)
        Logger.info("Paid attempts limited #{bucket} rail=#{rail} ip=#{ip}")

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_s))
        |> send_resp(429, "Too many payment attempts. Retry after #{retry_s} seconds.")
        |> halt()
    end
  end

  defp pay_x402(conn, bucket, tier, max_requests, retry_after_s, ip) do
    case X402Pay.handle(conn) do
      {:ok, conn, _settlement} ->
        record_paid(tier)
        Logger.info("x402 paid #{bucket} path=#{conn.request_path} ip=#{ip}")

        conn
        |> assign_tier(tier)
        |> assign(:x402_paid, true)

      {:payment_required, challenge} ->
        conn
        |> X402.put_challenge(challenge)
        |> payment_required(bucket, tier, max_requests, retry_after_s)

      {:payment_required, challenge, reason} ->
        Logger.info("x402 payment refused #{bucket} reason=#{reason} ip=#{ip}")

        conn
        |> X402.put_challenge(challenge)
        |> payment_required(bucket, tier, max_requests, retry_after_s)

      # The facilitator or our guard is unavailable: nothing is served. A
      # 503 after x402_ex's settle wait may still have been paid; it records
      # the settlement when it lands (the reconciler books it), and the
      # same header retried is refused as replayed, so no one pays twice.
      {:error, reason} ->
        Logger.warning("x402 payment unavailable #{bucket} reason=#{reason}")

        conn
        |> send_resp(503, "")
        |> halt()
    end
  end

  # BRC-121: checked against our headers, claimed once, taken by our node
  # (Bitblocks.Payments.Bsv402), then served as the anonymous caller it is,
  # metered under the payer's identity key, with what was paid in the
  # response headers.
  defp pay_bsv(conn, bucket, tier, max_requests, retry_after_s, ip) do
    case Bsv402.handle(conn) do
      {:ok, paid} ->
        record_paid(tier)

        :telemetry.execute([:bitblocks, :bsv402, :paid], %{count: 1, satoshis: paid.satoshis}, %{
          outcome: paid.outcome
        })

        Logger.info(
          "BSV 402 paid #{bucket} txid=#{paid.txid} outcome=#{paid.outcome} " <>
            "path=#{conn.request_path} ip=#{ip}"
        )

        conn
        |> assign_tier(tier)
        |> assign(:bsv_payer, paid.sender_key)
        |> put_resp_header("x-bsv-payment-satoshis-paid", Integer.to_string(paid.satoshis))
        |> put_resp_header("x-bsv-txid", paid.txid)

      {:error, %{status: 402} = refused} ->
        Logger.info("BSV 402 payment refused #{bucket} reason=#{refused.reason} ip=#{ip}")

        conn
        |> put_private(:bsv402_refused, refused)
        |> put_resp_header("x-bsv-refused", Atom.to_string(refused.reason))
        |> payment_required(bucket, tier, max_requests, retry_after_s)

      # Too large (413), or our node or database didn't answer (503): nothing
      # is served, and nothing was taken.
      {:error, %{status: status} = refused} ->
        Logger.warning("BSV 402 payment not taken #{bucket} reason=#{refused.reason} ip=#{ip}")

        conn
        |> put_resp_header("x-bsv-refused", Atom.to_string(refused.reason))
        |> then(fn conn ->
          if status == 503, do: put_resp_header(conn, "retry-after", "5"), else: conn
        end)
        |> put_resp_content_type("application/json")
        |> send_resp(
          status,
          Jason.encode!(%{error: Atom.to_string(refused.reason), message: refused.detail})
        )
        |> halt()
    end
  end

  defp payment_required(conn, bucket, tier, max_requests, retry_after_s) do
    record_throttle(tier)
    conn = offers(conn)

    label = if tier == :anonymous_site, do: "Anonymous budget spent", else: "AI crawler throttled"

    Logger.info(
      "#{label} #{bucket} limit=#{max_requests} path=#{conn.request_path} " <>
        "ip=#{BitblocksWeb.Utils.IpHelper.get_ip_address(conn)}"
    )

    refusal = %{
      tier: tier,
      limit: max_requests,
      retry_after_s: retry_after_s,
      x402: get_resp_header(conn, "payment-required") != [],
      bsv: get_resp_header(conn, "x-bsv-sats") != [],
      bsv_refused: conn.private[:bsv402_refused]
    }

    {content_type, body} = PaymentRequiredHTML.body(conn, refusal)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(max_requests))
    |> put_resp_header("x-ratelimit-remaining", "0")
    |> put_resp_content_type(content_type)
    |> send_resp(402, body)
    |> halt()
  end

  # The offers a 402 carries, on each rail that's on, for a route a payment
  # could open: x402's PAYMENT-REQUIRED (unless a refused x402 payment has
  # already put a fresh one), and BRC-121's x-bsv-sats and x-bsv-server.
  defp offers(conn) do
    conn =
      if offering?(conn, :x402) and get_resp_header(conn, "payment-required") == [],
        do: X402.put_challenge(conn, X402Pay.challenge(conn)),
        else: conn

    if offering?(conn, :bsv),
      do: Enum.reduce(Bsv402.terms(), conn, fn {k, v}, c -> put_resp_header(c, k, v) end),
      else: conn
  end

  defp record_throttle({:ai_crawler, family}) do
    key = {:crawler_throttled, family}
    :ets.update_counter(@table, key, 1, {key, 0})
    :telemetry.execute([:bitblocks, :ai_crawler, :throttled], %{count: 1}, %{family: family})
  end

  defp record_throttle(:anonymous_site) do
    key = :anonymous_throttled
    :ets.update_counter(@table, key, 1, {key, 0})
    :telemetry.execute([:bitblocks, :anonymous, :throttled], %{count: 1}, %{})
  end

  defp record_paid({:ai_crawler, family}),
    do: :telemetry.execute([:bitblocks, :ai_crawler, :paid], %{count: 1}, %{family: family})

  defp record_paid(:anonymous_site),
    do: :telemetry.execute([:bitblocks, :anonymous, :paid], %{count: 1}, %{})

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

  @doc """
  Requests with no key and no session refused past the shared anonymous
  budget on this node since it started. 0 until one is refused.
  """
  @spec throttled_anonymous() :: non_neg_integer()
  def throttled_anonymous do
    ensure_table()

    case :ets.lookup(@table, :anonymous_throttled) do
      [{_, count}] -> count
      [] -> 0
    end
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

  @doc "Requests a minute a signed-in user has (`RATE_LIMIT_SIGNED_IN_PER_MINUTE`)."
  def signed_in_max_requests,
    do: config(:signed_in_max_requests, @default_signed_in_max_requests)

  defp config(key, default) do
    Application.get_env(:bitblocks, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
