# Handling Large BSV Blocks

Bitcoin SV blocks can contain millions of transactions, resulting in JSON responses that are hundreds of megabytes. This document explains the challenges and solutions.

## The Problem

**Example: Block 643055**
- Contains ~1.8 million transactions
- JSON response: ~200-400MB
- Takes minutes to download and parse
- Can cause memory issues and timeouts

## Current Mitigations

### 1. Increased Timeouts

**RPC Calls:**
```elixir
# Individual RPC calls
timeout: 120_000      # 2 minutes
recv_timeout: 120_000
max_body_length: 500_000_000  # 500MB

# Batch RPC calls
timeout: 180_000      # 3 minutes
```

**GenServer Calls:**
```elixir
start_sync: 60_000   # 60 seconds for database queries
```

### 2. Block Size Limits

The `Sync.get/1` function now skips blocks with >100,000 transactions:

```elixir
if tx_count > 100_000 do
  {:error, :too_many_transactions}
end
```

**Why 100,000?**
- Blocks with 100k transactions = ~10-20MB JSON response (manageable)
- Blocks with 1M+ transactions = 200-400MB JSON response (problematic)

### 3. Better Error Handling

Parse errors are now caught and logged:

```elixir
{:error, {:parse_error, _}} ->
  {:error, :response_too_large}
```

## Strategies for Large Blocks

### Option 1: Skip Mega-Blocks

**For blocks with millions of transactions:**
- Store block header only (already done during initial sync)
- Skip transaction details
- Mark block as "header_synced" not "completed"

**Configuration:**
```elixir
# In Sync.get/1
if tx_count > 100_000 do
  # Skip this block
end
```

### Option 2: Chunked Transaction Fetching

**For blocks you DO want to process:**

```elixir
# Get block header with tx IDs (verbosity 1)
{:ok, block} = BitcoinsvCli.getblock(hash, 1)

# Process transactions in chunks
block["tx"]
|> Enum.chunk_every(1000)  # 1000 tx at a time
|> Enum.each(fn chunk ->
  {:ok, txs} = BitcoinsvCli.batch_getrawtransaction(chunk)
  # Store transactions
end)
```

### Option 3: Use Verbosity 0

**Get raw block hex instead of JSON:**

```elixir
# Returns hex string instead of full JSON
raw_block = BitcoinsvCli.getblock(hash, 0)

# Parse locally
{:ok, parsed_block} = BSV.Block.from_binary(raw_block, encoding: :hex)
```

**Advantages:**
- Smaller response size
- Faster download
- Parse on your side (more control)

**Disadvantages:**
- Need to parse binary format
- More complex code

### Option 4: External Block Explorers

For mega-blocks, use an external service:
- WhatsOnChain API
- BitIndex API
- Your own indexer node

## Recommended Approach

**For most blocks (<100k tx):**
- Use current `get/1` function
- Works fine with increased timeouts

**For mega-blocks (>100k tx):**
1. Store header only (already done)
2. Use chunked fetching if needed:
   ```elixir
   Bitblocks.Sync.get_block_transactions_chunked(block_height, chunk_size: 1000)
   ```
3. Or skip entirely and rely on external services

## Memory Considerations

**With 2GB RAM:**
- Can handle blocks up to ~500k transactions
- Beyond that, risk OOM

**Response Size Estimates:**
- 10k transactions: ~1-2MB
- 100k transactions: ~10-20MB
- 1M transactions: ~200-400MB
- 2M transactions: ~500-800MB

## Future Improvements

### 1. Streaming JSON Parser

Instead of loading entire response into memory:

```elixir
# Use a streaming JSON parser
{:ok, stream} = HTTPoison.get(url, headers(), stream_to: self())

# Process JSON as it arrives
Jaxon.Stream.from_enumerable(stream)
|> Jaxon.Stream.query([:root, "tx", :all])
|> Stream.chunk_every(1000)
|> Enum.each(&process_tx_chunk/1)
```

### 2. Background Job Processing

```elixir
# Queue large block processing
Oban.insert(SyncLargeBlockJob.new(%{block_height: 643055}))

# Process in background with retries
defmodule SyncLargeBlockJob do
  use Oban.Worker, queue: :large_blocks, max_attempts: 3

  def perform(%{args: %{"block_height" => height}}) do
    # Process in chunks with retries
  end
end
```

### 3. Compression

Some Bitcoin nodes support gzip compression:

```elixir
headers = [
  {"Accept-Encoding", "gzip"},
  {"Content-Encoding", "gzip"}
]
```

### 4. Dedicated Large Block Handler

```elixir
defmodule Bitblocks.Sync.LargeBlockHandler do
  def sync_large_block(block_height) do
    # 1. Get block header only
    # 2. Fetch tx IDs in chunks
    # 3. Process transactions in parallel batches
    # 4. Save progress to resume on failure
  end
end
```

## Monitoring

**Watch for large block issues:**

```bash
# Find blocks with many transactions — attach a remote console to the running release
/app/bin/bitblocks remote

# In IEx
import Ecto.Query
alias Bitblocks.{Repo, Chain.Block}

# Find blocks with >100k transactions
from(b in Block,
  where: fragment("array_length(?, 1) > 100000", b.tx),
  select: {b.height, fragment("array_length(?, 1)", b.tx)}
)
|> Repo.all()

# Check which blocks failed to sync
from(b in Block,
  where: b.sync_state == "header_synced",
  select: {b.height, fragment("array_length(?, 1)", b.tx)}
)
|> Repo.all()
```

## Configuration

Current settings in `config.exs`:

```elixir
config :bitblocks,
  # Limit transactions fetched per block
  max_transactions_per_block: 1000,
  # Whether to fetch full transaction details
  fetch_full_transactions: false
```

Add if needed:

```elixir
config :bitblocks,
  # Skip blocks larger than this
  max_block_size_transactions: 100_000,
  # Chunk size for large block processing
  large_block_chunk_size: 1000
```

## Summary

**Current Status:**
- ✅ Handles blocks up to 100k transactions well
- ✅ Skips blocks >100k to avoid crashes
- ✅ Increased timeouts for large responses
- ❌ Cannot fully process mega-blocks (>1M transactions)

**When You Hit a Mega-Block:**
1. Header is already synced (has tx IDs)
2. Transaction details skipped
3. Can process later if needed using chunking

**Next Steps:**
1. Identify if you need full transaction data for mega-blocks
2. If yes, implement chunked processing
3. If no, leave as header-only (recommended)
