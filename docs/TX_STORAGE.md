# Transaction storage: every tx in the CDN, metadata in Postgres

Status: steps 1 and 2 built (2026-11-07), behind config; steps 3 to 6 proposed.
Decided by Ryan: every tx is in the CDN; every tx has its metadata in the database; very large raw bodies stay out of the database.
The rest is the plan below; the open choices are marked.
What is built, and what infra still has to do, is in [Built](#built-steps-1-and-2).

## Why now

On 2026-11-04 the bitblocks database was 65 GB for about 10.6 million txs, growing about 11 GB a day, on a shared burstable instance that ran out of CPU credits.
It is moving to its own instance (`bitblocks-db`, db.m7g.large, gp3 autoscaling to 1 TB), which buys time, not a shape that holds the chain.
The chain has 7,524,524,627 txs (`sum(num_tx)` over 973,549 headers, 2026-11-05).
A `transactions` row averaged 3,125 bytes in a 0.2% sample of the rows stored so far: `raw` 943, `outputs` 893, `inputs` 690, `input_txids` 136.
So `raw`, `inputs` and `outputs` are about 80% of a row, and rows like these for every tx would be about 24 TB before indexes.
Measured on stored early-chain rows (height below 200,000), a `transactions` row holds the same tx about twice:

| Part of the row | Share of row bytes |
|---|---|
| `raw` (hex) | about 30% |
| `inputs` and `outputs` (decoded JSON, including scriptSig and script hex and asm) | about 41% |
| everything else (txid, tag arrays, hashes, tallies) | about 29% |

The GIN indexes come on top of that.
Hex doubles the bytes; the decoded JSON repeats the scripts the raw bytes already carry.

## The shape

**1. Every tx in the CDN, packed by block.**
The sync already fetches each block of up to 32 MB as one verified raw block (`Chain.RawBlock`).
That file is written to S3 as it is, one object per block: `blocks/<height>-<hash>.bin`, immutable.
Each tx row records where its bytes sit: `raw_offset` and `raw_length` within its block's object.
A tx in a block over 32 MB is handled as it comes (Ryan, 2026-11-05): the sync stores it in its row through the per-tx path, and it stays there until its bytes are in the store.
Nothing is built ahead of those blocks; chunk objects remain an option if they turn out to need one.
One upload per block costs about $5 for every million blocks; one upload per tx would cost about $5,000 for every billion txs.

**2. One URL per tx, served once and cached forever.**
`https://cdn.bitblocks.app/tx/<txid>` stays the address.
CloudFront forwards a miss to a small bitblocks endpoint, which looks up the tx's block and offset, makes one ranged S3 read, checks the bytes hash to the txid, and answers `immutable`.
A tx is read from the database at most once per CloudFront edge; after that the edge serves it.
The existing per-tx objects (`raw/<txid>`, about 21,000 from the collection syncs) keep working and are read first.

**3. Metadata for every tx in Postgres.**
Kept on every row: txid, block hash and height, position in the block, version, counts, sat tallies (in, out, fee, burned), coinbase, protocols, output types, addresses, script and template hashes, AIP signers, `raw_offset` and `raw_length`, and `blob_stored_at`.
Inputs keep the outpoint they spend (`input_txids`, plus `spend_index`); outputs keep value, type, address and script hash.
Not kept: the scriptSig and script hex and asm inside `inputs` and `outputs`, which are parsed from the raw bytes when a page needs them (`Chain.RawTx`).

**4. Raw bytes in Postgres only when small.**
`raw` stays in the row for txs up to 1 MB, `Transaction.raw_in_db_max_bytes/0` (Ryan, 2026-11-05).
Above that the row keeps its metadata and an empty `raw`, and every reader gets the bytes through `TxStore.raw/1`, which already falls back from the database to the store.
Why 1 MB for now: a 5% sample of blocks 900,000 and up (197,573 rows) has p99 at 4.3 KB and p99.9 at 370 KB, and 0.02% of rows over 1 MB hold 36% of raw bytes, against 0.19% and 77% at 100 KB.
The sample covers only what was stored at those heights, so check the number again when the sync gets there.
The cap takes effect with step 5 below; until then every row keeps its `raw`.

Every row says what it weighs and where its bytes are:

- `size_bytes` is the tx's size, from its raw bytes.
- `raw_in_db` is true while the full bytes sit in the row, and false once they live only in the store.
  It records where the bytes are, not the threshold, so `size_bytes > 1000000 AND raw_in_db` is exactly the rows still to move.
- The store keeps every tx whatever the threshold, so changing the threshold only moves rows: lower it and more rows trim, raise it and rows refill from the store.
  A change to the number is a database change too: `raw_in_db_max_bytes/0`, the rows it moves, and any index that names it.

A raw body is never dropped from a row before its block object is written and verified (`blob_stored_at` set and the bytes re-read).
Stored as bytes (`bytea`), not hex, when the column is next touched: half the size for what stays.

## Order of work

1. Write each completed block's raw bytes to S3 from the sync loop, with offsets on the rows, and verify every write.
   `Release.tx_store_reconcile/3` already counts what's missing per block range, so this is checkable from day one.
2. The `/tx/<txid>` origin endpoint behind CloudFront, reading the per-block object by range.
3. Route every reader of `raw` through `TxStore.raw/1`: about 12 modules today, including the tx page, `/content`, tokens, collections, the tx pipeline backfills and `ChainFlow`.
4. Readers of the decoded `inputs` and `outputs` (about 20 modules) move to parsed raw or to the kept metadata columns, one at a time, each with its tests.
5. Then stop writing the hex and asm into `inputs` and `outputs`, and stop keeping `raw` above the threshold.
6. A backfill for blocks already synced: write their block objects, then trim their rows, in ranges, with a dry run first, like the tally backfills.

Steps 1 and 2 add storage without removing anything; nothing leaves the database until steps 3 to 5 are done and tested.

## Built: steps 1 and 2

**The block object.**
When the block job (`FetchTransactionsWorker`) completes a block it fetched whole (`Chain.RawBlock`, up to 32 MB), `Bitblocks.TxStore.BlockObject.store/3` writes the block's exact bytes to `blocks/<height>-<hash>.bin`.
The write is then read back: the object's size must equal the block's, and its first 80 bytes (a ranged read) must hash to the block hash.
Only then, in one transaction, does each of the block's tx rows get `raw_offset` and `raw_length`, and the block get `raw_object_stored_at` (with `updated_at`).
A failed or unverified write is logged and leaves the stamp nil; the block stays `completed` and the sync moves on.
Blocks over 32 MB take the per-tx path and get no object; their txs keep `raw` in the row.

**Finding what's missing.**
`Release.store_block_objects(from, to)` counts completed blocks without an object; with `apply: true` it refetches each from the node (REST, else `getblock(hash, 0)`), writes and verifies it.
It is a dry run by default, takes at most `limit:` blocks (500) per call, lowest first, and stops after `max_failures:` (3) failures in a row, printing why, so a node refusing RPC is a clear stop rather than a long list of errors.
Run it again to carry on; this is also how blocks synced before step 1 get their objects (step 6's first half).

```bash
bin/bitblocks rpc 'Bitblocks.Release.store_block_objects(0, 9_999)'
bin/bitblocks rpc 'Bitblocks.Release.store_block_objects(0, 9_999, apply: true)'
```

**Reading a tx back.**
`TxStore.raw/1` reads the database's `raw`, then the tx's own object `raw/<txid>`, then a ranged read of its block's object at `raw_offset` and `raw_length`.
Bytes from the store must hash to the txid, or the answer is an error.
Each adapter has `get_range/3`: S3 with an HTTP Range GET, Local with a positioned file read.

**The origin endpoint.**
`GET /api/v1/txs/:txid/raw` answers the tx's bytes as `application/octet-stream` with `x-content-type-options: nosniff`.
The bytes are hashed on every response; only bytes that hash to the txid are served, with `cache-control: public, max-age=31536000, immutable`.
Errors (400 not a txid, 404 not held, 500 held bytes that don't hash, 503 store unreadable) are `no-store`, so a tx we don't hold yet is never cached as missing.
It is public like the other tx reads, outside the JSON-only `:api` pipeline, and counted by the endpoint-wide rate limiter (`RATE_LIMIT_PER_MINUTE` per IP).
This is the origin CloudFront sits in front of: `https://cdn.bitblocks.app/tx/<txid>` maps to `/api/v1/txs/<txid>/raw` on a miss.

**Counting it.**
`Release.tx_store_reconcile/3` now counts block objects stored and missing (with those over the raw-block cap named), and counts a tx as in the store when it has its own object or is located in a stamped block object.
`block_objects_missing` is a gap like any other; its sample re-reads located txs by range and checks each hashes to its txid.

**Config.**

| Key | Default | Meaning |
|---|---|---|
| `:store_block_objects` (env `STORE_BLOCK_OBJECTS`) | `:auto` | `:auto` writes only while `TxStore.ready?/0` is `:ok`, so a missing bucket never breaks sync; `false` off; `true` on |
| `Bitblocks.TxStore, adapter:` | S3 (prod), Local (dev, test) | where objects go |
| `:raw_block_max_bytes` | 32 MB | the largest block fetched whole, and so given an object |

**Before this writes to S3 in prod (infra).**

- A bucket, named in `AWS_S3_BUCKET_TXS` (in the `bitblocks/prod` secret); private, no expiry, versioning optional.
- The instance role allowed `s3:PutObject`, `s3:GetObject` and `s3:ListBucket` on it (`ListBucket` makes a missing object a 404 rather than a 403, which the store reads as "not found"); `HeadObject` and ranged GETs are covered by `GetObject`.
- CloudFront for `cdn.bitblocks.app`: the app as origin for `/tx/*`, with a path rewrite (a CloudFront Function) from `/tx/<txid>` to `/api/v1/txs/<txid>/raw`, honouring the origin's `cache-control`, not forwarding cookies or query strings.
- The rate limiter keys on the last `X-Forwarded-For` entry (the one the ALB adds, `BitblocksWeb.Utils.IpHelper`); behind CloudFront that is a CloudFront edge address, so every miss would count against a few edge IPs.
  Give CloudFront an API key with its own budget instead (`Authorization: Bearer bbk_…` as an origin custom header; `Release.create_api_key/2`).
- Set `TX_CDN_BASE_URL` to `https://cdn.bitblocks.app` once CloudFront serves `/tx/*`: the transaction page's download link (`TxStore.download_url/1`, signed-in readers) moves from the origin to the CDN.
- `TxStore.url/1` (the `cdn_url` in the tx API) still links only txs with their own object, `CDN_BASE_URL/raw/<txid>`; pointing it at `/tx/<txid>` for every tx is a small change to make once CloudFront serves that path.

## Open choices

- Whether small txs also drop `raw` once the CDN holds them (the most space, but every parse then reads S3 or the edge).
- Whether the decoded JSON goes entirely, or a compact per-input and per-output summary stays (proposed: a compact summary stays).
