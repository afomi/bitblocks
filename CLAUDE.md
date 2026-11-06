# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

When rendering html code, render each attribute on a separate line.
When rendering markdown in .md files, render each sentence on a separate line. (to improve diffs)

## Commits and pushes

In this repo, Claude may commit and push without asking.
This overrides the global "never run `git commit` or `git push`" rule, for this repo only.
A push to `develop` deploys to production (`.github/workflows/aws-deploy.yml`), so run the tests first and confirm the deploy finished.
Do not commit `.claude/` or `WORKSPACE_BITBLOCKS_AUDIT.md`.

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

**The sync loop** (authoritative: `docs/SYNCING.md`):

- Bitblocks is accurate as of the last-known block, and says which one: `Bitblocks.Sync.complete_through/0` is the highest H such that every block 0..H is `completed` (merkleroot rebuilt, every tx stored).
- Work goes strictly upward from `complete_through + 1`, one owner per block, never skipped. Small blocks (at most 1,000 txs each) go in runs of up to 50 blocks or 20,000 txs per job, so the hand-off between jobs is paid once per run.
- `Bitblocks.Sync.Coordinator` leads, on the Oban leader node only: header sync to the node's tip with reorgs (every minute), dispatch of the lowest incomplete blocks to worker slots, the concurrency setting, and the `{:sync_overview, _}` broadcast that `SyncProgress` shares with /syncing.
- `Bitblocks.Workers.SyncWorker` (cron, every minute) only keeps the coordinator alive.
- `Bitblocks.Workers.FetchTransactionsWorker` is the block job: queue `:sync_blocks`, unique on the block hash, one worker slot; a run job (`args.run`, from `Sync.dispatch/1`) walks its small blocks in height order.
  - Blocks up to 32 MB are fetched once as raw bytes (`Chain.RawBlock`: node REST `/rest/block/<hash>.bin`, else `getblock(hash, 0)`) and parsed locally; txids derived from the bytes must rebuild the header's merkleroot. Larger blocks use the txid list (`Chain.TxidSource`) and per-chunk bodies (`Chain.TxSources`).
  - Sequential within a block; bounded runs (`:tx_fetch_run_ms`, 30 s) that snooze and resume from the offset saved in the job's meta.
  - A failure marks the block `failed` and backs off 1, 2, 4 … minutes, capped at an hour; never gives up. The seventh failure in a row (over an hour) sends one `Notifications.sync_stall_alert/3`.
