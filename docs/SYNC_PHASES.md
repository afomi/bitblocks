# Three-Phase Blockchain Sync Strategy

This document explains the optimized three-phase approach to syncing Bitcoin SV blockchain data.

## Overview

Bitblocks now uses a three-phase sync strategy that dramatically reduces bandwidth and memory usage when syncing block headers, especially for blocks containing millions of transactions.

## Phase 1: Header-Only Sync (Verbosity 0) ⚡

**Goal**: Quickly sync all block headers to establish blockchain continuity

**Method**: Use `getblock(hash, 0)` RPC call
- Returns: Raw hex-encoded block data (~215 bytes for minimal blocks, ~1KB typical)
- Contains: 80-byte block header + transaction count + all transaction data (serialized)

**What We Extract**:
- Block hash (computed via double SHA256 of header)
- Height (from `getblockhash` call)
- Version
- Previous block hash
- Merkle root
- Timestamp
- Difficulty (bits)
- Nonce
- Transaction count (from variable-length integer after header)
- Total block size

**Database State**: `sync_state = "header_only"`

**Performance**:
- **~595,000x smaller** than verbosity 1 for blocks with 4M transactions
- Can sync 900,000+ block headers in minutes instead of weeks
- Memory usage: ~1KB per block instead of up to 256 MB

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

### Block with 4,000,000 Transactions

| Approach | Size | Memory |
|----------|------|--------|
| Verbosity 0 (header only) | ~215 bytes | ~1 KB |
| Verbosity 1 (with txids) | 128,000,032 bytes | ~128 MB |
| Verbosity 2 (full tx data) | ~1-4 GB | ~1-4 GB |

**Speedup**: Phase 1 is **595,000x** smaller than Phase 2!

### Syncing 900,000 Blocks to Tip

| Approach | Total Data | Time Estimate |
|----------|------------|---------------|
| Header-only (Phase 1) | ~900 MB | Minutes |
| With txid arrays (Phase 2) | ~10-50 GB | Hours to days |
| Full transactions (Phase 3) | ~500 GB - 2 TB | Weeks |

## Implementation Details

### Header Decoder

The `Bitblocks.BlockHeaderDecoder` module decodes the 80-byte Bitcoin block header:

```elixir
# Block header format (80 bytes):
# - Version (4 bytes, little-endian)
# - Previous block hash (32 bytes, reversed for display)
# - Merkle root (32 bytes, reversed for display)
# - Timestamp (4 bytes, little-endian)
# - Bits/difficulty target (4 bytes, little-endian)
# - Nonce (4 bytes, little-endian)

# After header: variable-length integer for transaction count
```

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

## Future Enhancements

- Background job to upgrade `header_only` blocks to `header_synced` for recent blocks
- Automatic pruning of old tx arrays to save database space
- Parallel header-only sync for maximum throughput
- Incremental transaction fetching with progress tracking
