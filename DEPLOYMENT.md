# Deployment Guide

## Hackney HTTP Client Configuration

### The Issue

When running commands on Fly.io (or other production environments), you may encounter this error:

```
** (ArgumentError) errors were found at the given arguments:
  * 1st argument: the table identifier does not refer to an existing ETS table
    (stdlib 7.0.1) :ets.lookup_element(:hackney_config, :mod_metrics, 2)
```

### The Solution

This error occurs because Hackney (the HTTP client used by HTTPoison) wasn't properly initialized. The fix has been applied in `lib/bitblocks/application.ex:10-11`:

```elixir
# Ensure Hackney pool is started for HTTPoison
:hackney_pool.start_pool(:default, [timeout: 150_000, max_connections: 100])
```

This initializes the Hackney connection pool before the application starts, ensuring all ETS tables are created.

### Configuration Options

- `timeout: 150_000` - 150 second timeout for HTTP requests (important for large block downloads)
- `max_connections: 100` - Maximum number of concurrent HTTP connections

You can adjust these values in `lib/bitblocks/application.ex` if needed for your specific deployment.

## Deploying to Fly.io

After this fix is applied, deploy to Fly.io:

```bash
# Commit the changes
git add lib/bitblocks/application.ex
git commit -m "Fix Hackney ETS initialization for production"

# Deploy to Fly.io
fly deploy
```

## Running Commands in Production

### Important: Use `rpc` Not `eval`

When running commands on Fly.io, you **must** use `rpc` instead of `eval`. The `eval` command starts a new Elixir process without the application running, so Hackney and other dependencies are not initialized. The `rpc` command runs code in the context of the already-running application.

### Method 1: One-off Commands (Recommended)

Use `rpc` to run commands directly:

```bash
# Sync a range of blocks (CORRECT WAY)
fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.sync_blocks(100001, 200000)'"

# Get blockchain info
fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.blockchain_info()'"

# Get database stats
fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.db_stats()'"

# Sync transactions for a specific block
fly ssh console -a bitblocks -C "/app/bin/bitblocks rpc 'Bitblocks.Release.sync_block_transactions(150000)'"
```

### Method 2: Interactive Remote Console

For longer sessions or multiple commands:

```bash
# Open remote console
fly ssh console -a bitblocks

# In the console, start remote IEx (connects to running app)
app/bin/bitblocks remote

# Now you can run commands interactively
Bitblocks.Release.sync_blocks(100001, 200000)
Bitblocks.Release.blockchain_info()
Bitblocks.Release.db_stats()
```

### ❌ WRONG: Don't Use `eval`

This will fail with the Hackney ETS error:

```bash
# DON'T DO THIS - eval starts a new process without the app
fly ssh console -a bitblocks -C "/app/bin/bitblocks eval 'Bitblocks.Sync.get_blocks(100001..200000)'"
```

### Available Release Commands

All commands are in `Bitblocks.Release`:

- `sync_blocks(start, end)` - Sync a range of blocks
- `sync_block_transactions(height)` - Sync transaction data for a specific block
- `blockchain_info()` - Get Bitcoin node info
- `db_stats()` - Get database statistics
- `migrate()` - Run pending migrations
- `rollback(repo, version)` - Rollback to a specific migration version

## Environment Variables

Ensure these are set in your Fly.io secrets:

```bash
fly secrets set BITCOIN_NODE_URL=http://your-node:8332
fly secrets set BITCOIN_NODE_RPC_USERNAME=your_username
fly secrets set BITCOIN_NODE_RPC_PASSWORD=your_password
fly secrets set DATABASE_URL=your_postgres_url
fly secrets set SECRET_KEY_BASE=your_secret_key
```

## Verifying the Fix

After deployment, verify Hackney is working:

```elixir
# In remote console
BitcoinsvCli.getblockchaininfo()
# Should return blockchain info without ETS errors
```

## Troubleshooting

If you still see ETS errors after deploying:

1. **Check application is fully started:**
   ```bash
   fly logs
   # Look for "Started application bitblocks"
   ```

2. **Verify Hackney pool exists:**
   ```elixir
   :hackney_pool.get_stats(:default)
   # Should return pool statistics
   ```

3. **Check for startup errors:**
   ```elixir
   Application.started_applications()
   # Should include :hackney
   ```

## Additional Notes

- The Hackney pool is initialized synchronously before the supervision tree starts
- This ensures all HTTP clients (BitcoinsvCli, HTTPoison) have access to the pool
- The 150-second timeout accommodates large Bitcoin SV blocks
- Connection pooling improves performance for multiple concurrent RPC calls
