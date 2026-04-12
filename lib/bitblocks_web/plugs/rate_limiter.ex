defmodule BitblocksWeb.Plugs.RateLimiter do
  @moduledoc """
  Simple ETS-backed rate limiter per IP address.

  Tracks request counts in a sliding window. Returns 429 Too Many Requests
  when the limit is exceeded, with a Retry-After header.

  ## Configuration

      config :bitblocks, BitblocksWeb.Plugs.RateLimiter,
        window_ms: 60_000,     # 1 minute window
        max_requests: 20       # 20 requests per window

  Defaults to 20 requests per minute — tight. Casual browsing is fine,
  scripted abuse hits the wall fast. Static assets bypass this plug.
  """

  import Plug.Conn
  require Logger

  @table :rate_limiter
  @default_window_ms 60_000
  @default_max_requests 20

  def init(opts), do: opts

  def call(conn, _opts) do
    ensure_table()

    ip = BitblocksWeb.Utils.IpHelper.get_ip_address(conn)
    now = System.system_time(:millisecond)
    window_ms = config(:window_ms, @default_window_ms)
    max_requests = config(:max_requests, @default_max_requests)

    case check_rate(ip, now, window_ms, max_requests) do
      {:ok, count} ->
        conn
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(max_requests))
        |> put_resp_header("x-ratelimit-remaining", Integer.to_string(max(0, max_requests - count)))

      {:error, retry_after_ms} ->
        retry_after_s = max(1, div(retry_after_ms, 1000))

        Logger.warning("Rate limited IP #{ip}")

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
          {:ok, count}
        end

      [] ->
        :ets.insert(@table, {ip, [now]})
        {:ok, 1}
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:set, :public, :named_table])
      _ -> :ok
    end
  end

  defp config(key, default) do
    Application.get_env(:bitblocks, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