- Concurrency: admin-set on /syncing, persisted in `sync_settings`, clamped to `Sync.concurrency_limit/0` (CPU cores, `pool_size` minus `:sync_pool_reserve`, `:sync_rpc_limit` / `SYNC_RPC_LIMIT`). Default `:sync_workers`: 1 in dev and test, 2 in prod.
- Pause: admin-set on /syncing, the `paused` column of `sync_settings` (`Sync.set_paused/1`); the coordinator dispatches nothing new while it is set, across restarts and deploys, and blocks already dispatched finish.
- One writer (#39, `Bitblocks.NodeRole`): `NODE_ROLE=reader` starts a read-only web node with no Oban queues, plugins or leadership and no coordinator. Unset is a writer. Leadership lives in the database and dispatch counts live jobs there, so more instances never mean more RPC streams. `/syncing`, `/status` and `this_node` on `GET /api/v1/status` say whether this node is the sync writer and whether rate limits are shared or per node.
- `Bitblocks.Workers.SyncHeadersWorker` holds the header logic (`sync_tip/0`, `sync_range/2`, reorg handling) and still runs a manual range job.

**After a tx comes in** (authoritative: `docs/TX_PIPELINE.md`):

- `Bitblocks.Chain.TxPipeline.steps/0` is the ordered list of what happens to every stored tx, and the one place to add a step (one module plus one line).
- Chunk steps run before the insert, in `Chain.TxIngest.store_chunk/2`: `script_analysis`, `sats_out`, `burned`, `sats_in` (previous outputs from stored txs, one query per chunk; nil when one isn't stored), `fee`, `classify_outputs` (every output typed against `priv/data/tx_types/types.json` by `Bitblocks.TxTypes.Classifier`, unmatched as `custom`; the tx's set of types in `transactions.tx_types`, #49).
- Tx steps run after it: `record_spends`, `index_tokens`, `index_bitcom`.
- A tx already stored when its block is fetched is skipped, so it meets no step; `Chain.TxPipeline.CatchUp` (`CatchUpBlockWorker`, queue `:derived`) brings such a block's rows up to version after it completes.
- The block steps run once the block is `completed`: `block_totals` (`sats_out`, `fees`, `miner_reward`, `subsidy`, `burned`, and `fees_verified`: `miner_reward <= subsidy + fees`), then `type_counts` (`blocks.type_counts`, txs per type, which `/types` sums through `Bitblocks.TxTypes.Counts`).
- A failing step is logged and reported (telemetry `[:bitblocks, :tx_pipeline, :step_failed]`) and never loses the stored tx.
- Read-time facts, never stored: `Chain.output_status/1` (spent, unspent, unknown or unspendable per output; unspent only when the index reaches the tip, see `Bitblocks.Chain.Utxos`) and `Chain.nft_facts/1` (inscription or Run jig, and collection membership).
- `Release.backfill_tx_tallies(from, to, apply: true)` fills the tally columns for blocks completed before the steps; dry run by default.

- **Derived data** (authoritative: `docs/DERIVED_DATA.md`): everything `Chain.TxPipeline` adds after ingestion carries its provenance.
  Each step has a `version/0`; rows stamp the version that computed them (`transactions.script_analysis_version`, `transactions.tallies_version`, `transactions.tx_types_version`, `blocks.tallies_version`, `blocks.type_counts_version`).
  Backfills pick rows below the current version, stamp them, and record each run (dry runs too) in `derivation_runs`; `GET /content/bcat/:txid         — a BCat file, its chunks joined in order, each checked against the txid its head names; ?download=1; a short file is an error naming missing_chunks (up to 256 chunks, 32 MB)
GET /api/v1/status/derivations` shows the versions and latest runs.

- `Bitblocks.Workers.ChainTilesWorker` — builds chain-scrubber tiles (`Bitblocks.ChainTiles`) on the `:chain_tiles` lane (concurrency 1), reading `blocks` only. Cron every 5 minutes in incremental mode: a no-op until `Release.build_chain_tiles()` has run once, and when no block changed. See `docs/CHAIN_SCRUBBER.md`.

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
  - `/` - home; `/status` - status page (sign-in required)
  - `/blocks` - List blocks
  - `/blocks/:id` - Show block by height or hash (sign-in required; txids load 50 per page)
  - `/transactions` - List transactions (sign-in required)
  - `/transactions/:id` - Show transaction by txid (sign-in required)
  - `/sign-in`, `/auth/github`, `/auth/github/callback`, `DELETE /auth/logout` - GitHub sign-in (`BitblocksWeb.UserAuth`, `BitblocksWeb.AuthController`)
  - `/metanet` - Metanet DAG explorer (enter txid, navigate tree)
  - `/order-book` - Open Order Book (browse BSV-20 token listings)
  - `/tokens` and `/tokens/:id` - BSV-20/BSV-21 token index (supply, holders); read-only, minting lives in qart
  - `/collections` and `/collections/:id` - BSV NFT collections index and show (`:id` is a slug or origin outpoint; one view for every collection)
  - `/types` and `/types/:id` - transaction types glossary (#49): pattern, spend, spec and real examples per type, from `priv/data/tx_types/types.json` (`Bitblocks.TxTypes`); `/types` shows each type's tx count and first block, summed from `blocks.type_counts` over the blocks verified complete and typed, and says which range that is (`Bitblocks.TxTypes.Counts`, refreshed every 10 minutes); `/types/:id` adds first height, date and txid and txs per 10,000 blocks (#51)
  - `/bitcom` and `/bitcom/:address` - live Bitcom registry (unwriter's Bitcom): namespaces, on-chain ownership proof, files, routes, usage
  - `/syncing` - signed-in live sync view: blocks fetching on each lane with synced and processed x of y, recent completions, tips and blocks by sync_state, from one shared snapshot (`Bitblocks.SyncProgress`; `docs/SYNCING.md`); admins also get the operator panel there: pause, worker slots, node load, failed blocks, the audit. `/sync` redirects to it
  - `/chain-scrubber` - admin only: scrub the chain genesis to tip in three.js from precomputed tiles (`docs/CHAIN_SCRUBBER.md`); `/chain-scrubber/tiles/manifest` and `/chain-scrubber/tiles/:level/:idx` serve the tiles from ETS with no DB query
  - `/tx-graph` - admin only: the transaction flow space, a block range in three.js with every input as an arc to the output it spends, scrubbed by a playhead (`docs/TX_FLOW.md`); data from `/chain-scrubber/flow?from=&to=` (`Bitblocks.ChainFlow`)
  - `/annotations` - admin only: CRUD for chain annotations (forks, upgrades, halvings, mintings, milestones, world events), placed by height, txid or date (`Bitblocks.Annotations`); drawn on both scenes
  - `/dev/dashboard` - LiveDashboard (dev only)

**Access (`BitblocksWeb.UserAuth`):**
- Public: home, `/blocks`, the beta features, `/reorgs`, `/protocols`, `/about`, the API, `/content`.
- Signed in with GitHub: block and transaction detail, `/status`, `/syncing`.
- Admin: everything in the router's `:admin` scope plus the chain-scrubber tiles.
  An admin is a GitHub user whose row is marked admin (`users.admin`, keyed by their GitHub numeric id; set with `bin/bitblocks rpc 'Bitblocks.Release.set_admin("afomi", true)'`).
  Sign-in asks GitHub for the public profile only; admin is read from the row on each request, so a grant or revoke takes effect on the next page load.
- GitHub sign-in needs `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET`; unset, the sign-in page says it isn't configured.
  In prod both come from the AWS Secrets Manager secret `bitblocks/prod`, which `.github/scripts/deploy.sh` writes to `/opt/bitblocks.env` on every deploy.
- config/test.exs turns the gate off for the suite; `test/bitblocks_web/user_auth_test.exs` turns it on.

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

The sync loop runs by itself (docs/SYNCING.md); there is nothing to start, retry or repair by hand after an outage.

```bash
# Where it stands: complete through block X of N known, the target block
bin/bitblocks rpc 'Bitblocks.Release.sync_status()'

# Store headers for a range by hand (the loop also fills header gaps)
bin/bitblocks rpc 'Bitblocks.Release.sync_headers(0, 100_000)'

# Reopen completed blocks the audit finds short of transactions
bin/bitblocks rpc 'Bitblocks.Release.repair_incomplete_blocks()'

# Check gaps and status
bin/bitblocks rpc 'Bitblocks.Release.gaps()'
bin/bitblocks rpc 'Bitblocks.Release.sync_status()'
bin/bitblocks rpc 'Bitblocks.Release.status()'

# Derived data (docs/DERIVED_DATA.md): bring rows below the current version up to it.
# Dry run first; apply in ascending ranges; a dry run then reports 0 below version.
bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_tallies(0, 10_000)'
bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_tallies(0, 10_000, apply: true)'
bin/bitblocks rpc 'Bitblocks.Release.backfill_script_analysis(0, 10_000)'
bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_types(0, 10_000)'
bin/bitblocks rpc 'Bitblocks.Release.derivation_runs()'

# The same backfills as Oban jobs, one range at a time: no open connection, carries on across a deploy
bin/bitblocks rpc 'Bitblocks.Release.start_backfill("tx_steps", 0, 10_000)'
bin/bitblocks rpc 'Bitblocks.Release.start_backfill("tx_steps", 0, 10_000, apply: true)'
bin/bitblocks rpc 'Bitblocks.Release.start_tx_sizes_backfill(apply: true)'
bin/bitblocks rpc 'Bitblocks.Release.backfill_status()'
bin/bitblocks rpc 'Bitblocks.Release.backfill_status(1)'
bin/bitblocks rpc 'Bitblocks.Release.pause_backfill(1)'
bin/bitblocks rpc 'Bitblocks.Release.resume_backfill(1)'
bin/bitblocks rpc 'Bitblocks.Release.cancel_backfill(1)'

# Each tx's size_bytes and raw_in_db on older rows (docs/TX_STORAGE.md): dry run first
bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_sizes()'
bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_sizes(apply: true)'

# A reorg's orphaned tx rows (#34): dry run first, then add apply: true
bin/bitblocks rpc 'Bitblocks.Release.reconcile_orphaned_block("<orphan hash>")'

# Block objects in the tx store (docs/TX_STORAGE.md): dry run first, then add apply: true
bin/bitblocks rpc 'Bitblocks.Release.store_block_objects(0, 9_999)'

# BSV-21 transfer validation (#41): dry run first, then add apply: true
bin/bitblocks rpc 'Bitblocks.Release.revalidate_token_transfers()'

# Bitcom registry snapshot (#21): writes a new version if the registry changed; a daily cron does the same
bin/bitblocks rpc 'Bitblocks.Release.bitcom_snapshot()'

# Historical Bitcom commands from WhatsOnChain address history (#24): dry run first (docs/BITCOM.md)
bin/bitblocks rpc 'Bitblocks.Release.discover_bitcom("<address>") |> IO.inspect()'
bin/bitblocks rpc 'Bitblocks.Release.discover_bitcom("<address>", apply: true)'

# The shapes behind `custom`, ranked (#51): reads raw bytes in the range, stores nothing
bin/bitblocks rpc 'Bitblocks.Release.type_candidates(0, 100_000) |> IO.inspect(limit: :infinity)'

# Chain-scrubber tiles (#48): full build once, then the cron keeps them current
bin/bitblocks rpc 'Bitblocks.Release.build_chain_tiles()'
bin/bitblocks rpc 'Bitblocks.Release.chain_tiles_status()'

# The tx store (CDN) counted against the chain: declared, stored, in the store, sampled (read-only)
bin/bitblocks rpc 'Bitblocks.Release.tx_store_reconcile(0, 9_999)'
```

`/syncing` shows the loop live; admins also get the worker-slot control and the load on our node there.

### API

Logged-out callers get `RATE_LIMIT_PER_MINUTE` (default 30) requests per minute per IP.
These limits count per node until the Erlang cluster is connected (`this_node.rate_limit_scope` on `/api/v1/status`).
Logged-in users get `RATE_LIMIT_SIGNED_IN_PER_MINUTE` (600) per user, and admins `RATE_LIMIT_ADMIN_PER_MINUTE` (3,000) per user.
This covers HTTP requests, not events over an open LiveView socket.
Keyed callers send `Authorization: Bearer bbk_…` (or `x-api-key`) and get their key's own budget; create one with `bin/bitblocks rpc 'Bitblocks.Release.create_api_key("qart", 1200)'` (printed once), or register one made elsewhere from its sha256 with `Release.create_api_key_from_hash/3`, so the key never appears in command output. An unknown or revoked key is a 401.

```
GET /api/v1/blocks              — paginated block list
GET /api/v1/blocks/latest       — most recent block
GET /api/v1/blocks/:id          — block by height or hash
GET /api/v1/txs                 — transactions newest confirmation first, keyset cursor `<height>:<txid>` (?protocol=Twetch, ?block_hash=, ?txid=<hex prefix>); meta.complete is false while any block in range is not completed
GET /api/v1/txs/:txid           — single transaction by txid; confirmed (true | false) and confirmation: confirmed | unverified | orphaned (`Chain.confirmations/1`), also on the list
GET /api/v1/txs/:txid/proof     — merkle proof for a transaction
GET /api/v1/txs/:txid/beef      — BRC-62 BEEF as hex: the tx with its own BUMP, its parents first (up to 25; parents_missing, complete); same errors as /proof
GET /api/v1/txs/:txid/raw       — the tx's exact bytes (octet-stream), verified against the txid, immutable; the CDN origin (docs/TX_STORAGE.md)
GET /content/:outpoint          — inscription body parsed from the raw tx on the fly (1Sat convention; immutable, nosniff, sandbox CSP)
GET /content/bcat/:txid         — a BCat file, its chunks joined in order, each checked against the txid its head names; ?download=1; a short file is an error naming missing_chunks (up to 256 chunks, 32 MB)
GET /api/v1/status/derivations  — each pipeline step's version, stage and derivation versions, latest backfill runs
GET /api/v1/price/bsv           — cached BSV spot price (USD) from CoinGecko
GET /api/v1/support             — sponsorship numbers for the off-site page: monthly costs, target, BSV received (CORS *)
GET /api/v1/stream/blocks       — SSE stream: `block_updated` (height, hash, sync_state; each new header and state change) and `reorg` (fork_point, fork_height, orphans)
GET /api/v1/metanet/:txid       — Metanet node with parent, children, MURL path
GET /api/v1/metanet/:txid/children — children of a Metanet node
GET /api/v1/metanet/roots       — Metanet root nodes (orphans)
GET /api/v1/protocols           — registered protocols
GET /api/v1/protocols/:addr/feed — parsed protocol feed (e.g. Twetch posts), same order, cursor and meta as /api/v1/txs; an item that does not parse has parse_error
GET /api/v1/order-book/listings — open listings, none whose token outpoint is in spend_index; status active only when known unspent, else unknown (Chain.Utxos rule); signature_checked: false; meta.indexed_through_height, meta.tip_height (filters: token_id, seller, min_price, max_price)
GET /api/v1/order-book/listings/:txid — single listing detail (status spent when a stored tx spends its token outpoint)
GET /api/v1/order-book/tokens/:token_id — listings for a token
GET /api/v1/order-book/sellers/:address — listings by seller
GET /api/v1/order-book/stats    — order book aggregate statistics
GET /api/v1/stream/order-book   — SSE stream of order book events
GET /api/v1/tokens              — indexed BSV-20/BSV-21 tokens (filters: standard, sym)
GET /api/v1/tokens/:id          — token by token_id (<txid>_<vout>) or ticker
GET /api/v1/tokens/:id/holders  — holder balances for a token: the mint and validated transfers only (#41), with transfer counts by status
GET /api/v1/tokens/:id/transfers — transfer history for a token
GET /api/v1/tokens/stats        — token aggregate statistics
GET /api/v1/stream/tokens       — SSE stream of new tokens / transfers
GET /api/v1/addresses/:address/balance — status exact | partial | unknown, indexed_through_height, tip_height; confirmed only when exact, else unknown (sats with no settled spent-ness). Rule: Bitblocks.Chain.Utxos
GET /api/v1/addresses/:address/utxos — data: known-unspent outputs only (empty unless exact); unknown: outputs whose spent-ness isn't settled; meta.status, meta.indexed_through_height
GET /api/v1/utxo/:txid/:vout/owner — address, spent (true | false | null), status, source: local | whatsonchain (local first; WoC only when local is unknown or the tx isn't stored)
GET /api/v1/woc/address/:address/balance|unspent — WoC shapes, served only when exact; otherwise a 503 with status and indexed_through_height
GET /api/v1/addresses/:address/tokens — unspent BSV-20/21 outputs held by an address (?standard=bsv-21, ?token_id=)
GET /api/v1/types               — transaction types, each with its page URL and counts (txs, first_seen_height, first_seen_txid, first_seen_time, per_10000_blocks); top-level counts names the range they cover (CORS *)
GET|POST|PATCH|DELETE /api/v1/annotations[/:id] — admin only: chain annotations (?from=&to=, ?kind=); writes must be application/json
GET /api/v1/types/:id           — one type with its latest examples from the index (status ok | coming | unavailable)
GET /api/v1/bitcom              — Bitcom registry export, every namespace with re-verifiable txids (also at /bitcom.json)
GET /api/v1/bitcom/:address     — one Bitcom namespace: tier, proof, files, routes
GET /api/v1/bitcom/snapshots    — versioned registry snapshots, newest first, each with its sha256 (CORS *)
GET /api/v1/bitcom/snapshots/:version — one snapshot's exact bytes (or latest); sha256sum of the body matches the listed hash
GET /api/v1/bit/:address/*path  — resolves bit://<address>/<path> to providers' endpoints; returned, never fetched
GET /b/:txid                    — a B:// file parsed from its tx on the fly (immutable, nosniff, sandbox CSP)
GET /api/v1/projections/:id     — managed projection (#29): tenant, filter, definition hash
GET /api/v1/projections/:id/txs — hydrate: matching confirmed txs oldest first, frozen at a snapshot (?cursor=, ?limit=); meta.complete is false while blocks in range are syncing
GET /api/v1/projections/:id/status — index_state ready | backfilling, indexed_through_height, lag_blocks
GET /api/v1/collections/:id       — collection summary + verification (:id = grand-tardinians | rexxies, or a 1Sat collection origin outpoint)
GET /api/v1/collections/:id/items — items in mint order: origin, name, traits, current_outpoint, owner, trace_state: current | ended | partial | unknown | untraced (current and ended are settled; ended is final: the trail truly ends, e.g. a Run jig spent outside Run), trace_error + trace_checked_at for a failed last attempt that kept the last known state (?cursor=, ?limit=)
POST /api/v1/collections/:id/items/lookup — {"outpoints": [...]} up to 200, answered in order from the index (no re-trace)
GET /api/v1/collections/:id/items/:outpoint — one item by origin or current outpoint; member (true | false | "unknown"; false only after a finished chain walk with every trace settled: current or ended), spent (null unless settled; always true when ended), ownership, owner (?refresh=1 re-traces)
GET /api/v1/outpoints/:txid/:vout — is this outpoint an ordinal/token? answer: yes | no | unknown (spend only on "no")
GET /api/v1/script/:scripthash/history — tx history for a script (Electrum scripthash: sha256 of scriptPubKey, reversed hex)
GET /api/v1/script/:scripthash/unspent — UTXOs locked by a script, as the address utxos: unspent (exact only), unknown, status, indexed_through_height, tip_height
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
