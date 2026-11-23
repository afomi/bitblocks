defmodule BitblocksWeb.Plugs.PoolGuard do
  @moduledoc """
  Answers 503 with `Retry-After` while the database pool is overloaded,
  rather than a 500 a minute later.

  A distributed crawl of transaction pages filled the `Bitblocks.Repo`
  pool. Each query ran in milliseconds and waited seconds for a
  connection; a page makes a dozen of them, so a client waited about a
  minute for a 500. Two things change that:

    * **Shed at the door.** While `Bitblocks.Repo.PoolMonitor` counts at
      least `:queue_length` checkouts waiting, a request is answered 503
      before it reaches the router, and asks nothing of the pool. The
      queue drains for the requests and background jobs already in it.
    * **A dropped checkout is a 503.** When the pool drops a checkout
      (`DBConnection.ConnectionError`), the page is a 503 rather than a
      500 (the `Plug.Exception` impl below), and this plug adds
      `Retry-After` to every 503.

  Background jobs keep the pool's own settings (`queue_target`,
  `timeout`): nothing here touches the pool, only which web requests
  join its queue.

  Not shed: the load balancer's and deploy's checks (`/healthz` is
  answered before this plug, `/api/v1/status`), Stripe's webhooks, a
  signed-in session, so an operator can still reach `/syncing` during a
  crawl, and the two sign-in pages (`/sign-in`, `/auth/github`), so a
  person can sign in to get past it. Those two ask nothing of the pool
  while it is under pressure: no session means no user lookup, and
  `BitblocksWeb.IndexNotice` skips its query (`under_pressure?/0`). The
  GitHub callback, which writes the user row, is still shed.

  Config (`config :bitblocks, #{inspect(__MODULE__)}`):

    * `:queue_length`: waiting checkouts that start shedding (default 40,
      four times the default pool; env `SHED_QUEUE_LENGTH`; 0 turns
      shedding off).
    * `:retry_after_s`: the `Retry-After` value (default 10).
  """

  @behaviour Plug

  import Plug.Conn

  alias Bitblocks.Repo.PoolMonitor

  @default_queue_length 40
  @default_retry_after_s 10

  # Prefixes never shed: the deploy check and webhooks that must land.
  @exempt_prefixes ["/api/v1/status", "/webhooks/"]
  # Exact paths never shed: signing in, so a person can get past the guard.
  @exempt_paths ["/sign-in", "/auth/github"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = register_before_send(conn, &retry_after/1)

    if shed?(conn), do: shed(conn), else: conn
  end

  @doc "Whether a request arriving now would be shed (`conn` decides the exemptions)."
  @spec shed?(Plug.Conn.t()) :: boolean()
  def shed?(conn), do: under_pressure?() and not exempt?(conn)

  @doc """
  Whether the pool's queue is at or past the shedding limit right now.
  Read from the gauge, so it asks nothing of the pool; pages that are never
  shed use it to skip optional queries.
  """
  @spec under_pressure?() :: boolean()
  def under_pressure? do
    limit = queue_limit()
    limit > 0 and PoolMonitor.queue_length() >= limit
  end

  defp exempt?(conn) do
    conn.request_path in @exempt_paths or
      Enum.any?(@exempt_prefixes, &String.starts_with?(conn.request_path, &1)) or
      signed_in?(conn)
  end

  # The session cookie is already parsed by Plug.Session in the endpoint;
  # reading it asks nothing of the database.
  defp signed_in?(conn) do
    conn = fetch_session(conn)
    not is_nil(get_session(conn, "user_id"))
  rescue
    _ -> false
  end

  defp shed(conn) do
    :telemetry.execute([:bitblocks, :pool_guard, :shed], %{count: 1}, %{
      path: conn.request_path,
      queue_length: PoolMonitor.queue_length()
    })

    conn =
      conn
      |> put_private(:pool_guard, :shed)
      |> put_resp_header("cache-control", "no-store")

    if json?(conn) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        503,
        Jason.encode!(%{
          error: "busy",
          message: "The database is busy. Try again in #{retry_after_s()} seconds.",
          retry_after_s: retry_after_s()
        })
      )
      |> halt()
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(503, "Busy. Try again in #{retry_after_s()} seconds.\n")
      |> halt()
    end
  end

  defp json?(conn) do
    String.starts_with?(conn.request_path, "/api/") or
      Enum.any?(get_req_header(conn, "accept"), &String.contains?(&1, "application/json"))
  end

  defp retry_after(%Plug.Conn{status: 503} = conn) do
    case get_resp_header(conn, "retry-after") do
      [] -> put_resp_header(conn, "retry-after", Integer.to_string(retry_after_s()))
      _ -> conn
    end
  end

  defp retry_after(conn), do: conn

  defp queue_limit, do: config(:queue_length, @default_queue_length)

  @doc false
  def retry_after_s, do: config(:retry_after_s, @default_retry_after_s)

  defp config(key, default) do
    :bitblocks |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end

# A checkout the pool dropped is the database being busy, not a fault in
# the page: 503, with PoolGuard's Retry-After, rather than 500.
defimpl Plug.Exception, for: DBConnection.ConnectionError do
  def status(_exception), do: 503
  def actions(_exception), do: []
end
