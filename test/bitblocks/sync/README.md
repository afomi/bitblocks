# Sync Pipeline Tests

This directory contains tests for the concurrent blockchain synchronization pipeline.

## Test Files

### `transaction_fetcher_test.exs`

Tests the TransactionFetcher GenStage consumer that:
- Fetches full block data from Bitcoin node
- Enriches blocks with transaction details
- Handles errors gracefully
- Processes multiple blocks concurrently

### `pipeline_test.exs`

Integration tests for the complete sync pipeline that verify:
- Block syncing to database
- Progress tracking
- Backpressure and concurrency
- Error handling
- PubSub event broadcasting
- Database integration

## Running Tests

### Regular Unit Tests

By default, integration tests are excluded (they require a Bitcoin node):

```bash
mix test
```

### Integration Tests (Requires Bitcoin Node)

To run integration tests, you need a configured Bitcoin SV node:

```bash
# Set environment variables
export BITCOIN_NODE_URL=http://localhost:8332
export BITCOIN_NODE_RPC_USERNAME=your_username
export BITCOIN_NODE_RPC_PASSWORD=your_password

# Run integration tests
mix test --only integration
```

Or run all tests including integration:

```bash
mix test --include integration
```

### Run Specific Test Files

```bash
# TransactionFetcher tests only
mix test test/bitblocks/sync/transaction_fetcher_test.exs --include integration

# Pipeline tests only
mix test test/bitblocks/sync/pipeline_test.exs --include integration
```

## Test Architecture

### Integration Tests

These tests are marked with `@moduletag :integration` and require:
- A running Bitcoin SV node
- Network access
- Real RPC calls

They test the actual integration with the Bitcoin network.

### Unit Tests (Future)

For faster testing without a Bitcoin node, you could add unit tests using mocks:

```elixir
# Add to mix.exs
{:mox, "~> 1.0", only: :test}
```

Then create mocks for `BitcoinsvCli` to test logic without network calls.

## Test Data

Tests use Bitcoin block 100,000 as a reference block:
- Well-known, stable block
- Contains 4 transactions
- Hash: `000000000003ba27aa200b1cecaad478d2b00432346c3f1f3986da1afd33e506`

## Performance Expectations

Pipeline integration tests should demonstrate:
- **Concurrent processing**: 5 blocks synced faster than sequential (< 10 seconds)
- **Backpressure**: No memory explosions or crashes under load
- **Error resilience**: Pipeline continues after RPC errors

## Troubleshooting

### Bitcoin Node Connection Errors

```
Bitcoin RPC Error: BITCOIN_NODE_URL is not configured
```

**Solution**: Set environment variables before running tests.

### Test Timeouts

If tests timeout, your Bitcoin node may be slow or unreachable:
- Check node is running: `bitcoin-cli getblockchaininfo`
- Increase timeout in test if needed
- Verify network connectivity

### Database Conflicts

If tests fail with database errors:
```bash
# Reset test database
mix ecto.reset
```
