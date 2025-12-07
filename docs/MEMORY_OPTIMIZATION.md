
# Memory Optimization Guide for Fly.io

This guide helps diagnose and fix memory issues when running on Fly.io's 2GB memory limit.

## Current Situation

- **Memory Limit:** 2GB per VM
- **VMs Running:** 3 instances minimum
- **Issue:** Instances crashing when exceeding 2GB

## Immediate Diagnostics

### 1. Check Memory Usage in Production

```bash
# SSH into a Fly.io instance
fly ssh console

# Once inside, attach to the running app
/app/bin/bitblocks remote

# Check current memory
:erlang.memory(:total) |> div(1024 * 1024)  # MB

# Get top processes
Bitblocks.MemoryMonitor.top_processes(20)

# Get ETS table usage
Bitblocks.MemoryMonitor.ets_tables()

# Get full memory info
Bitblocks.MemoryMonitor.get_memory_info()
```

### 2. Monitor Logs for Warnings

The MemoryMonitor will now log:
- **Every 30 seconds:** Current memory usage
- **At 1.5GB (75%):** WARNING with top 5 consumers
- **At 1.8GB (90%):** CRITICAL with full diagnostic info

Check logs:
```bash
fly logs
```

## Common Memory Culprits

### 1. **Large Block Syncing** (Most Likely)

**Problem:** Storing large blocks with millions of transactions in memory.

**Symptoms:**
- Memory spikes during sync operations
- Crashes when processing blocks > 500MB
- SyncWorker or Pipeline in top processes

**Solutions:**

#### A. Limit Transaction Storage
```elixir
# In config/runtime.exs
config :bitblocks,
  fetch_full_transactions: false,  # Already set correctly
  max_transactions_per_block: 1000  # Limit how many txs we fetch
```

#### B. Process Blocks in Smaller Chunks
```elixir
# Update sync_worker.ex or pipeline.ex
# Reduce concurrent workers from 5 to 2-3
config :bitblocks, sync_workers: 3  # Instead of 5
```

#### C. Don't Store `tx` Array for Large Blocks

Add to `database_writer.ex`:
```elixir
# Before inserting block
tx_list = if length(block_data.tx) > 10_000 do
  # For huge blocks, don't store all txids in memory
  []
else
  block_data.tx
end

block_struct = %Chain.Block{
  # ...
  tx: tx_list,  # Empty for huge blocks
  # ...
}
```

### 2. **ETS Table Bloat**

**Problem:** Caches growing unbounded.

**Symptoms:**
- ETS tables show high memory in diagnostics
- Memory grows over time, never decreases
- RpcCache or other caches in top tables

**Solutions:**

#### A. Add TTL to RPC Cache

Update `rpc_cache.ex`:
```elixir
# Use EtsHelper with TTL
def get_blockchain_info do
  Bitblocks.EtsHelper.fetch_with_ttl(
    @table_name,
    :blockchain_info,
    60,  # 60 second TTL
    fn -> fetch_and_cache_blockchain_info() end
  )
end
```

#### B. Periodic Cache Cleanup

Add to `rpc_cache.ex`:
```elixir
def handle_info(:cleanup, state) do
  # Clear old entries periodically
  Bitblocks.EtsHelper.clear(@table_name)
  schedule_cleanup()
  {:noreply, state}
end

defp schedule_cleanup do
  Process.send_after(self(), :cleanup, :timer.hours(1))
end
```

### 3. **Message Queue Buildup**

**Problem:** Processes receiving messages faster than they can process them.

**Symptoms:**
- High message_queue_len in diagnostics
- Memory grows during heavy load
- GenServer processes in top consumers

**Solutions:**

#### A. Add Backpressure to Sync Pipeline

Update `pipeline.ex`:
```elixir
# Limit demand in producer_consumer
{:producer_consumer, state,
  subscribe_to: subscribe_to,
  max_demand: 5,      # Reduce from default
  min_demand: 1}
```

#### B. Drop Messages When Overwhelmed

```elixir
def handle_info(msg, %{message_queue_len: len} = state) when len > 1000 do
  Logger.warning("Dropping message, queue too long: #{len}")
  {:noreply, state}
end
```

### 4. **Binary Memory Leaks**

**Problem:** Large binaries (RPC responses, raw transactions) not being garbage collected.

**Symptoms:**
- High `binary` memory in diagnostics
- Memory doesn't drop after sync completes
- bitcoinsv_cli processes in top consumers

**Solutions:**

#### A. Force GC After Large Operations

Update `bitcoinsv_cli.ex`:
```elixir
def getblock(hash, level) do
  result = bitcoin_rpc("getblock", [hash, level])

  # Force GC if result is large (> 50MB)
  if is_binary(result) and byte_size(result) > 50_000_000 do
    :erlang.garbage_collect(self())
  end

  result
end
```

#### B. Use Streaming for Large Responses

Instead of loading entire block in memory, stream it:
```elixir
# This is more advanced - consider for future if needed
HTTPoison.get(url, headers(), stream_to: self())
```

### 5. **Process Leaks**

**Problem:** Processes being spawned but not terminated.

**Symptoms:**
- Growing process_count in diagnostics
- Hundreds or thousands of processes
- Memory grows linearly over time

