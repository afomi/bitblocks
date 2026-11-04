# Transaction storage: every tx in the CDN, metadata in Postgres

Status: proposal (2026-11-04), not built.
Decided by Ryan: every tx is in the CDN; every tx has its metadata in the database; very large raw bodies stay out of the database.
The rest is the plan below; the open choices are marked.

## Why now

On 2026-11-04 the bitblocks database was 65 GB for about 10.6 million txs, growing about 11 GB a day, on a shared burstable instance that ran out of CPU credits.
It is moving to its own instance (`bitblocks-db`, db.m7g.large, gp3 autoscaling to 1 TB), which buys time, not a shape that holds the chain.
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
Blocks over 32 MB are written as a series of chunk objects, with the same offset scheme.
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
`raw` stays in the row for txs up to `:raw_in_db_max_bytes`, proposed **100 KB**.
Above that the row keeps its metadata and an empty `raw`, and every reader gets the bytes through `TxStore.raw/1`, which already falls back from the database to the store.
Why 100 KB rather than 2 MB: payments, tokens and most inscriptions are under a few KB; the large txs are data carriers (images, files), which are exactly what the CDN is for.
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

## Open choices

- The threshold: 100 KB proposed; 2 MB keeps more in the database, and less traffic goes to the store.
- Whether small txs also drop `raw` once the CDN holds them (the most space, but every parse then reads S3 or the edge).
- Whether the decoded JSON goes entirely, or a compact per-input and per-output summary stays (proposed: a compact summary stays).
