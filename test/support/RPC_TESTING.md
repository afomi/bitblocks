# RPC Testing Guide

This guide explains how to use RPC stubs in tests to avoid requiring a live Bitcoin node.

## Overview

The test suite includes two components for stubbing RPC calls:

1. **RpcStub** - Manages stub state and provides helper functions for setting up stubs
2. **BitcoinsvCliMock** - Mock implementation of `BitcoinsvCli` that returns stubbed responses

## Quick Start

### Option 1: Using RpcStub in Individual Tests

```elixir
defmodule MyTest do
  use BitblocksWeb.ConnCase
  alias BitblocksWeb.RpcStub

  setup do
    RpcStub.setup()  # Sets up default stubs
    :ok
  end

  test "my test", %{conn: conn} do
    # Customize a specific stub if needed
    RpcStub.stub_getblockchaininfo(%{
      "blocks" => 123,
      "headers" => 123
    })

    # Your test code here
    conn = get(conn, ~p"/status")
    assert html_response(conn, 200) =~ "123"
  end
end
```

### Option 2: Using BitcoinsvCliMock Globally

In `config/test.exs`, configure the app to use the mock:

```elixir
# Use mock for all Bitcoin RPC calls in tests
config :bitblocks, :bitcoinsv_cli, BitcoinsvCliMock
```

Then in your application code, use the configured module:

```elixir
# Instead of:
BitcoinsvCli.getblockchaininfo()

# Use:
cli_module = Application.get_env(:bitblocks, :bitcoinsv_cli, BitcoinsvCli)
cli_module.getblockchaininfo()
```

## Available Stubs

### getblockchaininfo

```elixir
RpcStub.stub_getblockchaininfo(%{
  "chain" => "main",
  "blocks" => 850000,
  "headers" => 850000,
  "bestblockhash" => "00000000...",
  "difficulty" => 1234567890.123456
})
```

### getblockhash

```elixir
# Stub a specific height
RpcStub.stub_getblockhash(100, "000000007bc154e0fa7ea32218...")

# Use auto-generated hash
RpcStub.stub_getblockhash(100)
```

### getblock

```elixir
# Stub with custom response
RpcStub.stub_getblock("000000007bc154...", 1, %{
  "hash" => "000000007bc154...",
  "height" => 100,
  "tx" => ["txid1", "txid2"]
})

# Use default fixture
RpcStub.stub_getblock("000000007bc154...")
```

### getrawtransaction

```elixir
# Stub a specific transaction
RpcStub.stub_getrawtransaction("8c14f0db3df150...", 1, %{
  "txid" => "8c14f0db3df150...",
  "vin" => [...],
  "vout" => [...]
})

# Use default fixture
RpcStub.stub_getrawtransaction("8c14f0db3df150...")
```

### Batch Operations

```elixir
# Stub batch block hash requests
heights = [0, 1, 2, 3]
hashes = ["hash0", "hash1", "hash2", "hash3"]
RpcStub.stub_batch_getblockhash(heights, hashes)

# Stub batch transaction requests
txids = ["txid1", "txid2", "txid3"]
RpcStub.stub_batch_getrawtransaction(txids)
```

## Fixtures

Pre-defined fixture files are available in `test/fixtures/rpc/`:

- `getblockchaininfo.json` - Default blockchain info response
- `getblockhash.json` - Common block hashes (genesis, block 100, etc.)
- `getblock_verbosity_1.json` - Block with transaction IDs
- `getrawtransaction.json` - Sample coinbase transaction

### Creating Custom Fixtures

1. Create a new JSON file in `test/fixtures/rpc/`:

```json
{
  "custom_field": "custom_value"
}
```

2. Load it in your test:

```elixir
fixture = File.read!("test/fixtures/rpc/my_custom_fixture.json")
  |> Jason.decode!()

RpcStub.stub_getblock("hash", 1, fixture)
```

## Default Stubs

When you call `RpcStub.setup()`, the following defaults are automatically stubbed:

- **getblockchaininfo**: Returns fixture with 850,000 blocks
- **getblockhash(0)**: Genesis block hash
- **getblockhash(100)**: Block 100 hash
- **getblockhash(1000)**: Block 1000 hash
- **getblock**: Sample block with 4 transactions

## Clearing Stubs

```elixir
# Clear all stubs
RpcStub.clear()

# Stop the stub server
RpcStub.stop()
```

## Direct Mock Usage

You can also use `BitcoinsvCliMock` directly without setup:

```elixir
# These will work even without RpcStub.setup()
blockchain_info = BitcoinsvCliMock.getblockchaininfo()
hash = BitcoinsvCliMock.getblockhash(100)
block = BitcoinsvCliMock.getblock(hash)
```

The mock provides sensible defaults for all methods.

## Testing RPC Cache

To test the RPC cache with stubs:

```elixir
test "caches getblockchaininfo" do
  RpcStub.setup()

  # First call - should invoke RPC
  info1 = Bitblocks.RpcCache.get_blockchain_info()

  # Verify it cached correctly
  events = Bitblocks.RpcCache.get_blockchain_info_events(limit: 1)
  assert length(events) == 1

  # Second call - should use cache (no new event)
  info2 = Bitblocks.RpcCache.get_blockchain_info()
  events = Bitblocks.RpcCache.get_blockchain_info_events(limit: 10)
  assert length(events) == 1

  # Both should return same data
  assert info1 == info2
end
```

## Best Practices

1. **Always call `RpcStub.setup()` in test setup** - This ensures consistent state
2. **Customize only what you need** - Default stubs work for most cases
3. **Use fixtures for complex data** - Keep tests readable by using fixture files
4. **Clear stubs between tests** - The setup callback does this automatically
5. **Test both success and error cases** - Stub error responses when needed:

```elixir
RpcStub.stub_getblockchaininfo({:error, :connection_failed})
```

## Troubleshooting

### "RpcStub not started"

Make sure you call `RpcStub.setup()` in your test setup:

```elixir
setup do
  RpcStub.setup()
  :ok
end
```

### "No stub for X"

Either:
1. Add the stub manually: `RpcStub.stub_getblock("hash")`
2. Or the mock will return a sensible default automatically

### "Fixture not found"

Check that the fixture file exists in `test/fixtures/rpc/` and has valid JSON.

## Examples

See `test/bitblocks_web/rpc_stub_test.exs` for comprehensive examples of using the stub system.
