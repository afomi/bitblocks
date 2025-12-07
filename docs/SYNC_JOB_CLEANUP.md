# Sync Job Cleanup

This document explains how the stale sync job cleanup works and how to use it.

## Problem

When the application crashes or is restarted while a sync job is running, the database still shows the job as "running" even though no process is actually executing it.
This can confuse users and prevent new syncs from starting.

## Solution

### Automatic Cleanup on Startup

The application now automatically cleans up stale "running" jobs on startup:

1. **On application start** (`lib/bitblocks/application.ex:20-24`): The system waits 1 second for the database to be ready, then calls `Bitblocks.Chain.cleanup_stale_sync_jobs/0`

2. **Cleanup function** (`lib/bitblocks/chain.ex:617-648`):
   - Finds all sync jobs with status "running"
   - Marks them as "failed" with a completion timestamp
   - Logs a warning about the stale jobs

### Process Registry Check

The system uses Elixir's process registry instead of storing PIDs:

- Both `Bitblocks.SyncWorker` and `Bitblocks.Sync.Pipeline` are named GenServers
- We can check if they're alive using `Process.whereis/1`
- The helper function `Bitblocks.Chain.sync_actually_running?/0` checks if a sync is truly running

## Manual Usage

### Check if sync is actually running

```elixir
# In IEx
Bitblocks.Chain.sync_actually_running?()
# => true or false
```

### Manually clean up stale jobs

```elixir
# In IEx
Bitblocks.Chain.cleanup_stale_sync_jobs()
# => 3  (number of jobs cleaned up)
```

### Create a test stale job

```elixir
# In IEx - create a fake "running" job for testing
alias Bitblocks.Chain.SyncJob
alias Bitblocks.Repo

%SyncJob{}
|> Ecto.Changeset.change(%{
  scope: "test",
  start_block: 0,
  end_block: 100,
  status: "running",
  started_at: DateTime.utc_now(),
  blocks_synced: 0,
  total_blocks: 100,
  errors_count: 0
})
|> Repo.insert()

# Then verify cleanup works
Bitblocks.Chain.cleanup_stale_sync_jobs()
# Should mark it as failed
```

## Why This Approach?

### Idiomatic Elixir
- Uses OTP's built-in process registry
- No need to store PIDs in the database
- Leverages "let it crash" philosophy

### Simple & Reliable
- No complex heartbeat mechanisms
- No PID tracking across restarts
- Works across application restarts

### Production Ready
- Automatically runs on every startup
- Logs warnings for visibility
- Can be manually triggered if needed

## Monitoring

The cleanup logs at WARNING level, so you can monitor for:

```
Found N stale sync job(s) in 'running' state. Marking as failed (likely interrupted by restart).
```

If you see this frequently, it may indicate:
- Frequent crashes during sync
- Manual restarts during active syncs
- OOM kills or other system issues

## Future Enhancements

If needed, we could add:
1. A `/sync/cleanup` admin endpoint to manually trigger cleanup
2. A scheduled job to periodically check for stale jobs
3. More detailed failure reasons (crash vs restart vs timeout)
