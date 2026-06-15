# System Architecture

How Bitblocks runs: the background services, job queues, and async work that keep the index in sync with the chain.

For the higher-level component overview (RPC integration, sync phases, data layer, web layer), see the root `CLAUDE.md`.

---

## Sync RPC Sizing — why three phases

The three-phase sync (headers → txid arrays → full transactions) exists because the RPC payload sizes differ by orders of magnitude.
Choosing the right call per phase is the difference between syncing the chain in minutes versus weeks.

**Phase 1 — `getblockheader(hash, true)`** (`sync_state = "header_only"`): returns header metadata as JSON (~400 bytes).
Do **not** use `getblock(hash, 0)` for this — verbosity 0 returns the *entire serialized block* (every transaction in raw hex).

**Phase 2 — `getblock(hash, 1)`** (`sync_state = "header_synced"`): adds the txid array (~32 bytes/txid).
Tx arrays larger than 10,000 entries are not stored in memory.

**Phase 3 — `getrawtransaction(txid, 1)`** (`sync_state = "completed"`): full decoded transaction, fetched per-txid on demand.

Payload size for a 2.8M-transaction block (e.g. block 755880):

| Call | Size | Note |
|------|------|------|
| `getblockheader` (Phase 1) | ~400 bytes | header only |
| `getblock` verbosity 1 (Phase 2) | ~90 MB | + txid array |
| `getblock` verbosity 0 | ~2.3 GB | entire raw block — **never** for header sync |
| `getblock` verbosity 2 | ~2.3 GB | fully decoded |

`getblockheader` is ~225,000x smaller than `getblock` verbosity 1, and ~5,750,000x smaller than verbosity 0, on a block this size.

Syncing ~900,000 blocks to tip: header-only ≈ 900 MB (minutes); with txid arrays ≈ 10–50 GB (hours–days); full transactions ≈ 500 GB–2 TB (weeks).

---

## Background Services

Audit of all async work in Bitblocks: what runs, how it's managed, and what should change.

### Oban workers (job queue)

Retryable, persistent, visible on `/sync`.

| Worker | Queue | Trigger | Retries |
|---|---|---|---|
| SyncHeadersWorker | blocks | Cron every minute (tip), manual (range) | 3 |
| FetchTransactionsWorker | transactions | Auto-queued by SyncHeaders | 5 |

Queue concurrency (prod): `transactions: 4, blocks: 1, default: 10`

### GenServers (supervised processes)

Always running, periodic or on-demand. Visible on `/sync` under "Background Services."

| Service | Interval | What it does |
|---|---|---|
| StatsCache | 60s | Caches block/tx COUNT(*) via fast `pg_class` estimate to avoid slow queries |
| RpcCache | On-demand, 10m TTL | Caches getblockchaininfo |
| ForkTracker | 10s | Polls getchaintips, builds fork DAG, persists to disk |
| MemoryMonitor | 30s | Checks VM memory, logs warnings at thresholds |
| MiningProxy | 5s | Polls getblocktemplate (disabled by default) |
| Collections | On-demand | Registry for NFT collections |
| Rexxies | On init | Loads Rexxie collection from JSON |
| EventPlayground | On-demand | In-memory event store per address |

### Should be Oban but isn't

| Work | Currently | Why it should be Oban |
|---|---|---|
| Collections.sync_transactions | Inline, sleeps between batches | Batch RPC work, needs retry, should be visible |
| Release.analyze_transactions | CLI task, runs in shell | Long-running, needs resumability, should survive disconnects |

### Should stay as GenServers

Everything with sub-minute polling or in-memory state.
These aren't jobs — they're services.
ForkTracker, MemoryMonitor, MiningProxy, caches.

### LiveView polling (not background work)

Some LiveViews poll on their own timer.
These are UI refresh loops, not background work — they only run when someone has the page open.

