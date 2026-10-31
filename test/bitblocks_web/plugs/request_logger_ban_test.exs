defmodule BitblocksWeb.Plugs.RequestLoggerBanTest do
  @moduledoc """
  Auto-ban (RequestLogger → IpBlocker). infra traced the plain 403s to it on
  2026-10-30: any 4xx counted, and bans never expired. A caller looking up
  outpoints that aren't items (404s by design) was banned for good.
  """
  # async: false — the tracking and block tables are global.
  use BitblocksWeb.ConnCase, async: false

  alias BitblocksWeb.Plugs.IpBlocker

  defp ip, do: "198.51.100.#{System.unique_integer([:positive]) |> rem(250)}"

  defp get_from(ip, path, headers \\ []) do
    headers
    |> Enum.reduce(put_req_header(build_conn(), "x-forwarded-for", ip), fn {k, v}, c ->
      put_req_header(c, k, v)
    end)
    |> get(path)
  end

  setup do
    previous = Application.get_env(:bitblocks, :invalid_request_threshold)
    Application.put_env(:bitblocks, :invalid_request_threshold, 10)
    on_exit(fn -> Application.put_env(:bitblocks, :invalid_request_threshold, previous) end)

    ip = ip()
    IpBlocker.unblock_ip(ip)
    on_exit(fn -> IpBlocker.unblock_ip(ip) end)
    %{ip: ip}
  end

  test "API 404s are answers, not abuse: they never ban", %{ip: ip} do
    for n <- 1..15 do
      get_from(ip, "/api/v1/txs/#{String.pad_leading("#{n}", 64, "0")}")
    end

    refute IpBlocker.blocked?(ip)
    assert get_from(ip, "/api/v1/blocks").status == 200
  end

  test "repeated 404s on non-API paths still ban, and the ban expires", %{ip: ip} do
    for n <- 1..10, do: get_from(ip, "/no-such-page-#{n}")

    assert IpBlocker.blocked?(ip)
    assert get_from(ip, "/api/v1/blocks").status == 403

    # An auto-ban is temporary; force its expiry rather than waiting 15 minutes.
    IpBlocker.block_ip(ip, 0)
    refute IpBlocker.blocked?(ip)
  end

  test "a caller with a valid API key is never counted", %{ip: ip} do
    {:ok, _key, token} = Bitblocks.ApiKeys.create("ban-test", 1_000)

    for n <- 1..12,
        do: get_from(ip, "/no-such-page-#{n}", [{"authorization", "Bearer #{token}"}])

    refute IpBlocker.blocked?(ip)
  end

  test "manual blocks stay until unblocked", %{ip: ip} do
    IpBlocker.block_ip(ip)
    assert IpBlocker.blocked?(ip)
    IpBlocker.unblock_ip(ip)
    refute IpBlocker.blocked?(ip)
  end
end
