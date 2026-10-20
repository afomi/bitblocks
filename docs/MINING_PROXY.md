# Mining Proxy — Elixir Block Template Server

A lightweight alternative to ckpool.
An Elixir process that serves block templates and accepts solutions.
No C dependencies, no separate daemon — runs inside the bitblocks application.

## Architecture

```
┌─────────────────────────────────────────────┐
│  Bitblocks (Elixir)                         │
│                                             │
│  ┌───────────────┐    ┌──────────────────┐  │
│  │ BSV Node      │    │ MiningProxy      │  │
│  │ (RPC)         │◀──▶│ (GenServer)      │  │
│  │               │    │                  │  │
│  │ getblock-     │    │ • Polls for new  │  │
│  │   template    │    │   templates      │  │
│  │ submitblock   │    │ • Tracks active  │  │
│  │               │    │   work units     │  │
│  └───────────────┘    │ • Validates      │  │
│                       │   solutions      │  │
│                       └────────┬─────────┘  │
│                                │             │
│                       ┌────────┴─────────┐  │
│                       │ HTTP/WebSocket   │  │
│                       │ Endpoint         │  │
│                       └────────┬─────────┘  │
└────────────────────────────────┼─────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │  Remote Hashers         │
                    │  (ASICs, GPUs, rentals) │
                    └─────────────────────────┘
```

## Why Elixir Instead of ckpool

| ckpool | Elixir proxy |
|--------|-------------|
| C daemon, separate process | Runs inside bitblocks OTP app |
| Stratum v1 TCP protocol | HTTP/WebSocket — or stratum, your choice |
| Full pool with share accounting | Minimal: template + submit, nothing else |
| Battle-tested, complex | Simple, inspectable, ~200 lines |

The insight: you don't need a pool.
You need two endpoints and a polling loop.

## API

### Get current work

```
GET /api/v1/mining/work
```

Returns the current block template as a work unit:

```json
{
  "work_id": "a1b2c3",
  "header": {
    "version": 536870912,
    "prev_hash": "000000000000000003a4...",
    "merkle_root": "7f8e9d...",
    "timestamp": 1712956800,
    "bits": "180e571c",
    "nonce": 0
  },
  "target": "00000000000e571c...",
  "coinbase_tx": "01000000010000...",
  "height": 926500
}
```

The hasher takes `header`, iterates `nonce` (and `timestamp` within allowed range),
and checks if `SHA256d(header) < target`.

### Submit solution

```
POST /api/v1/mining/submit
```

```json
{
  "work_id": "a1b2c3",
  "nonce": 2083236893,
  "timestamp": 1712956805
}
```

The proxy:
1. Reconstructs the full block header with the submitted nonce/timestamp
2. Verifies the hash meets the target (cheap, instant)
3. If valid, calls `submitblock` on the node
4. Returns the result

```json
{
  "status": "accepted",
  "block_hash": "000000000000000001f2..."
}
```

Or:

```json
{
  "status": "rejected",
  "reason": "hash does not meet target"
}
```

## GenServer Design

```elixir
defmodule Bitblocks.MiningProxy do
  use GenServer

  # State:
  # - current_template: the latest block template from the node
  # - work_id: unique ID for the current template (changes on each update)
  # - coinbase_address: where the block reward goes
  # - poll_interval: how often to refresh the template (default 5s)

  # On init:
  #   1. Call getblocktemplate on the node
  #   2. Store the template
  #   3. Schedule next poll

  # On poll:
  #   1. Call getblocktemplate
  #   2. If merkle_root changed → new work_id, broadcast to connected hashers
  #   3. Schedule next poll

  # On submit:
  #   1. Verify work_id matches current (or recent) template
  #   2. Reconstruct header with submitted nonce
  #   3. SHA256d(header) — verify hash < target
  #   4. If valid → submitblock to node
  #   5. Return result
end
```

## What the Hasher Needs to Do

The hasher is dead simple — any language, any hardware:

```python
import hashlib, struct, requests

# Get work
work = requests.get("https://bitblocks.app/api/v1/mining/work").json()

header = work["header"]
target = int(work["target"], 16)

# Build 80-byte header
raw = struct.pack("<I", header["version"])
raw += bytes.fromhex(header["prev_hash"])[::-1]  # little-endian
raw += bytes.fromhex(header["merkle_root"])[::-1]
raw += struct.pack("<I", header["timestamp"])
raw += struct.pack("<I", int(header["bits"], 16))

# Iterate nonces
for nonce in range(2**32):
    attempt = raw + struct.pack("<I", nonce)
    hash = hashlib.sha256(hashlib.sha256(attempt).digest()).digest()
    if int.from_bytes(hash[::-1], 'big') < target:
        requests.post("https://bitblocks.app/api/v1/mining/submit", json={
            "work_id": work["work_id"],
            "nonce": nonce,
            "timestamp": header["timestamp"]
        })
        break
```

That's the entire miner.
30 lines of Python.
Obviously CPU-speed is useless — but the same logic runs on ASICs via firmware.

## Implementation Steps

1. **`BitcoinsvCli.getblocktemplate/0`** — add RPC wrapper (like `getmempoolinfo`)
2. **`Bitblocks.MiningProxy`** — GenServer that polls for templates
3. **`/api/v1/mining/work`** — GET endpoint, returns current work
4. **`/api/v1/mining/submit`** — POST endpoint, accepts solutions
5. **Coinbase address config** — where the block reward goes

The whole thing is ~200 lines of Elixir.
No C code, no stratum, no external daemons.
HTTP in, HTTP out.

## Considerations

- **Stale work**: hashers must check `work_id` — if the template changed, their work is stale.
  WebSocket would let you push new work instantly instead of hashers polling.
- **Mempool**: your node needs a mempool for templates with transactions.
  Without it, templates contain only the coinbase tx (valid but no fee revenue).
- **Latency**: found blocks must reach the network fast. Your node handles this via `submitblock`.
- **Security**: the submit endpoint should be authenticated — you don't want anyone
  submitting bad blocks through your node.
- **No share accounting**: this is solo mining only. No payout splitting, no difficulty
  adjustment for individual hashers. If you want pool features, that's a bigger project.

## Why This Is Interesting

The standard mining stack (ckpool, stratum, ASIC firmware) is 20+ years of accumulated C code.
It works but it's opaque.

An Elixir proxy with HTTP endpoints makes mining **inspectable**.
You can see the template, verify the math, submit a solution, and watch it propagate —
all through a web interface.

For bitblocks as an educational tool, this demystifies mining.
For bitblocks as infrastructure, this is a path to becoming a network participant, not just an observer.
