# Bitcoin RPC Fixtures

This directory contains cached responses from a Bitcoin SV node for testing purposes.

## Purpose

These fixtures allow tests to run without requiring a live Bitcoin SV node connection, making tests:
- **Fast** - No network calls
- **Reliable** - Consistent data
- **Portable** - Work in CI/CD environments

## Refreshing Fixtures

To update fixtures with latest API responses:

```bash
# Refresh all fixtures
REFRESH_FIXTURES=true mix test

# Or use the dedicated mix task
mix test.refresh_fixtures
```

## API Contract Validation

Periodically verify that the Bitcoin SV RPC API hasn't changed:

```bash
# Run API contract validation tests (requires live node)
REFRESH_FIXTURES=true mix test --only api_contract
```

## Files

- `block_100000_raw.json` - Raw hex for block 100,000
- `block_100000_verbose.json` - Full block data with transactions
- `tx_100000_coinbase.json` - Coinbase transaction from block 100,000
- `tx_100000_regular.json` - Regular transaction from block 100,000

## Test Data

All fixtures use block 100,000 on Bitcoin SV mainnet:
- **Hash**: `000000000003ba27aa200b1cecaad478d2b00432346c3f1f3986da1afd33e506`
- **Height**: 100,000
- **Transactions**: 4
- **Date**: December 29, 2010

This block was chosen because it's stable, well-known, and unlikely to change.