| LiveView | Interval | What it polls |
|---|---|---|
| PulseLive | 1s | Network stats |
| MempoolLive | 10s | Mempool info |
| PeerMapLive | 30s | Peer info |
| ForkGraphLive | 15s | Fork tape refresh |
| SyncLive | Reactive (500ms debounce) | Block updates via PubSub |

---

## Oban Queue Configuration

Bitblocks uses Oban for background job processing, backed by PostgreSQL.
Jobs are enqueued by application code and drained by Oban workers running inside the Phoenix process.

### Queues

| Queue | Prod concurrency | Dev concurrency | Purpose |
|-------|-----------------|-----------------|---------|
| `transactions` | 4 | 5 | Fetch full transaction data for a block from the BSV node |
| `blocks` | 1 | 3 | Block-level sync operations |
| `default` | 10 | 10 | General background work |

Production `blocks` concurrency is intentionally low (`1`) to avoid overwhelming the BSV node RPC endpoint.
Each `FetchTransactionsWorker` job can itself issue thousands of sequential RPC calls for a single large block.

### Key Worker: FetchTransactionsWorker

**Module:** `Bitblocks.Workers.FetchTransactionsWorker`
**Queue:** `transactions`
**Max attempts:** 5
**Unique constraint:** one job per `block_hash` within a 300-second window

#### What it does

1. Receives a `block_hash` argument.
2. Upgrades the block from `header_only` → `header_synced` if needed (fetches txid array).
3. Transitions block `sync_state` to `txs_syncing`.
4. Fetches full transaction data from the BSV node in batches of 100 txids at a time.
5. Writes each batch to the `transactions` table with `on_conflict: :nothing` (idempotent).
6. Transitions block to `completed` or `failed`.

#### Resumability

If the worker crashes or the node restarts mid-block, it counts existing transactions in the DB for that block hash and skips ahead to the first unfetched txid.
Re-enqueuing a job for a partially-synced block is safe.

#### Memory bounds

Default batch size is 100 transactions.
100 raw transactions ≈ 10–50 MB depending on tx size.
A 2.8M-transaction block processes as ~28,000 batches.

### Block Sync States

```
pending → header_only → header_synced → txs_queued → txs_syncing → completed
                                                                  ↘ failed
```

`FetchTransactionsWorker` moves a block from `txs_queued` → `txs_syncing` → `completed`.

### Enqueuing Jobs

Jobs are enqueued via `Chain.queue_transaction_fetch/1`, which accepts a `%Block{}` struct or a `block_hash` binary.
The `Release.backfill/1` function enqueues jobs in batches, waiting for each batch to drain before queuing the next (to avoid flooding the `oban_jobs` table with hundreds of thousands of jobs at once).

### Stale-job cleanup

On application startup, `Bitblocks.Chain.cleanup_stale_sync_jobs/0` clears sync jobs left in a "running" state by a previous crashed run.
It uses the process registry (`Process.whereis`) to distinguish a truly-running sync from an orphaned DB record, so a live job is never killed.

### Monitoring

```bash
# Count jobs by state in the transactions queue
bin/bitblocks rpc '
import Ecto.Query
Bitblocks.Repo.one(from j in Oban.Job,
  where: j.queue == "transactions",
  where: j.state in ["available", "executing", "scheduled"],
  select: count()
)'

# Full tx sync status by block sync_state
bin/bitblocks rpc 'Bitblocks.Release.tx_sync_status()'
```

### Config Files

- **Default (dev):** `config/config.exs` — `transactions: 5, blocks: 3, default: 10`
- **Production:** `config/prod.exs` — `transactions: 4, blocks: 1, default: 10`
- **Test:** `config/test.exs` — queues disabled (`queues: false`, `testing: :manual`)

### Tuning Notes

- Production `blocks: 1` is conservative by design.
Each `FetchTransactionsWorker` job holds an RPC connection open for the duration of the block.
- The `tx_batch` option on `Release.backfill/1` controls how many jobs are enqueued before waiting for the Oban queue to drain — not the per-job batch size.
Default is 100 jobs per backfill wave.
