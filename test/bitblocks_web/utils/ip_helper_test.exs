defmodule BitblocksWeb.Utils.IpHelperTest do
  # The ALB appends the peer address as the LAST X-Forwarded-For entry
  # (xff_header_processing.mode = append, no CloudFront in the app's path;
  # infra, 2026-11-04). Earlier entries are whatever the client sent, so
  # trusting the first let anyone dodge the rate limit or get someone else banned.
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias BitblocksWeb.Utils.IpHelper

  test "takes the last entry, the one the load balancer added" do
    conn = conn(:get, "/") |> put_req_header("x-forwarded-for", "6.6.6.6, 203.0.113.9")
    assert IpHelper.get_ip_address(conn) == "203.0.113.9"
  end

  test "a forged header alone can't choose the address" do
    conn = conn(:get, "/") |> put_req_header("x-forwarded-for", "1.1.1.1, 2.2.2.2, 198.51.100.7")
    assert IpHelper.get_ip_address(conn) == "198.51.100.7"
  end

  test "a single entry is the client" do
    conn = conn(:get, "/") |> put_req_header("x-forwarded-for", "203.0.113.9")
    assert IpHelper.get_ip_address(conn) == "203.0.113.9"
  end

  test "without the header, the socket address" do
    conn = %{conn(:get, "/") | remote_ip: {192, 0, 2, 1}}
    assert IpHelper.get_ip_address(conn) == "192.0.2.1"
  end
end
