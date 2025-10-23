defmodule BitblocksWeb.Plugs.RequestLogger do
  @moduledoc """
  Logs request metadata for all requests, with special attention to suspicious patterns.
  Useful for identifying and reporting abusive traffic.

  Also tracks invalid requests (404s, 400s, suspicious patterns) and automatically
  bans IPs that exceed configurable thresholds.
  """
  require Logger

  @table_name :request_tracking
  @auto_ban_enabled Application.compile_env(:bitblocks, :auto_ban_enabled, true)
  @invalid_request_threshold Application.compile_env(:bitblocks, :invalid_request_threshold, 10)
  @tracking_window_seconds Application.compile_env(:bitblocks, :tracking_window_seconds, 300)

  def init(opts), do: opts

  def start_link do
    # Create ETS table for tracking invalid requests per IP
    :ets.new(@table_name, [:set, :public, :named_table])
    {:ok, self()}
  end

  def call(conn, _opts) do
    start_time = System.monotonic_time()

    Plug.Conn.register_before_send(conn, fn conn ->
      duration = System.monotonic_time() - start_time
      duration_ms = System.convert_time_unit(duration, :native, :millisecond)

      # Collect comprehensive metadata
      metadata = %{
        ip: get_ip_address(conn),
        method: conn.method,
        path: conn.request_path,
        status: conn.status,
        user_agent: get_header(conn, "user-agent"),
        referer: get_header(conn, "referer"),
        duration_ms: duration_ms,
        query_string: conn.query_string,
        host: get_header(conn, "host"),
        forwarded_for: get_header(conn, "x-forwarded-for"),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      # Track invalid requests and auto-ban if enabled
      is_invalid =
        case conn.status do
          404 ->
            Logger.warning("404 Not Found", metadata)
            true

          400 ->
            Logger.warning("400 Bad Request", metadata)
            true

          status when status >= 400 and status < 500 ->
            Logger.warning("Client error #{status}", metadata)
            true

          status when status >= 500 ->
            Logger.error("Server error #{status}", metadata)
            # Don't count server errors against the client
            false

          _ ->
            # Only log successful requests at debug level
            Logger.debug("Request completed", metadata)
            false
        end

      # Detect suspicious patterns and mark as invalid if found
      is_suspicious = check_suspicious_patterns(conn, metadata)

      # Track and potentially auto-ban
      if is_invalid or is_suspicious do
        track_and_ban_if_needed(metadata.ip, conn, metadata)
      end

      conn
    end)
  end

  defp check_suspicious_patterns(conn, metadata) do
    suspicious_patterns = [
      # Common attack paths
      {~r/\.env$/i, "Attempting to access .env file"},
      {~r/wp-admin|wordpress|wp-content/i, "WordPress probe"},
      {~r/phpmyadmin|pma/i, "phpMyAdmin probe"},
      {~r/\.php$/i, "PHP file probe"},
      {~r/\.git/i, "Git directory probe"},
      {~r/admin|administrator/i, "Admin panel probe"},
      {~r/\.xml$/i, "XML file probe"},
      {~r/config\.|\.config/i, "Config file probe"},
      {~r/\.sql$/i, "SQL file probe"},
      {~r/backup|\.bak|\.old/i, "Backup file probe"},
      {~r/\.\./i, "Path traversal attempt"},
      {~r/eval\(|exec\(|system\(/i, "Code injection attempt"},
      {~r/<script|javascript:/i, "XSS attempt"}
    ]

    path = conn.request_path

    found_suspicious =
      Enum.any?(suspicious_patterns, fn {pattern, description} ->
        if Regex.match?(pattern, path) do
          Logger.warning(
            "SUSPICIOUS REQUEST DETECTED: #{description}",
            Map.put(metadata, :pattern_matched, description)
          )

          true
        else
          false
        end
      end)

    # Check for high request rate from same IP (basic check)
    check_request_frequency(metadata.ip, metadata)

    found_suspicious
  end

  defp track_and_ban_if_needed(ip, _conn, metadata) do
    if @auto_ban_enabled do
      ensure_table_exists()

      now = System.system_time(:second)

      # Get or initialize tracking data for this IP
      {invalid_count, first_seen} =
        case :ets.lookup(@table_name, ip) do
          [{^ip, count, timestamp}] ->
            # Check if we're still within the tracking window
            if now - timestamp <= @tracking_window_seconds do
              {count + 1, timestamp}
            else
              # Reset if window expired
              {1, now}
            end

          [] ->
            {1, now}
        end

      # Update the tracking
      :ets.insert(@table_name, {ip, invalid_count, first_seen})

      # Check if threshold exceeded
      if invalid_count >= @invalid_request_threshold do
        Logger.error(
          "AUTO-BAN TRIGGERED: IP #{ip} exceeded threshold with #{invalid_count} invalid requests in #{now - first_seen}s",
          Map.merge(metadata, %{
            invalid_count: invalid_count,
            threshold: @invalid_request_threshold,
            window_seconds: now - first_seen
          })
        )

        # Auto-ban the IP
        BitblocksWeb.Plugs.IpBlocker.block_ip(ip)

        # Clear tracking for this IP since it's now banned
        :ets.delete(@table_name, ip)
      end
    end
  end

  defp ensure_table_exists do
    Bitblocks.EtsHelper.ensure_table_exists(@table_name)
  end

  defp check_request_frequency(ip, metadata) do
    # Use process dictionary for simple in-memory tracking
    # Note: This is per-process, so won't track across multiple instances
    # For production, use Redis or ETS
    now = System.system_time(:second)
    key = {:request_count, ip}

    case Process.get(key) do
      nil ->
        Process.put(key, {now, 1})

      {last_reset, count} ->
        if now - last_reset < 60 do
          # Within 1 minute window
          new_count = count + 1
          Process.put(key, {last_reset, new_count})

          if new_count > 100 do
            Logger.warning(
              "HIGH REQUEST RATE DETECTED: #{new_count} requests in ~#{now - last_reset}s",
              Map.put(metadata, :request_count, new_count)
            )
          end
        else
          # Reset window
          Process.put(key, {now, 1})
        end
    end
  end

  defp get_ip_address(conn) do
    BitblocksWeb.Utils.IpHelper.get_ip_address(conn)
  end

  defp get_header(conn, header) do
    BitblocksWeb.Utils.IpHelper.get_header(conn, header)
  end
end
