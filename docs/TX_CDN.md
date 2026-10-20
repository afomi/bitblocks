# Transaction CDN — Immutable Content Distribution

Every Bitcoin transaction is immutable and content-addressable by its txid.
This makes the chain a perfect origin for a global CDN.

## The Insight

| CDN property | Bitcoin tx |
|-------------|-----------|
| Content-addressable | txid = SHA256d(tx) |
| Immutable | Once confirmed, never changes |
| Cache invalidation | Not needed — content is permanent |
| Cache key | txid (64-char hex, globally unique) |
| Cache hit rate | 100% after first fetch (content never expires) |

Traditional CDNs spend enormous effort on cache invalidation.
A transaction CDN has **zero invalidation** — `Cache-Control: immutable` on every response, forever.

## Architecture

```
Client request: GET /tx/f4184fc596403b9d...
         │
         ▼
┌─────────────────────┐
│  CloudFront / CDN   │  ← cache-control: public, immutable, max-age=31536000
│  (edge locations)   │
└────────┬────────────┘
         │ cache miss
         ▼
┌─────────────────────┐
│  S3 bucket          │  ← one object per txid
│  tx/f4184fc5...     │     raw tx hex or parsed JSON
└────────┬────────────┘
         │ miss (not yet cached)
         ▼
┌─────────────────────┐
│  Bitblocks origin   │  ← fetches from node, writes to S3, returns
│  /api/v1/txs/:txid  │
└─────────────────────┘
```

## S3 Object Layout

```
s3://bitblocks-txs/
  raw/{txid}          ← raw hex (the canonical form)
  json/{txid}.json    ← parsed: inputs, outputs, protocols
  proof/{txid}.json   ← merkle proof anchored to block header
```

Each object is write-once, read-forever.
S3 costs: ~$0.023/GB/month for storage, $0.09/GB for transfer.
A raw transaction averages ~250 bytes. 1M transactions = ~250 MB = ~$0.006/month to store.

## Metering

Two models, not mutually exclusive:

### 1. S3-native metering (fiat)

Standard AWS pricing. Free tier for casual use, pay-per-GB for heavy consumers.
CloudFront handles rate limiting and geographic distribution.

```
Free:       1,000 tx lookups/day
Pro:        100,000/day — $29/mo
Enterprise: unlimited — custom pricing
```

### 2. Satoshi-metered (Bitcoin-native)

Each request costs a fraction of a satoshi.
The client includes a micropayment in the request header.
Bitblocks verifies the payment before serving the response.

```
GET /tx/f4184fc5...
X-Payment: <signed satoshi payment proof>
```

This is the 402 Payment Required model that HTTP was designed for but never used.
BSV's sub-cent transaction fees make it viable.

Implementation options:
- **Payment channel**: client opens a channel, streams micropayments per request
- **Prepaid credits**: client buys credits (on-chain tx), spends them per request
- **Per-request payment**: each request includes a nano-payment (expensive in tx fees)

Payment channels are the most efficient — one on-chain tx opens the channel,
thousands of off-chain updates meter usage, one on-chain tx settles.

## Why This Matters

### For developers
`GET https://cdn.bitblocks.app/tx/{txid}` — fast, global, permanent.
No node needed. No RPC. Just HTTP with a CDN in front.
Build apps against a URL pattern, not a protocol.

### For the chain
As BSV grows to 20+ TB, running a full node becomes expensive.
A CDN lets lightweight clients access individual transactions without syncing the chain.
The node is the authority. The CDN is the distribution layer.

### For the economics
The data is public and immutable — perfect for caching.
The value-add is availability, speed, and convenience.
Metering (fiat or satoshi) pays for the infrastructure.

## Relationship to Data Packs

Data packs (tools/data_pack_exporter) are bulk exports — entire block ranges as JSONL files.
The CDN is individual lookups — one transaction at a time, globally distributed.

They complement each other:
- **Data packs**: "give me blocks 600,000–700,000" (bulk, offline)
- **CDN**: "give me transaction f4184fc5..." (individual, real-time)

## Implementation Path

1. **S3 bucket** — create `bitblocks-txs` with lifecycle rules (no expiry needed)
2. **Origin function** — on cache miss, fetch from node, write to S3, return
3. **CloudFront** — put in front of S3 with `Cache-Control: immutable`
4. **API endpoint** — `GET /cdn/tx/:txid` that checks S3 first, node second
5. **Metering** — start with fiat (API keys + rate limits), add satoshi payments later

The S3 write-through can happen as part of the existing tx backfill.
When `FetchTransactionsWorker` stores a transaction in Postgres, it also writes to S3.
The CDN is populated automatically as the chain is indexed.