**Solutions:**

#### A. Check for Orphaned Processes

```elixir
# In IEx
Process.list() |> length()
# Should be < 500 normally

# Find processes without registered names
Process.list()
|> Enum.reject(fn pid ->
  case Process.info(pid, :registered_name) do
    {:registered_name, []} -> false
    _ -> true
  end
end)
|> length()
```

#### B. Add Process Cleanup

Ensure all spawned processes are supervised or linked:
```elixir
# Bad
Task.async(fn -> heavy_work() end)

# Good
Task.Supervisor.async(MyApp.TaskSupervisor, fn -> heavy_work() end)
```

## Emergency Actions

### If Memory is Critical Right Now:

```elixir
# Connect to remote console
fly ssh console
/app/bin/bitblocks remote

# Force global garbage collection
Bitblocks.MemoryMonitor.force_global_gc()

# Stop any running sync
Bitblocks.SyncWorker.stop_sync()
Bitblocks.Sync.Pipeline.stop_sync()

# Clear RPC cache
Bitblocks.EtsHelper.clear(:rpc_cache)

# Check if memory dropped
:erlang.memory(:total) |> div(1024 * 1024)
```

## Long-Term Solutions

### 1. Increase Memory Limit (Quick Fix)

```bash
# Update fly.toml
[[vm]]
  memory = '4gb'  # Instead of 2gb
  cpu_kind = 'shared'
  cpus = 1

# Deploy
fly deploy
```

**Cost:** ~$15/month per VM extra

### 2. Optimize Sync Strategy

**A. Sync Headers Only**

Don't fetch transaction data at all:
```elixir
# Already implemented in your code
config :bitblocks, fetch_full_transactions: false
```

**B. Queue Transactions Separately**

Use the Oban background job system you already have:
```elixir
# After syncing block headers
Bitblocks.Chain.queue_transaction_fetch_for_range(start_height, end_height)
```

This spreads memory usage over time instead of all at once.

### 3. Database Instead of Memory

**A. Don't Store Large tx Arrays**

Modify block schema to not store `tx` field for blocks > 10k transactions:
```sql
ALTER TABLE blocks ADD COLUMN tx_count INTEGER;
-- Use tx_count instead of storing the full array
```

**B. Stream from Database**

Instead of loading blocks into memory:
```elixir
# Bad
blocks = Repo.all(from b in Block, where: ...)

# Good
Repo.stream(from b in Block, where: ...)
|> Stream.chunk_every(100)
|> Enum.each(&process_chunk/1)
```

### 4. Horizontal Scaling

Instead of bigger VMs, use more smaller VMs:
```toml
# fly.toml
[[vm]]
  memory = '1gb'  # Smaller
  cpus = 1

[http_service]
  min_machines_running = 6  # More instances
```

Distribute load:
- VM 1-2: Handle web requests only
- VM 3-4: Handle sync operations only
- VM 5-6: Handle background jobs only

## Monitoring Setup

### 1. Add Memory Metrics to Telemetry

Already added! The MemoryMonitor emits:
- `[:bitblocks, :memory, :check]` - Every 30s
- `[:bitblocks, :memory, :warning]` - At 75% usage
- `[:bitblocks, :memory, :critical]` - At 90% usage

### 2. Set Up Alerts

In your monitoring tool (Prometheus/Grafana):
```
Alert: memory_high
Condition: bitblocks_memory_total_mb > 1500
Action: Send Slack notification
```

### 3. Track Over Time

Create dashboard with:
- Total memory over time
- Top processes memory
- ETS table sizes
- Process count
- Binary memory

## Testing Memory Locally

```bash
# Start app with memory limit
elixir --erl "+MBas aoffcbf +Muac 0 +Muas 1024" -S mix phx.server

# This limits to ~1GB to simulate Fly.io

# Then run sync and watch:
iex> :observer.start()
# Click "System" tab to see memory graph
```

## Recommended Configuration for 2GB Limit

```elixir
# config/runtime.exs
config :bitblocks,
  # Sync config
  fetch_full_transactions: false,
  max_transactions_per_block: 1000,
  sync_workers: 2,  # Reduce from 5

  # Oban config
  queues: [
    default: 5,
    fetch_transactions: 2  # Limit concurrent job workers
  ]
```

```toml
# fly.toml
[http_service.concurrency]
  type = 'connections'
  hard_limit = 500  # Reduce from 1000
  soft_limit = 500
```

## Summary

**Most Likely Culprit:** Syncing large blocks with millions of transactions

**Quick Wins:**
1. ✅ Add MemoryMonitor (done - will give you visibility)
2. ⚠️ Reduce sync workers from 5 to 2-3
3. ⚠️ Don't store `tx` arrays for blocks > 10k transactions
4. ⚠️ Add TTL to RPC cache

**Medium Term:**
1. Queue transaction fetching as background jobs
2. Add backpressure to sync pipeline
3. Force GC after large RPC responses

**If All Else Fails:**
1. Increase to 4GB memory ($15/month per VM)
2. Or split into specialized VMs (web vs sync vs jobs)

The MemoryMonitor will now give you detailed logs showing exactly what's consuming memory!
