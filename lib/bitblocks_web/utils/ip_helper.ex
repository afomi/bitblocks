defmodule BitblocksWeb.Utils.IpHelper do
  @moduledoc """
  Utilities for extracting and working with IP addresses from connections.

  Handles both direct connections and proxied connections (e.g., via Fly.io).
  """

  @doc """
  Extracts the client IP address from a connection.

  Checks the X-Forwarded-For header first (for proxied connections like Fly.io),
  then falls back to the remote_ip from the connection.

  ## Examples

      iex> get_ip_address(conn)
      "192.168.1.1"

      iex> get_ip_address(conn_with_forwarded_header)
      "203.0.113.1"

  """
  def get_ip_address(conn) do
    forwarded = get_header(conn, "x-forwarded-for")

    if forwarded && forwarded != "" do
      forwarded
      |> String.split(",")
      |> List.first()
      |> String.trim()
    else
      format_remote_ip(conn.remote_ip)
    end
  end

  @doc """
  Extracts a specific header value from a connection.

  Returns the first value if multiple headers with the same name exist,
  or nil if the header doesn't exist.

  ## Examples

      iex> get_header(conn, "user-agent")
      "Mozilla/5.0..."

      iex> get_header(conn, "nonexistent-header")
      nil

  """
  def get_header(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [value | _] -> value
      [] -> nil
    end
  end

  @doc """
  Formats a remote_ip tuple into a string representation.

  Handles both IPv4 and IPv6 addresses.

  ## Examples

      iex> format_remote_ip({192, 168, 1, 1})
      "192.168.1.1"

      iex> format_remote_ip({0x2001, 0x0db8, 0, 0, 0, 0, 0, 1})
      "2001:db8:0:0:0:0:0:1"

      iex> format_remote_ip(nil)
      "unknown"

  """
  def format_remote_ip(remote_ip) do
    case remote_ip do
      {a, b, c, d} ->
        "#{a}.#{b}.#{c}.#{d}"

      {a, b, c, d, e, f, g, h} ->
        "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"

      _ ->
        "unknown"
    end
  end
end
