# Memory Optimization Guide

How to diagnose and fix memory pressure in the running app.
Bitblocks runs in containers on AWS; the BEAM memory characteristics below are platform-independent, so this applies to any deploy target and to local runs under a memory cap.

The `Bitblocks.MemoryMonitor` GenServer polls VM memory every 30s and logs warnings at threshold (see `docs/SYSTEM_ARCHITECTURE.md` → Background Services).

## Immediate Diagnostics

Attach a remote console to the running release, then:

```elixir
# Current total memory (MB)
:erlang.memory(:total) |> div(1024 * 1024)

# Top memory-consuming processes
Bitblocks.MemoryMonitor.top_processes(20)

# ETS table usage
Bitblocks.MemoryMonitor.ets_tables()

# Full memory breakdown
Bitblocks.MemoryMonitor.get_memory_info()
```

Check the application logs for the MemoryMonitor's periodic usage line and any WARNING/CRITICAL entries with top-consumer diagnostics.

## Common Memory Culprits

### 1. Large block syncing (most likely)

Storing large blocks with millions of transactions in memory.
**Symptoms:** memory spikes during sync; `FetchTransactionsWorker` in top processes.

**Mitigations (already in place):**
- `FetchTransactionsWorker` fetches transactions in batches of 100, never the whole block at once.
- Tx arrays larger than 10,000 entries are not stored on the block row.
- Production `transactions` queue concurrency is bounded (4) so a fixed number of blocks fetch in parallel.

To reduce further, lower the `transactions` queue concurrency in `config/prod.exs`.

### 2. ETS table bloat

Caches growing unbounded.
**Symptoms:** ETS tables show high memory; memory grows over time and never drops; `RpcCache` in top tables.

**Mitigations:** `RpcCache` uses a TTL (10m) so entries expire. If a new cache is added, give it a TTL or a periodic cleanup rather than letting it grow unbounded.

### 3. Binary memory leaks

Large binaries (RPC responses, raw transactions) held past use.
**Symptoms:** high `binary` memory in diagnostics; memory doesn't drop after a sync completes; `bitcoinsv_cli` processes in top consumers.

**Mitigation:** force a GC on the calling process after handling a very large (>50 MB) RPC response:

```elixir
if is_binary(result) and byte_size(result) > 50_000_000 do
  :erlang.garbage_collect(self())
end
```

### 4. Process leaks

Processes spawned but never terminated.
**Symptoms:** growing process count; memory grows linearly.

**Mitigation:** supervise spawned work — use `Task.Supervisor.async/2` (or Oban) rather than a bare `Task.async/1`, so failures and lifetimes are managed.

```elixir
# Count processes (should be well under ~500 at rest)
Process.list() |> length()
```

## Emergency Actions

If memory is critical right now, from a remote console:

```elixir
# Force global garbage collection
Bitblocks.MemoryMonitor.force_global_gc()

# Pause sync by pausing the Oban queues
Oban.pause_queue(queue: :transactions)
Oban.pause_queue(queue: :blocks)

# Clear the RPC cache
Bitblocks.EtsHelper.clear(:rpc_cache)

# Re-check
:erlang.memory(:total) |> div(1024 * 1024)
```

Resume with `Oban.resume_queue/1`.

## Long-Term Strategies

1. **Sync headers only, queue transactions separately.**
   Header sync (`getblockheader`, ~400 bytes) establishes chain continuity cheaply; `FetchTransactionsWorker` then fills transaction bodies as background jobs, spreading memory over time.
   See `docs/SYSTEM_ARCHITECTURE.md` → Sync RPC Sizing.

2. **Keep large tx arrays out of memory and the row.**
   Blocks over 10k transactions don't store the full txid array; use `tx_count` instead.

3. **Stream from the database** rather than loading large result sets:

   ```elixir
   Repo.stream(query) |> Stream.chunk_every(100) |> Enum.each(&process_chunk/1)
   ```

4. **Scale out** rather than up — more containers with bounded per-instance memory, with sync/job concurrency tuned so no single instance loads a mega-block beyond its budget.

## Testing Memory Locally

```bash
# Start under a ~1GB allocator cap to surface pressure early
elixir --erl "+MBas aoffcbf +Muac 0 +Muas 1024" -S mix phx.server

# Then run a sync and watch the live memory graph
iex> :observer.start()   # System tab
```

## Monitoring

The MemoryMonitor emits telemetry on each check; wire alerts in your monitoring stack on total memory crossing your per-instance budget, and track total memory, top-process memory, ETS sizes, process count, and binary memory over time.
