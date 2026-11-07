defmodule BitblocksWeb.Utils.IpHelper do
  @moduledoc """
  Utilities for extracting and working with IP addresses from connections.

  Handles both direct connections and connections through the AWS ALB.
  """

  @doc """
  Extracts the client IP address from a connection.

  Behind the AWS ALB (`xff_header_processing.mode = append`, no CloudFront in
  the app's path), the load balancer appends the address it saw as the LAST
  X-Forwarded-For entry. Earlier entries are whatever the client sent, so only
  the last one can be trusted for rate limits and bans. If a proxy is ever put
  in front of the ALB, its entry becomes last and this must change.

  Falls back to the socket's remote_ip when there is no header.

  ## Examples

      iex> get_ip_address(conn)
      "192.168.1.1"

      iex> get_ip_address(conn_with_forwarded_header)
      "203.0.113.1"

  """
  def get_ip_address(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [] ->
        format_remote_ip(conn.remote_ip)

      values ->
        values
        |> Enum.join(",")
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> List.last()
        |> Kernel.||(format_remote_ip(conn.remote_ip))
    end
  end

  @doc """
  The client IP of a connected LiveView, by the rule of `get_ip_address/1`.
  The endpoint's socket passes `:x_headers` and `:peer_data`. Nil when neither
  is there.
  """
  def get_socket_ip(socket) do
    forwarded =
      for {"x-forwarded-for", value} <-
            Phoenix.LiveView.get_connect_info(socket, :x_headers) || [],
          entry <- String.split(value, ","),
          entry = String.trim(entry),
          entry != "",
          do: entry

    case {List.last(forwarded), Phoenix.LiveView.get_connect_info(socket, :peer_data)} do
      {nil, %{address: address}} -> format_remote_ip(address)
      {ip, _peer} -> ip
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
