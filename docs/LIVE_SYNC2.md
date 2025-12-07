# Three-Phase Blockchain Sync Strategy

This document explains the optimized three-phase approach to syncing Bitcoin SV blockchain data.

## Overview

Bitblocks uses a three-phase sync strategy that dramatically reduces bandwidth and memory usage when syncing block headers,
especially for blocks containing millions of transactions.

## Phase 1: Header-Only Sync (getblockheader) ⚡

**Goal**: Quickly sync all block headers to establish blockchain continuity

**Method**: Use `getblockheader(hash, true)` RPC call
- Returns: JSON with just block header metadata (~400 bytes)
- Does NOT include transaction data (unlike `getblock` verbosity 0 which returns the ENTIRE 2.3 GB block!)

**What We Get**:
- Block hash
- Height (from prior `getblockhash` call)
- Version
- Previous block hash
- Merkle root
- Timestamp
- Difficulty (bits)
- Nonce
- Transaction count (num_tx)
- Chainwork
- Mediantime
- Next block hash (if not chain tip)

**Database State**: `sync_state = "header_only"`

**Performance**:
- **~6,000x smaller** than `getblock` verbosity 1 for blocks with 4M transactions
- **~5,750,000x smaller** than `getblock` verbosity 0 for 2.3 GB blocks!
- Can sync 900,000+ block headers in minutes instead of weeks
- Memory usage: ~400 bytes per block instead of up to 2.3 GB

**Use Cases**:
- Initial blockchain sync
- "From Block to Tip" continuous syncing
- Chain tip monitoring
- Block reorganization detection

## Phase 2: Transaction ID Array (Verbosity 1)

**Goal**: Fetch transaction IDs for blocks where we need to know what transactions are included

**Method**: Use `getblock(hash, 1)` RPC call
- Returns: JSON with block metadata + array of transaction IDs
- Size: ~32 bytes per transaction ID
- For 4M tx block: ~128 MB

**What We Get (in addition to Phase 1)**:
- Array of transaction IDs (txids)
- Chainwork
- Mediantime
- Next block hash
- Difficulty (decimal value)
- Confirmations

**Database State**: `sync_state = "header_synced"`

**Performance**:
- Still significantly smaller than verbosity 2
- Transaction IDs can be stored or omitted based on block size
- Memory optimization: We don't store tx arrays > 10,000 transactions

**Use Cases**:
- Displaying block details in UI
- Transaction lookup by block
- Merkle tree verification
- When you need to know which transactions are in a block

## Phase 3: Full Transaction Data (Individual RPC Calls)

**Goal**: Fetch complete transaction data for specific transactions

**Method**: Use `getrawtransaction(txid, 1)` RPC call for each transaction
- Returns: Full decoded transaction with inputs, outputs, scripts
- Size: Varies greatly (typically 250 bytes - 100 KB per transaction)

**What We Get**:
- Transaction version
- Inputs (previous outputs, scripts, sequence)
- Outputs (amount, scriptPubKey, addresses)
- Locktime
- Transaction size
- Block hash and confirmations

**Database State**: `sync_state = "completed"`

**Performance**:
- Only fetch transactions as needed
- Can be done lazily/on-demand
- Allows prioritization of important transactions

**Use Cases**:
- Displaying transaction details
- UTXO tracking
- Address balance calculation
- Script analysis
- Transaction parsing and indexing

## State Machine Transitions

```
pending
  ├─> header_only (Phase 1: verbosity 0)
  │     ├─> header_synced (Phase 2: verbosity 1)
  │     └─> completed (if 0 transactions)
  │
  └─> header_synced (directly to Phase 2: verbosity 1)
        ├─> txs_queued
        │     └─> txs_syncing (Phase 3)
        │           ├─> completed
        │           └─> failed
        │                 └─> txs_queued (retry)
        │
        └─> completed (if 0 transactions)
```

## Memory Optimization Examples

### Block with 2,800,000 Transactions (e.g., Block 755880)

| Approach | Size | Memory |
|----------|------|--------|
| `getblockheader` (Phase 1) | ~400 bytes | ~400 bytes |
| `getblock` verbosity 0 | 2,300,000,000 bytes | 2.3 GB |
| `getblock` verbosity 1 (Phase 2) | ~90,000,000 bytes | ~90 MB |
| `getblock` verbosity 2 (Phase 3) | ~2.3 GB | ~2.3 GB |

