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
        admin_max_requests: 3_000     # admin, per user

  Static assets bypass this plug.

  ## Who is asking

  A valid API key first, then the session's user, then the IP:

  | Caller | Counted by | Budget a minute |
  | --- | --- | --- |
  | API key | the key | its `requests_per_minute` |
  | Admin | the user | `RATE_LIMIT_ADMIN_PER_MINUTE`, 3,000 |
  | Logged in | the user | `RATE_LIMIT_SIGNED_IN_PER_MINUTE`, 600 |
  | Logged out | the IP | `RATE_LIMIT_PER_MINUTE`, 30 |

  Counting by user means people behind one address don't share a budget. A
  session whose user is gone, or a forged cookie, which reads as no session,
  gets the IP's budget. Admin is `users.admin`.

  The tier is read once and cached (`:tier_cache_ms`, 60 s), so the limiter
  adds no query per request, and a grant or revoke reaches it within that time.

  This covers HTTP requests, including a LiveView's first render. Events over
  an open LiveView socket don't pass through the endpoint's plugs, so they
  aren't counted; a LiveView that needs a budget calls `allow?/2`.

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

  alias BitblocksWeb.Plugs.RateLimiter.Replicator

  @table :rate_limiter
  @default_window_ms 60_000
  # Prod sets these from the environment (config/runtime.exs); keyed callers use
  # their key's own budget (Bitblocks.ApiKeys).
  @default_max_requests 30
  @default_signed_in_max_requests 600
  @default_admin_max_requests 3_000
  @default_tier_cache_ms 60_000

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

        {bucket, max_requests, tier} = budget(user_id, ip, now, anonymous)
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
          # only within the IP's budget, so random keys can't hammer the DB.
          nil ->
            case limit(conn, ip, now, window_ms, anonymous, :anonymous) do
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

  defp budget(user_id, ip, now, anonymous) do
    case tier(user_id, now) do
      :admin ->
        {"user:#{user_id}", config(:admin_max_requests, @default_admin_max_requests), :admin}

      :signed_in ->
        max_requests = config(:signed_in_max_requests, @default_signed_in_max_requests)
        {"user:#{user_id}", max_requests, :signed_in}

      :anonymous ->
        {ip, anonymous, :anonymous}
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
        |> assign(:caller_tier, tier)
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(max_requests))
        |> put_resp_header(
          "x-ratelimit-remaining",
          Integer.to_string(max(0, max_requests - count))
        )

      {:error, retry_after_ms} ->
        retry_after_s = max(1, div(retry_after_ms, 1000))

        Logger.warning("Rate limited #{bucket} tier=#{tier} limit=#{max_requests}")

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(max_requests))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> send_resp(429, "Too Many Requests. Retry after #{retry_after_s} seconds.")
        |> halt()
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

  defp config(key, default) do
    Application.get_env(:bitblocks, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
