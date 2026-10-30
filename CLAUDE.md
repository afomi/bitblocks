# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

When rendering html code, render each attribute on a separate line.
When rendering markdown in .md files, render each sentence on a separate line. (to improve diffs)

## Project Overview

Bitblocks is a Phoenix/Elixir application that syncs and displays Bitcoin SV blockchain data.
It connects to a Bitcoin SV node via RPC to fetch blocks and transactions, stores them in a PostgreSQL database, and provides a web interface to browse blockchain data.

## Development Commands

**Setup:**
```bash
mix setup  # Install deps, create DB, migrate, setup assets
```

**Running the server:**
```bash
mix phx.server              # Start Phoenix server
iex -S mix phx.server       # Start with IEx console
```

**Database:**
```bash
mix ecto.create             # Create database
mix ecto.migrate            # Run migrations
mix ecto.reset              # Drop, create, and migrate DB
```

**Testing:**
```bash
mix test                    # Run test suite
```

**Assets:**
```bash
mix assets.build            # Build Tailwind and esbuild
mix assets.deploy           # Build and minify for production
```

## Architecture

### Bitcoin RPC Integration

- `BitcoinsvCli` (lib/bitcoinsv_cli.ex) - Wraps Bitcoin SV RPC calls
  - Configuration loaded from config files (`:rpc_user`, `:rpc_password`, `:bitcoin_url`)
  - Handles authentication, timeouts, and error cases
  - Key methods: `getblockhash/1`, `getblock/1-2`, `getrawtransaction/1-2`

### Blockchain Sync

**Three-Phase Sync Strategy** (see docs/SYSTEM_ARCHITECTURE.md for RPC sizing details):

1. **Phase 1: Header-Only Sync (getblockheader)** - DEFAULT
   - Uses `getblockheader(hash, true)` to fetch header metadata (~400 bytes)
   - ~5,750,000x smaller than `getblock` verbosity 0 (which downloads entire 2.3 GB block!)
   - ~225,000x smaller than `getblock` verbosity 1 for blocks with 2.8M transactions
   - Returns: hash, height, version, prev/merkleroot, time, bits, nonce, tx count, chainwork
   - Sets `sync_state = "header_only"`
   - Perfect for rapid blockchain sync and chain tip monitoring

2. **Phase 2: Transaction IDs (Verbosity 1)**
   - Uses `getblock(hash, 1)` to fetch JSON with txid array (~128 MB for 4M tx blocks)
   - Adds: txid array, chainwork, difficulty, next block hash
   - Sets `sync_state = "header_synced"`
   - Memory optimization: doesn't store tx arrays >10k transactions

3. **Phase 3: Full Transactions (Individual Calls)**
   - Uses `getrawtransaction(txid, 1)` for each transaction
   - Fetched on-demand for transactions being viewed
   - Sets `sync_state = "completed"`

**Two-Job Sync Model** (Oban workers):

- `Bitblocks.Workers.SyncHeadersWorker` — ensures block headers exist
  - **Range mode**: `%{"mode" => "range", "from" => 0, "to" => 50_000}` — fills gaps in a height range
  - **Tip mode**: `%{"mode" => "tip"}` — checks chain tip once a minute, syncs new blocks. Oban cron is the sole scheduler; the worker only re-enqueues itself as a 60s backoff when the node is unreachable.
  - Uses `getblockhash` + `getblockheader` (~400 bytes per block)
  - Inserts with `on_conflict: :nothing` — idempotent, safe to overlap
  - **Tip mode** enqueues a `FetchTransactionsWorker` for each newly inserted block (the after-create job, so the tip stays fully synced). **Range/backfill mode** does not — backfill meters tx fetches in waves. See `docs/SYNCING.md`.

- `Bitblocks.Workers.FetchTransactionsWorker` — fetches raw transactions for a block
  - Two Oban lanes, each concurrency 1: `:transactions_tip` (newly confirmed blocks) and `:transactions_backfill` (historical fill-in). They never share slots, so one current + one past block fetch run in parallel and the tip is never starved. Lane chosen at enqueue via `Chain.queue_transaction_fetch(block, lane: :tip | :backfill)` (default `:backfill`).
  - Fetches in batches of 100 via `getrawtransaction`
  - Resumable — counts existing txs on restart, picks up where it left off
  - Retry budget: a block that fails 3 times (`:backfill_max_attempts`) stops being re-selected and the backfill goes idle. Clear with `Release.retry_failed_blocks()` once the cause (e.g. a down node) is fixed.
  - Runs `TransactionParser.analyze` and `Chain.record_spends` on each tx
  - Transitions block: `txs_queued → txs_syncing → completed|failed`

