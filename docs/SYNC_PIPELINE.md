# Sync Pipeline & Running Processes

## Process Map

```
┌─────────────────────────────────────────────────────────────────────────┐
│  EXTERNAL                                                               │
│                                                                         │
│  ┌──────────────┐    ┌──────────────┐    ┌────────────────────────┐    │
│  │  BSV Node    │    │  CoinGecko   │    │  Browser / qart / API  │    │
│  │  (RPC)       │    │  (HTTP)      │    │  consumers             │    │
│  └──────┬───────┘    └──────┬───────┘    └───────────┬────────────┘    │
└─────────│──────────────────│───────────────────────────│───────────────┘
          │                  │                           │
          ▼                  ▼                           ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  CACHES / INFRA                                                         │
│                                                                         │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────────┐  │
│  │  RpcCache    │    │  PriceCache  │    │  StatsCache              │  │
│  │  GenServer   │    │  GenServer   │    │  GenServer               │  │
│  │              │    │              │    │                          │  │
│  │  Caches      │    │  Caches BSV  │    │  Caches COUNT(*) block/  │  │
│  │  getblock-   │    │  spot price  │    │  tx queries — avoids     │  │
│  │  chaininfo   │    │  (5 min TTL) │    │  slow scans per request  │  │
│  │  (10 min TTL)│    │              │    │                          │  │
│  └──────┬───────┘    └──────┬───────┘    └──────────────────────────┘  │
│         │                  │                                            │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────────┐  │
│  │  ForkTracker │    │  MiningProxy │    │  RateLimiter.Replicator  │  │
│  │  GenServer   │    │  GenServer   │    │  + SseLimiter.ClusterSt. │  │
│  │              │    │              │    │                          │  │
│  │  Tracks      │    │  Serves block│    │  Cluster-replicates      │  │
│  │  competing   │    │  templates   │    │  per-IP rate limits and  │  │
│  │  chain tips  │    │  to remote   │    │  SSE connection counts   │  │
│  │  + forks     │    │  hashers     │    │  over PubSub             │  │
│  └──────────────┘    └──────────────┘    └──────────────────────────┘  │
│                                                                         │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────────┐  │
│  │  MemoryMon.  │    │  DNSCluster  │    │  Finch                   │  │
│  │  GenServer   │    │  GenServer   │    │  HTTP client pool        │  │
│  │              │    │              │    │  (used by Swoosh mailer) │  │
│  │  Warns when  │    │  Node        │    │                          │  │
│  │  memory      │    │  discovery   │    │                          │  │
│  │  approaches  │    │  for Erlang  │    │                          │  │
│  │  limits      │    │  clustering  │    │                          │  │
│  └──────────────┘    └──────────────┘    └──────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  OBAN BACKGROUND JOBS                                                   │
│                                                                         │
│  ┌───────────────────────────────────┐                                  │
│  │  SyncHeadersWorker                │                                  │
│  │  queue: :blocks                   │                                  │
│  │                                   │                                  │
│  │  Tip mode (cron 1m + 30s resched):│                                  │
│  │    RpcCache → node tip height     │                                  │
│  │    DB → our tip height            │                                  │
│  │    getblockhash + getblockheader  │                                  │
│  │    → inserts block at header_only │                                  │
│  │    → enqueues FetchTxsWorker (tip)│                                  │
│  │    → detects + resolves reorgs    │                                  │
│  │                                   │                                  │
│  │  Range mode (manual backfill):    │                                  │
│  │    same, no tx enqueue (hourly    │                                  │
│  │    backfill cron picks them up)   │                                  │
│  └─────────────────┬─────────────────┘                                  │
│                    │ enqueues (tip lane)                                 │
│                    ▼                                                     │
│  ┌───────────────────────────────────┐  ┌────────────────────────────┐  │
│  │  FetchTransactionsWorker          │  │  BackfillTransactionsWorker│  │
│  │  queue: :transactions_tip         │  │  queue: :transactions_     │  │
│  │  (concurrency 1)                  │  │    backfill (concurrency 1)│  │
│  │                                   │  │  cron: hourly, self-       │  │
│  │  TxidSource.txids                 │  │    rescheduling            │  │
│  │    verified txid list (num_tx     │  │                            │  │
│  │    denominator, merkle-checked,   │  │  next lowest incomplete    │  │
│  │    re-fetched if array truncated) │  │    block (any state incl.  │  │
│  │  txs_queued → txs_syncing         │  │    orphaned txs_queued)    │  │
│  │    getrawtransaction (batch 100,  │  │  diff-and-fill: fetch ONLY │  │
│  │    only MISSING txids)            │  │    missing txids per chunk │  │
│  │  TxIngest.store (shared):         │  │  same TxidSource + TxIngest│  │
│  │    body-hash check, analyze,      │  │  verify count → completed  │  │
│  │    record_spends, index_tokens    │  │    | failed (never silent) │  │
│  │  verified count → completed       │  │  reschedule for next block │  │
│  │    | failed                       │  │                            │  │
│  └───────────────────────────────────┘  └────────────────────────────┘  │
│   Two separate concurrency-1 lanes: tip never starved, backfill never    │
│   competes. Completeness audit: Release.audit_completeness/1 +           │
│   repair_incomplete_blocks/1 (also on /sync).                            │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  DATA LAYER                                                             │
│                                                                         │
│  ┌──────────────────────────┐    ┌──────────────────────────────────┐  │
│  │  Repo (PostgreSQL)       │    │  PubSub                          │  │
│  │                          │    │                                  │  │
│  │  blocks                  │    │  "block:#{hash}"                 │  │
│  │  transactions            │    │  "blocks"                        │  │
│  │  spends                  │    │  "order_book"                    │  │
│  │  oban_jobs               │    │                                  │  │
│  │  protocols               │    │  LiveViews subscribe; workers    │  │
│  │  order_book_listings     │    │  broadcast on block updates      │  │
│  └──────────────────────────┘    └──────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  WEB LAYER (BitblocksWeb.Endpoint)                                      │
│                                                                         │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐  │
│  │  LiveViews       │  │  API Controllers │  │  SSE Streams         │  │
│  │                  │  │  /api/v1/*       │  │  /api/v1/stream/*    │  │
│  │  /blocks         │  │                  │  │                      │  │
│  │  /sync           │  │  BlockController │  │  blocks              │  │
│  │  /metanet        │  │  TxController    │  │  order-book          │  │
│  │  /order-book     │  │  PriceController │  │                      │  │
│  │  /ecosystem      │  │  MetanetCtrl     │  │                      │  │
│  │  /block-graph    │  │  OrderBookCtrl   │  │                      │  │
│  └──────────────────┘  └──────────────────┘  └──────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Why "App Indexed" Lags "Synced Blocks"

**Synced Blocks** = `getblockchaininfo.blocks` — the node's own count, nothing to do with our DB.

**App Indexed** = `COUNT(*) FROM blocks` — all block rows regardless of `sync_state`.

The gap closes within ~1 min per new block (one `SyncHeadersWorker` tip cycle — cron every minute, 30 s self-reschedule while active).
`App Indexed` counts the row from the moment the header is inserted (`header_only`).
Full transaction indexing (`completed`) happens separately and takes longer for large blocks.

### Block sync_state lifecycle

```
[not in DB]
    │
    │  SyncHeadersWorker (tip/range)
    ▼
header_only       ← header metadata only; no transactions
    │
    │  FetchTransactionsWorker
    ▼
header_synced     ← txid list fetched (getblock v1)
    │
    │
    ▼
txs_queued        ← Oban job enqueued
    │
    │
    ▼
txs_syncing       ← raw transactions being fetched
    │
    ├──(success)──▶ completed
    └──(error)────▶ failed
```

The `/sync` page shows a breakdown by `sync_state` so you can see exactly where blocks are in the pipeline.