**Speedup**: `getblockheader` is **5,750,000x** smaller than `getblock` verbosity 0!
**Speedup**: `getblockheader` is **225,000x** smaller than `getblock` verbosity 1!

### Syncing 900,000 Blocks to Tip

| Approach | Total Data | Time Estimate |
|----------|------------|---------------|
| Header-only (Phase 1) | ~900 MB | Minutes |
| With txid arrays (Phase 2) | ~10-50 GB | Hours to days |
| Full transactions (Phase 3) | ~500 GB - 2 TB | Weeks |

## Implementation Details

### Important Note About `getblock` Verbosity 0

**DO NOT use `getblock(hash, 0)` for header-only sync!**

Bitcoin's `getblock` with verbosity 0 returns the **ENTIRE serialized block** including all transactions in raw hex format. For a block with 2.8M transactions, this is **2.3 GB of data**!

Instead, use `getblockheader(hash, true)` which returns only the header metadata in JSON format (~400 bytes).

### Why getblockheader?

`getblockheader` is specifically designed for this use case:
- Returns only block header metadata
- Includes transaction count (num_tx)
- ~400 bytes instead of gigabytes
- Perfect for rapid chain sync

### SyncWorker Modes

The `SyncWorker` now accepts a `:verbosity` option:

```elixir
# Default: header-only (fastest)
sync_block(block_height)

# With transaction IDs
sync_block(block_height, verbosity: :with_txids)

# Or use numeric verbosity
sync_block(block_height, verbosity: 0)  # header-only
sync_block(block_height, verbosity: 1)  # with txids
```

### Default Behavior

**New behavior** (as of this implementation):
- All syncs default to **header-only mode** (verbosity 0)
- Transaction ID arrays are fetched lazily only when needed
- Individual transactions are fetched on-demand

This provides the best balance of speed, bandwidth, and functionality.

## Use Case Recommendations

### When to Use Each Phase

**Phase 1 Only** (header-only):
- Initial blockchain sync
- Monitoring chain tip
- Chain reorganization detection
- Verifying blockchain continuity
- When you only need block metadata

**Phase 1 + Phase 2** (with txid arrays):
- Displaying blocks in UI
- Finding transactions by block
- Block explorer functionality
- Merkle tree verification

**All Three Phases**:
- Full blockchain indexing
- Transaction search
- Address balance tracking
- UTXO set calculation
- Smart contract indexing

## Performance Tips

1. **Start with Phase 1**: Always sync headers first to establish chain continuity
2. **Lazy-load Phase 2**: Only fetch txid arrays for blocks you need to display
3. **On-demand Phase 3**: Fetch individual transactions as users request them
4. **Batch requests**: Use batch RPC calls when fetching multiple items
5. **Limit tx arrays**: Don't store tx arrays > 10,000 transactions in memory

## Sync Modes

### Sequential Sync (SyncWorker)

The sequential sync mode processes blocks one at a time:
- Uses `getblockheader` by default for header-only sync
- Supports lazy mode for large ranges (fetches in batches of 100 blocks)
- Good for small ranges or when you want fine-grained control

```elixir
# Start sequential sync
Bitblocks.SyncWorker.start_sync({0, 1000})
```

### Parallel Sync (Pipeline)

The parallel sync mode uses a GenStage pipeline with multiple workers:
- **BlockProducer**: Fetches block hashes in batches
- **TransactionFetcher**: 8 parallel workers fetch block headers using `getblockheader`
- **DatabaseWriter**: Writes blocks to database atomically

This is **much faster** than sequential mode for large ranges:
- 8x parallelism for block fetching
- Batch RPC calls for block hashes
- Efficient backpressure management

```elixir
# Start parallel sync
Bitblocks.Sync.Pipeline.start_sync(0, 900_000)
```

**Performance**: For syncing 900,000 blocks, parallel mode can be 5-8x faster than sequential mode.

## Future Enhancements

- Background job to upgrade `header_only` blocks to `header_synced` for recent blocks
- Incremental transaction fetching with progress tracking
- Configurable pruning of old tx arrays to save database space