### Data Layer

- `Bitblocks.Chain` (lib/bitblocks/chain.ex) - Context module for blockchain data
  - CRUD operations for blocks and transactions
  - `get_block!/1` - Finds block by height (integer) or hash (string)
  - `get_transaction!/1` - Finds transaction by txid
  - `list_blocks/0` - Returns up to 1000 blocks ordered by height
  - `list_transactions/0` - Returns up to 500 transactions

**Schemas:**
- `Bitblocks.Chain.Block` - Stores block metadata with state machine for sync phases
  - **sync_state** values: `pending`, `header_only`, `header_synced`, `txs_queued`, `txs_syncing`, `completed`, `failed`
  - Transitions managed by Machinery state machine
  - Fields: hash, height, merkleroot, difficulty, tx array (empty for `header_only` state), etc.
- `Bitblocks.Chain.Transaction` - Stores transaction data (txid, raw hex, block_hash, inputs/outputs as arrays)

### Web Layer

- Phoenix LiveView for interactive UI
- Routes (lib/bitblocks_web/router.ex):
  - `/` and `/status` - Status page
  - `/blocks` - List blocks
  - `/blocks/:id` - Show block by height or hash
  - `/transactions` - List transactions
  - `/transactions/:id` - Show transaction by txid
  - `/metanet` - Metanet DAG explorer (enter txid, navigate tree)
  - `/order-book` - Open Order Book (browse BSV-20 token listings)
  - `/tokens` and `/tokens/:id` - BSV-20/BSV-21 token index (supply, holders); read-only, minting lives in qart
  - `/bitcom` and `/bitcom/:address` - live Bitcom registry (unwriter's Bitcom): namespaces, on-chain ownership proof, files, routes, usage
  - `/dev/dashboard` - LiveDashboard (dev only)

**Request Logging:**
- `BitblocksWeb.Plugs.RequestLogger` (lib/bitblocks_web/plugs/request_logger.ex) - Logs all requests with metadata
  - Captures IP address (from X-Forwarded-For header or remote_ip)
  - Logs user agent, referer, path, query string, status code, and duration
  - Detects suspicious patterns (path traversal, injection attempts, probes for common vulnerabilities)
  - Warns on 404s and other client errors
  - Tracks high request rates from individual IPs
  - All logs include timestamps in ISO8601 format for easy parsing and reporting

## Configuration

Bitcoin SV node connection is configured in config files:
- Development: config/dev.exs
- Production: config/runtime.exs or config/prod.exs
- Settings: `:bitcoin_url`, `:rpc_user`, `:rpc_password`

Database runs on PostgreSQL (default: localhost, user/pass: postgres/postgres)

Dev server runs on http://127.0.0.1:4000

## Sync Workflow

Tip sync runs automatically via Oban cron (every minute).
To manually sync a range or backfill:

```bash
# Sync headers + queue tx downloads for a range
bin/bitblocks rpc 'Bitblocks.Release.sync_headers(0, 100_000)'

# Backfill everything from genesis to tip
bin/bitblocks rpc 'Bitblocks.Release.backfill()'

# Start/stop continuous tip sync
bin/bitblocks rpc 'Bitblocks.Release.start_tip_sync()'
bin/bitblocks rpc 'Bitblocks.Release.stop_tip_sync()'

# Check gaps and status
bin/bitblocks rpc 'Bitblocks.Release.gaps()'
bin/bitblocks rpc 'Bitblocks.Release.sync_status()'
bin/bitblocks rpc 'Bitblocks.Release.status()'
```

The `/sync` page provides a web UI for these operations with live job monitoring.

### API

Anonymous callers get `RATE_LIMIT_PER_MINUTE` (default 120) requests per minute per IP.
Keyed callers send `Authorization: Bearer bbk_…` (or `x-api-key`) and get their key's own budget; create one with `bin/bitblocks rpc 'Bitblocks.Release.create_api_key("qart", 1200)'` (printed once). An unknown or revoked key is a 401.

```
GET /api/v1/blocks              — paginated block list
GET /api/v1/blocks/latest       — most recent block
GET /api/v1/blocks/:id          — block by height or hash
GET /api/v1/txs                 — paginated transactions (?protocol=Twetch to filter)
GET /api/v1/txs/:txid           — single transaction by txid
GET /api/v1/txs/:txid/proof     — merkle proof for a transaction
GET /content/:outpoint          — inscription body parsed from the raw tx on the fly (1Sat convention; immutable, nosniff, sandbox CSP)
GET /api/v1/price/bsv           — cached BSV spot price (USD) from CoinGecko
GET /api/v1/support             — sponsorship numbers for the off-site page: monthly costs, target, BSV received (CORS *)
GET /api/v1/stream/blocks       — SSE stream of new blocks
GET /api/v1/metanet/:txid       — Metanet node with parent, children, MURL path
GET /api/v1/metanet/:txid/children — children of a Metanet node
GET /api/v1/metanet/roots       — Metanet root nodes (orphans)
GET /api/v1/protocols           — registered protocols
GET /api/v1/protocols/:addr/feed — parsed protocol feed (e.g. Twetch posts)
GET /api/v1/order-book/listings — active order book listings (filters: token_id, seller, min_price, max_price)
GET /api/v1/order-book/listings/:txid — single listing detail
GET /api/v1/order-book/tokens/:token_id — listings for a token
GET /api/v1/order-book/sellers/:address — listings by seller
GET /api/v1/order-book/stats    — order book aggregate statistics
GET /api/v1/stream/order-book   — SSE stream of order book events
GET /api/v1/tokens              — indexed BSV-20/BSV-21 tokens (filters: standard, sym)
GET /api/v1/tokens/:id          — token by token_id (<txid>_<vout>) or ticker
GET /api/v1/tokens/:id/holders  — holder balances for a token
GET /api/v1/tokens/:id/transfers — transfer history for a token
GET /api/v1/tokens/stats        — token aggregate statistics
GET /api/v1/stream/tokens       — SSE stream of new tokens / transfers
GET /api/v1/addresses/:address/tokens — unspent BSV-20/21 outputs held by an address (?standard=bsv-21, ?token_id=)
GET /api/v1/bitcom              — Bitcom registry export, every namespace with re-verifiable txids (also at /bitcom.json)
GET /api/v1/bitcom/:address     — one Bitcom namespace: tier, proof, files, routes
GET /api/v1/projections/:id     — managed projection (#29): tenant, filter, definition hash
GET /api/v1/projections/:id/txs — hydrate: matching confirmed txs oldest first, frozen at a snapshot (?cursor=, ?limit=); meta.complete is false while blocks in range are syncing
GET /api/v1/projections/:id/status — index_state ready | backfilling, indexed_through_height, lag_blocks
GET /api/v1/collections/:id       — collection summary + verification (:id = grand-tardinians | rexxies, or a 1Sat collection origin outpoint)
GET /api/v1/collections/:id/items — items in mint order: origin, name, traits, current_outpoint, owner, trace_state (?cursor=, ?limit=)
POST /api/v1/collections/:id/items/lookup — {"outpoints": [...]} up to 200, answered in order from the index (no re-trace)
GET /api/v1/collections/:id/items/:outpoint — one item by origin or current outpoint; member, spent (null unless traced current), owner (?refresh=1 re-traces)
GET /api/v1/outpoints/:txid/:vout — is this outpoint an ordinal/token? answer: yes | no | unknown (spend only on "no")
GET /api/v1/script/:scripthash/history — tx history for a script (Electrum scripthash: sha256 of scriptPubKey, reversed hex)
GET /api/v1/script/:scripthash/unspent — UTXOs locked by a script
POST /api/v1/script/decode      — decode script hex into a descriptor (type, fields, asm, matched template)
GET /api/v1/script/templates    — registered script templates
POST /api/v1/script/templates   — register a script template
GET /api/v1/script/templates/:template_hash — template detail
GET /api/v1/script/templates/:template_hash/history — txs matching a template
```

## Database Schema Notes

- Blocks table has indexes on height and tx arrays (see migration 20241217061442)
- Transaction inputs/outputs stored as string arrays (not fully parsed)
- Block size fields use bigint to handle large blocks
- Blocks link via `prevblockhash` and `nextblockhash` fields
