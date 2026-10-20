# Payment Channels for Metered Access

How to charge satoshis per API request without an on-chain transaction for each one.

## The Problem

BSV transaction fees are low (~0.05 sat/byte, ~$0.00001 per tx) but not zero.
If every API request required an on-chain payment, the tx fee would exceed the cost of the data.
A tx lookup might cost 0.01 sats to serve — but the on-chain payment to pay for it costs 50 sats.

## The Solution: Payment Channels

A payment channel is two on-chain transactions that bracket thousands of off-chain payments.

```
On-chain tx 1: OPEN channel (client locks funds)
     │
     │  Off-chain: request 1 → update balance → serve response
     │  Off-chain: request 2 → update balance → serve response
     │  Off-chain: request 3 → update balance → serve response
     │  ...
     │  Off-chain: request 10,000 → update balance → serve response
     │
On-chain tx 2: CLOSE channel (settle final balances)
```

Two on-chain transactions total.
10,000 API calls in between.
Each off-chain update is just a signed message — no mining, no fees, instant.

## How It Works

### Opening

The client creates a transaction with two outputs:

```
Output 0: 100,000 sats → 2-of-2 multisig (client + bitblocks)
Output 1: change back to client
```

The 100,000 sats are locked in a multisig — neither party can spend them alone.
This is the channel capacity: the client has pre-paid up to 100,000 sats of API access.

### Using

Each API request includes a signed payment update:

```
GET /tx/f4184fc5...
X-Channel-Id: <channel txid>
X-Payment: <signed update: client=99,990 bitblocks=10>
```

The "payment" is a signed Bitcoin transaction that spends the multisig:
- Output 0: 99,990 sats → client
- Output 1: 10 sats → bitblocks

But this transaction is NOT broadcast. It's just held by bitblocks as proof of payment.
Each subsequent request increments bitblocks' share:

```
Request 1:    client=99,990  bitblocks=10
Request 2:    client=99,980  bitblocks=20
Request 100:  client=99,000  bitblocks=1,000
Request 10000: client=0      bitblocks=100,000
```

Each update replaces the previous one.
Bitblocks only needs to keep the latest (highest-payment) update.

### Closing

Either party can close the channel at any time by broadcasting the latest update.
The on-chain transaction settles the final balances.

If the client disappears, bitblocks broadcasts the last update it received.
If bitblocks disappears, the client can reclaim funds after a timeout (using a timelocked refund tx created at channel open).

### Dispute Resolution

What if the client broadcasts an old state (one where they had more money)?

Two approaches:

**1. Simple (trust-based):** bitblocks trusts the client won't cheat because
   the amounts are small and the reputational cost is high.
   This is fine for API metering where individual payments are fractions of a cent.

**2. Enforceable (covenant-based):** use sCrypt covenants to enforce that only the
   latest state can be spent. Each update includes a sequence number; the contract
   only allows spending if the sequence number is higher than any previously seen.
   This is the Lightning Network approach, adapted for BSV.

For API metering, option 1 is sufficient. The maximum loss is the channel capacity
(e.g. $0.50), and cheating is detectable and attributable.

## Bitblocks Implementation

### Client Flow

```python
# 1. Open a channel (one-time, on-chain)
channel = bitblocks.open_channel(
    capacity_sats=100_000,
    client_pubkey=my_key.pub
)

# 2. Make requests (off-chain, instant)
for txid in txids_i_need:
    payment = channel.sign_update(cost=10)  # 10 sats per lookup
    response = requests.get(
        f"https://bitblocks.app/tx/{txid}",
        headers={"X-Payment": payment}
    )

# 3. Close when done (on-chain)
bitblocks.close_channel(channel.id)
```

### Server Flow

```elixir
# In the endpoint plug pipeline:
# 1. Check X-Payment header
# 2. Verify signature
# 3. Verify payment amount >= cost for this endpoint
# 4. Store latest update (replaces previous)
# 5. Serve the response

# Periodic settlement:
# - Close channels that have been inactive for 24h
# - Broadcast the latest update to collect payment
```

### API Endpoints

```
POST /api/v1/channels/open
  Body: {capacity_sats, client_pubkey}
  Returns: {channel_id, funding_address, multisig_script}

GET  /api/v1/channels/:id/status
  Returns: {balance_client, balance_server, updates_count}

POST /api/v1/channels/:id/close
  Broadcasts the latest state on-chain
```

## Cost Per Endpoint

| Endpoint | Cost (sats) | Rationale |
|----------|-------------|-----------|
| `GET /tx/:txid` | 1 | Cached, cheap to serve |
| `GET /tx/:txid` (raw hex) | 2 | Larger payload |
| `GET /tx/:txid/proof` | 5 | Requires node RPC call |
| `GET /blocks/:id` | 1 | Cached |
| `GET /addresses/:addr/utxos` | 10 | Proxied to WoC, more expensive |
| `GET /mining/work` | 0 | Free — we want hashers |
| `GET /stream/blocks` | 1/event | SSE, pay per event received |

At current BSV prices (~$50), 100,000 sats = $0.05.
A developer could make 100,000 tx lookups for five cents.

## Comparison to Alternatives

| Model | Pros | Cons |
|-------|------|------|
| API key + fiat subscription | Familiar, easy to implement | Excludes unbanked, minimum viable price is high |
| Per-request on-chain payment | Truly trustless | Tx fee exceeds payment value |
| Payment channel | Low friction, near-zero cost | Requires channel management |
| Prepaid credits (on-chain purchase, off-chain spend) | Simple, no channel complexity | Requires trust for credit balance |

## Implementation Priority

1. **Fiat first** — API keys with rate limits. Already partially in place.
2. **Prepaid credits** — buy credits with a BSV payment, spend them per-request.
   Simplest Bitcoin-native model. No channel complexity.
3. **Payment channels** — full bidirectional channels for high-volume consumers.
   Only worth building when there's demand for millions of requests.

The prepaid credit model is the sweet spot for launch:
- Client sends BSV to a deposit address
- Bitblocks credits their account (identified by address or API key)
- Each request decrements the balance
- When balance hits zero, requests are rate-limited to free tier

No channel state management. No multisig. No dispute resolution.
Just a deposit address and a balance counter.
The payment channel is the upgrade path when volume justifies the complexity.

## Relation to Mining Proxy

The mining proxy already has a reward-split model: 90% to hasher, 10% to platform.
This is conceptually the same as payment channels — work is done off-chain (hashing),
settlement happens on-chain (coinbase tx), and the split is pre-committed in the template.

The difference: mining splits happen per-block (rare, high-value).
API payments happen per-request (frequent, low-value).
Payment channels bridge that gap.
