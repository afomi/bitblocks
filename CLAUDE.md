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

**Three-Phase Sync Strategy** (see SYNC_PHASES.md for details):

1. **Phase 1: Header-Only Sync (Verbosity 0)** - DEFAULT
   - Uses `getblock(hash, 0)` to fetch raw hex (~215 bytes per block)
   - ~595,000x smaller than verbosity 1 for blocks with 4M transactions
   - Extracts: hash, height, version, prev/merkleroot, time, bits, nonce, tx count
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

**Sync Modules**:
- `Bitblocks.SyncWorker` (lib/bitblocks/sync_worker.ex) - Sequential sync with lazy mode
  - Defaults to header-only sync (verbosity 0)
  - Pass `verbosity: :with_txids` or `verbosity: 1` for Phase 2
  - Lazy batch discovery for large ranges (100 blocks at a time)
  - Idempotent - only fetches missing blocks
- `Bitblocks.BlockHeaderDecoder` (lib/bitblocks/block_header_decoder.ex) - Decodes verbosity 0 hex data
  - Parses 80-byte Bitcoin block headers
  - Computes block hash via double SHA256
  - Extracts transaction count from variable-length integer

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

To sync blockchain data, use IEx:

```elixir
iex -S mix phx.server

# Sync blocks 0-1000
Bitblocks.Sync.get_blocks(0..1000)

# Then fetch full transaction data for specific blocks
Bitblocks.Sync.get(100)  # Get all tx data for block 100
```

The sync process:
1. `get_blocks/1` fetches block metadata and stores blocks with tx ID arrays
2. `get/1` or `get_original/1` fetches full raw transaction data for each tx in a block
3. Transactions are stored with raw hex, which can be decoded using `BitcoinsvCli.decoderawtransaction/1`

## Database Schema Notes

- Blocks table has indexes on height and tx arrays (see migration 20241217061442)
- Transaction inputs/outputs stored as string arrays (not fully parsed)
- Block size fields use bigint to handle large blocks
- Blocks link via `prevblockhash` and `nextblockhash` fields
