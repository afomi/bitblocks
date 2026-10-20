# Performance Optimizations

This document outlines the performance optimizations for syncing blockchain data from a remote Bitcoin SV node.

Sync itself runs as Oban jobs (`SyncHeadersWorker` + `FetchTransactionsWorker`) — see `docs/SYSTEM_ARCHITECTURE.md`.
The optimizations below are at the RPC and HTTP layers those jobs use.

## Summary of Improvements

### 1. Batch RPC Requests ⚡️

**Problem:** Each RPC call to the remote Bitcoin node has network latency (typically 50-200ms).
Fetching 100 blocks one-by-one means 100 separate HTTP requests.

**Solution:** Batch JSON-RPC requests bundle multiple calls into a single HTTP request.

**Where:** `lib/bitcoinsv_cli.ex` — `batch_rpc/1`, `batch_getblockhash/1`, `batch_getblock/2`, `batch_getrawtransaction/2`.

**Expected speedup:** 10-50x faster for block hash fetching, depending on network latency.

```elixir
# Before: 10 separate HTTP requests
Enum.map(0..9, fn height -> BitcoinsvCli.getblockhash(height) end)

# After: 1 HTTP request
BitcoinsvCli.batch_getblockhash(0..9)
```

### 2. Bounded Concurrency

Transaction fetching runs through the Oban `transactions` queue, whose concurrency is the single tuning knob (prod: 4, dev: 5 — see `docs/SYSTEM_ARCHITECTURE.md`).
The `transaction_fetcher_concurrency` config (default 8) bounds parallel RPC fan-out within a job's batch fetch.
Raising either increases parallelism to hide network latency, at the cost of more concurrent load on the node.

### 3. Graceful Error Handling in the Sync UI

`lib/bitblocks_web/live/sync_live.ex` catches `:timeout`, `:noproc`, and general errors with fallback values, and guards arithmetic in `progress_percent/1` / `job_progress_percent/1` against nil/zero.
The UI stays functional even when background jobs are busy, and rendering never crashes on a division-by-zero in progress calculations.

## Additional Features for Large Blocks

### Chunked Transaction Fetching

For BSV blocks with millions of transactions, transactions are processed in manageable chunks:

```elixir
# Fetch first 1000 transactions from a block, 100 at a time
txids = block["tx"]
transactions = BitcoinsvCli.fetch_block_transactions(txids,
  max_txs: 1000,
  chunk_size: 100
)
```

**Functions:** `BitcoinsvCli.batch_getrawtransaction/2` (batch fetch raw transactions), `BitcoinsvCli.fetch_block_transactions/2` (chunked fetch with options).

## Configuration Reference

### Current Settings

```elixir
# config/config.exs
config :bitblocks,
  transaction_fetcher_concurrency: 8,     # Parallel RPC fan-out within a fetch
  fetch_full_transactions: false,         # Only fetch transaction IDs, not full data
  max_transactions_per_block: 1000        # Limit per block when fetching tx details
```

### Hackney HTTP Connection Pool

```elixir
# lib/bitblocks/application.ex
:hackney_pool.start_pool(:default,
  timeout: 150_000,        # 150 second timeout
  max_connections: 100     # Support up to 100 parallel connections
)
```

## Performance Metrics

### Before (sequential)
- **Block hash fetching:** ~100ms per block
- **100 blocks:** ~10 seconds minimum
- **Timeout errors:** frequent during large syncs

### After (batched)
- **Block hash fetching:** ~5-10ms per block
- **100 blocks:** ~1 second (10x faster)
- **Timeout errors:** rare, with graceful degradation

## Troubleshooting

### Slow Sync Performance

1. **Check network latency to your Bitcoin node:**
   ```bash
   ping your-bitcoin-node-hostname
   ```

2. **Increase concurrency if you have bandwidth** — raise the Oban `transactions` queue concurrency (`config/prod.exs`) and/or `transaction_fetcher_concurrency` (`config/config.exs`).

3. **Monitor connection pool usage** — if you see connection errors, increase `max_connections` in `application.ex`.

### Timeout Errors

1. **Check if your Bitcoin node is responsive:**
   ```bash
   curl -X POST http://your-node:8332 \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"1.0","method":"getblockchaininfo","params":[]}'
   ```

2. **Increase the hackney `timeout`** in `application.ex` if the node is legitimately slow on large blocks.

### Large Blocks Causing Issues

For blocks with millions of transactions:

1. **Don't fetch full transaction data:** keep `fetch_full_transactions: false`.
2. **Use the chunk fetcher for selective processing:**
   ```elixir
   BitcoinsvCli.fetch_block_transactions(txids, max_txs: 10_000)
   ```
3. **Consider skipping huge blocks entirely** — add logic to skip blocks where `num_tx > 1_000_000`.

See `LARGE_BLOCKS.md` for the full large-block strategy.

## Future Optimization Ideas

1. **Database connection pooling** — increase Ecto pool size for write-heavy workloads.
2. **Batch database inserts** — write multiple blocks in a single transaction.
3. **Caching** — cache frequently accessed blocks or chain tip info.
4. **Streaming responses** — use HTTP streaming for very large responses.

## Monitoring Recommendations

Use Phoenix LiveDashboard metrics at `/dev/dashboard` (development) to track GenServer message queue lengths and query performance.
Add logging for slow operations:

```elixir
Logger.info("Processed 100 blocks in #{duration}ms")
```
