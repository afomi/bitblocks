defmodule BitblocksWeb.Plugs.IpBlocker do
  @moduledoc """
  Blocks requests from specific IP addresses or CIDR ranges.

  Configure blocked IPs in config files:

      config :bitblocks, BitblocksWeb.Plugs.IpBlocker,
        blocked_ips: ["203.0.113.45", "198.51.100.0/24"]

  Or block IPs at runtime:

      BitblocksWeb.Plugs.IpBlocker.block_ip("192.0.2.100")
      BitblocksWeb.Plugs.IpBlocker.unblock_ip("192.0.2.100")
  """
  import Plug.Conn
  import Bitwise
  require Logger

  @table_name :blocked_ips

  def init(opts), do: opts

  def start_link do
    # Create ETS table for runtime IP blocking
    :ets.new(@table_name, [:set, :public, :named_table])

    # Load blocked IPs from config
    blocked_ips =
      Application.get_env(:bitblocks, __MODULE__, [])
      |> Keyword.get(:blocked_ips, [])

    Enum.each(blocked_ips, fn ip ->
      :ets.insert(@table_name, {ip, true})
    end)

    {:ok, self()}
  end

  def call(conn, _opts) do
    ip = get_ip_address(conn)

    if ip_blocked?(ip) do
      Logger.warning("Blocked request from IP: #{ip}", %{
        ip: ip,
        path: conn.request_path,
        user_agent: get_header(conn, "user-agent")
      })

      conn
      |> send_resp(403, "Forbidden")
      |> halt()
    else
      conn
    end
  end

  @doc """
  Block an IP address at runtime.

  ## Examples

      iex> BitblocksWeb.Plugs.IpBlocker.block_ip("203.0.113.45")
      :ok

      iex> BitblocksWeb.Plugs.IpBlocker.block_ip("198.51.100.0/24")
      :ok
  """
  def block_ip(ip) do
    ensure_table_exists()
    :ets.insert(@table_name, {ip, true})
    Logger.info("Blocked IP: #{ip}")
    :ok
  end

  @doc """
  Unblock an IP address.

  ## Examples

      iex> BitblocksWeb.Plugs.IpBlocker.unblock_ip("203.0.113.45")
      :ok
  """
  def unblock_ip(ip) do
    ensure_table_exists()
    :ets.delete(@table_name, ip)
    Logger.info("Unblocked IP: #{ip}")
    :ok
  end

  @doc """
  List all blocked IPs.
  """
  def list_blocked_ips do
    ensure_table_exists()

    :ets.tab2list(@table_name)
    |> Enum.map(fn {ip, _} -> ip end)
  end

  defp ip_blocked?(ip) do
    ensure_table_exists()

    # Check exact match
    case :ets.lookup(@table_name, ip) do
      [{^ip, true}] -> true
      [] -> check_cidr_ranges(ip)
    end
  end

  defp check_cidr_ranges(ip) do
    ensure_table_exists()

    # Get all blocked entries
    blocked = :ets.tab2list(@table_name)

    # Check if IP matches any CIDR range
    Enum.any?(blocked, fn {blocked_entry, _} ->
      if String.contains?(blocked_entry, "/") do
        ip_in_cidr?(ip, blocked_entry)
      else
        false
      end
    end)
  end

  defp ip_in_cidr?(ip, cidr) do
    # Simple CIDR matching for IPv4
    # For production, consider using a library like :inet_cidr
    case parse_cidr(cidr) do
      {:ok, network, prefix_len} ->
        case parse_ip(ip) do
          {:ok, ip_int} ->
            mask = calculate_mask(prefix_len)
            (ip_int &&& mask) == (network &&& mask)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp parse_ip(ip_string) do
    case String.split(ip_string, ".") do
      [a, b, c, d] ->
        with {a, ""} <- Integer.parse(a),
             {b, ""} <- Integer.parse(b),
             {c, ""} <- Integer.parse(c),
             {d, ""} <- Integer.parse(d) do
          {:ok, (a <<< 24) + (b <<< 16) + (c <<< 8) + d}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_cidr(cidr) do
    case String.split(cidr, "/") do
      [network_str, prefix_str] ->
        with {:ok, network} <- parse_ip(network_str),
             {prefix_len, ""} <- Integer.parse(prefix_str) do
          {:ok, network, prefix_len}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp calculate_mask(prefix_len) when prefix_len >= 0 and prefix_len <= 32 do
    if prefix_len == 0 do
      0
    else
      0xFFFFFFFF <<< (32 - prefix_len)
    end
  end

  defp get_ip_address(conn) do
    BitblocksWeb.Utils.IpHelper.get_ip_address(conn)
  end

  defp get_header(conn, header) do
    BitblocksWeb.Utils.IpHelper.get_header(conn, header)
  end

  defp ensure_table_exists do
    Bitblocks.EtsHelper.ensure_table_exists(@table_name)
  end
end
