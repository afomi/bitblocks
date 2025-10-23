# IP Blocking Guide

This document explains how to block abusive IPs from accessing Bitblocks, including automatic banning of IPs that make too many invalid requests.

## Auto-Ban Feature (NEW!)

Bitblocks now automatically bans IPs that exceed a threshold of invalid requests.

### How It Works

The system tracks:
- **404 errors** - Requests for non-existent pages
- **400 errors** - Bad requests
- **Suspicious patterns** - WordPress probes, path traversal, injection attempts, etc.

When an IP exceeds the threshold (default: 10 invalid requests in 5 minutes), it is automatically banned.

### Configuration

Edit `config/config.exs`:

```elixir
config :bitblocks,
  # Enable/disable auto-ban
  auto_ban_enabled: true,
  # Number of invalid requests before ban
  invalid_request_threshold: 10,
  # Time window in seconds
  tracking_window_seconds: 300  # 5 minutes
```

### Monitoring Auto-Bans

Watch for auto-ban events in your logs:

```bash
fly logs | grep "AUTO-BAN TRIGGERED"
```

Example output:
```
[error] AUTO-BAN TRIGGERED: IP 203.0.113.45 exceeded threshold with 10 invalid requests in 45s
```

### Disabling Auto-Ban

To disable in production, set in your config:

```elixir
config :bitblocks, auto_ban_enabled: false
```

Or via environment variable (in `config/runtime.exs`):

```elixir
config :bitblocks,
  auto_ban_enabled: System.get_env("AUTO_BAN_ENABLED", "true") == "true"
```

## Option 1: Fly.io Edge Blocking (Best for Permanent Bans)

Block IPs at the Fly.io edge before they reach your application:

```bash
# Block a single IP
fly ips block 203.0.113.45

# Block an IP range (CIDR notation)
fly ips block 198.51.100.0/24

# List all blocked IPs
fly ips list-blocked

# Unblock an IP
fly ips unblock 203.0.113.45
```

**Advantages:**
- Blocks traffic before it hits your app (saves resources)
- Works across all app instances
- Persists across deployments

## Option 2: Application-Level Blocking

Block IPs within the Phoenix application using the IpBlocker plug.

### Block IPs at Runtime

Connect to your production app via SSH or IEx:

```bash
# SSH into Fly.io app
fly ssh console

# Start IEx
/app/bin/bitblocks remote
```

Then in IEx:

```elixir
# Block a single IP
BitblocksWeb.Plugs.IpBlocker.block_ip("203.0.113.45")

# Block an IP range
BitblocksWeb.Plugs.IpBlocker.block_ip("198.51.100.0/24")

# List all blocked IPs
BitblocksWeb.Plugs.IpBlocker.list_blocked_ips()

# Unblock an IP
BitblocksWeb.Plugs.IpBlocker.unblock_ip("203.0.113.45")
```

**Note:** Runtime blocks are stored in ETS and will be lost on app restart.

### Block IPs via Configuration (Persistent)

Add blocked IPs to your config files for persistent blocking across restarts.

In `config/runtime.exs` or `config/prod.exs`:

```elixir
config :bitblocks, BitblocksWeb.Plugs.IpBlocker,
  blocked_ips: [
    "203.0.113.45",
    "198.51.100.0/24",
    "192.0.2.100"
  ]
```

Then redeploy:

```bash
fly deploy
```

## Finding Abusive IPs

### View Recent Logs

```bash
# See all logs
fly logs

# Filter for suspicious activity
fly logs | grep "SUSPICIOUS"

# Filter for 404s
fly logs | grep "404"

# Filter for high request rates
fly logs | grep "HIGH REQUEST RATE"
```

### Example Log Output

```
[warning] SUSPICIOUS REQUEST DETECTED: WordPress probe ip=203.0.113.45 method=GET path=/wp-admin/
[warning] HIGH REQUEST RATE DETECTED: 150 requests in ~45s ip=198.51.100.23
[warning] 404 Not Found ip=192.0.2.100 method=GET path=/api/admin
```

### Extract IPs from Logs

```bash
# Get all IPs that triggered 404s in the last hour
fly logs --since 1h | grep "404" | grep -oE 'ip=[0-9.]+' | cut -d= -f2 | sort | uniq -c | sort -rn

# Get IPs with suspicious patterns
fly logs --since 1h | grep "SUSPICIOUS" | grep -oE 'ip=[0-9.]+' | cut -d= -f2 | sort | uniq -c | sort -rn
```

## Workflow for Blocking Abusive IPs

1. **Monitor logs** for suspicious patterns:
   ```bash
   fly logs | grep -E "SUSPICIOUS|HIGH REQUEST RATE|404"
   ```

2. **Identify the offending IP** from the log output

3. **Block at the edge** (recommended):
   ```bash
   fly ips block <IP_ADDRESS>
   ```

4. **Verify the block**:
   ```bash
   fly ips list-blocked
   ```

5. **Document in logs** for future reference

## Reporting Abuse

If you need to report persistent abuse:

1. **Collect evidence** from logs showing:
   - IP address
   - Timestamps
   - Request patterns
   - Frequency

2. **Identify the IP owner**:
   ```bash
   whois <IP_ADDRESS>
   ```

3. **Report to:**
   - The IP's ISP (found in whois data)
   - Fly.io support: https://fly.io/docs/about/support/
   - abuse@<domain> (if targeting specific resources)

## Automated Blocking

For automatic blocking based on patterns, you could extend the `RequestLogger` plug to automatically call `block_ip/1` when certain thresholds are met.

Example modification to `lib/bitblocks_web/plugs/request_logger.ex`:

```elixir
# After detecting high request rate
if new_count > 200 do
  Logger.warning("AUTO-BLOCKING IP due to excessive requests")
  BitblocksWeb.Plugs.IpBlocker.block_ip(metadata.ip)
end
```

**Warning:** Be careful with auto-blocking to avoid false positives!
