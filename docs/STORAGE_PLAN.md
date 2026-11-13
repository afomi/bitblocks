# Storage plan for bitblocks-db

Status: draft for Ryan and infra, 2026-11-13, answering `from-infra-2026-11-11-db-growth-storage-plan.md`.
Numbers marked **measured** come from prod, the code or public chain data; numbers marked **est.** are estimates that the [SQL below](#sql-to-finalize-the-numbers) replaces.
Related: [TX_STORAGE.md](TX_STORAGE.md) (the tx store and its order of work), [DERIVED_DATA.md](DERIVED_DATA.md), [SYNCING.md](SYNCING.md).

## Summary

- Bitblocks stores about **6.3 KB per tx** today (est., from infra's 313 GB used over the ~49.5M txs in blocks 0 to 328,752), about 11 times the tx's own bytes.
- About 4.2 KB of that is a fixed cost per row (metadata, indexes, `spend_index`), so even with raw bytes and decoded JSON gone, a row for every tx is about **30 TB** at tip.
- If nothing changes, the full chain needs about **80 TB** (est., range 60 to 85 TB depending on TOAST compression), about **$9,200 a month** in gp3, and past RDS's 64 TiB limit: it cannot be done on this shape at any price on RDS.
- **Recommendation for now:** pause the sync when `complete_through` reaches **400,000** (about 2026-11-19 to 11-21, about 620 GB est.), or at 650 GB used, whichever comes first; header sync keeps running to tip.
- **Long term:** raw bytes in S3 (block objects already being written), no decoded JSON, no row for bulk data-carrier txs, and the duplicate indexes dropped.
- **Spin-down:** at a 400,000 cap the final dump is about 150 to 190 GB compressed and 2 to 4 hours (est.), or about 50 to 60 GB and under an hour if `raw`, `inputs` and `outputs` are left out of it.

## 1. What fills the database

Measured on prod:

- Used: 313 GB on 2026-11-11 at `complete_through` 328,752 (infra); `complete_through` 343,740 on 2026-11-13 07:25Z (`/api/v1/status`).
- Growth: 40 to 55 GB a day (infra), about 7.9M tx rows a day before 4161eed (memory note, 2026-11-08).
- Txs in blocks 0 to 328,752: about 49.5M, and 0 to 343,740 about 58M (est., a 20% sample of `num_tx` from `/api/v1/headers`; matches public Bitcoin counts for 2014).
- Early-chain `transactions` row, 0.2% sample (TX_STORAGE.md, 2026-11-05): 3,125 bytes, of which `raw` 943, `outputs` 893, `inputs` 690, `input_txids` 136.

Per-tx data, from the schema (`lib/bitblocks/chain/transaction.ex`, `priv/repo/migrations`), for a tx of S bytes with I inputs and O outputs:

| Where | What | Bytes per tx (est.) | Duplicate of the raw bytes? |
|---|---|---|---|
| `transactions.raw` | the tx as hex `text` | 2 × S (943 measured, early chain) | yes, at twice the size |
| `transactions.inputs`, `outputs` | one JSON string per vin and vout, with every script as hex (asm too on the older RPC path) | about 2 × S + 110 × (I + O) (1,583 measured, early chain) | yes, the scripts again, at twice the size |
| `input_txids`, `output_addresses` | outpoint txids (65 × I), addresses (35 × O) | about 230 | derivable from raw; `input_txids` repeats `spend_index` |
| `output_script_hashes`, `output_template_hashes` | two 64-char hashes per output | about 130 × O | derived (script analysis) |
| txid, block hash, tallies, counts, types, stamps, offsets, timestamps | scalars and short arrays | about 400 | no |
| B-tree indexes on `transactions` (14) | txid twice (unique and `text_pattern_ops`), `block_height, txid`, id, `inserted_at`, two sat totals, two counts, and more | about 450 | the `txid_prefix` index repeats the unique txid index |
| GIN indexes on `transactions` (7) | `input_txids`, `output_addresses`, `output_script_hashes`, `output_template_hashes`, `protocols`, `aip_signers`, `tx_types` | about 350 | `input_txids` repeats `spend_index (txid, vout)` |
| `spend_index` | one row per input, with two indexes | about 360 × I | no |
| bloat, free space, other tables | dead tuples, fillfactor, Oban, protocol tables | the rest, about 1,500 | no |

So the raw bytes are held three times over in a row (hex `raw`, hex scripts in `inputs` and `outputs`), at about four times their size, and that is roughly 40% of the database (est.); the other 60% is a fixed cost of about 4.2 KB per tx.
`transactions` text columns are TOAST-compressed only past about 2 KB per row, and hex compresses poorly with pglz, so little of this is saved by compression (Q3 measures `raw_pct_compressed`).

## 2. Projected size at full tip, if nothing changes

Public chain totals: **7,524,524,627 txs** (`sum(num_tx)` over 973,549 headers, 2026-11-05) and **12.95 TB** of raw block files on our node, an upper bound (measured, TX_STORAGE.md).
Average tx: about 1.7 KB over the whole chain, but 220 to 710 bytes below height 500,000, against 1.1 to 7.4 KB a tx in 650,000 to 950,000 (est., our sample of WhatsOnChain block sizes).

| Part | Formula | Size (est.) | gp3 a month at $115/TB |
|---|---|---|---|
| raw bytes as hex, plus the same scripts as hex in JSON | about 4 × 12.95 TB | about 50 TB (30 to 50 TB, with TOAST compression of large values) | about $5,800 |
| fixed cost per row | 7.52B × 4.2 KB | about 32 TB | about $3,600 |
| **total** | | **about 80 TB (range 60 to 85 TB)** | **about $9,200** |

The remaining heights hold almost all of it: blocks above 343,740 carry about 99% of the txs and 99.7% of the bytes.
On the current shape the database reaches 850 GB near height 420,000 (about 2026-11-24) and 1,000 GB near 435,000 (about 2026-11-27), est., at 6 to 9M txs a day.

## 3. What moves out of Postgres

Each move, sized at a 400,000 cap (about 106M txs, about 620 GB) and at full tip:

| Move | Saves at 400,000 | Saves at full tip | Costs instead |
|---|---|---|---|
| A. `raw` to S3: every block up to 32 MB is already written as a verified block object (`blocks/<height>-<hash>.bin`, TX_STORAGE.md steps 1 and 2), and `TxStore.raw/1` reads it back by range | about 110 GB, $13 a month | about 26 TB, $3,000 a month | S3 at $0.023/GB: 66 GB through 400,000 is $1.50 a month; 12.95 TB at tip is about $300 a month |
| B. Drop the decoded `inputs` and `outputs` JSON; parse from raw when a page needs it (`Chain.RawTx`), keep a compact per-output summary only where an index needs it | about 150 GB, $17 a month | about 26 TB, $3,000 a month | nothing stored; parse cost on read |
| C. No row for bulk data-carrier txs: a tx whose only outputs are OP_RETURN data and change, matching no indexed protocol, keeps its bytes in the block object and is found through a txid locator | little below 400,000 | about 18 TB if 60% of the remaining txs qualify (est.), $2,100 a month | a txid locator: 7.52B × about 40 bytes, about 300 GB as sorted files in S3 ($7 a month) or about 600 GB with its index in Postgres ($70 a month) |
| D. Drop duplicate and unused indexes: `transactions_txid_prefix_idx`, the `input_txids` GIN (and column, `spend_index` already answers it), and single-column indexes Q2 shows unused (`inserted_at`, sat totals, counts) | about 50 GB, $6 a month | about 3.4 TB, $390 a month | slower ad hoc queries on those columns |

What it leaves at full tip, with A to D: about 3B txs with rows at about 3.7 KB, about **11 TB** in Postgres, about $1,300 a month, plus about $300 in S3 (est.).
So a row for every tx does not fit a small budget even after the raw bytes leave.
Within a 1 TB database the whole chain allows about 130 bytes a tx, less than a txid and its index.
The shape that fits is headers and block totals for every block, a txid locator for every tx, and full metadata rows only for the txs an index serves (protocols, tokens, the addresses and scripts asked about).

Caveats, each to settle before the move:

- Blocks over 32 MB get no block object today, and they hold most of the bytes above 650,000 (est.); `Chain.BlockStream` already reads any block as a stream, so they can be written to S3 in parts (multipart upload) rather than kept per tx.
- RDS allocated storage never shrinks: trimming rows frees space for new rows, not money; a smaller bill needs a dump and restore to a new instance.
- Trimming by `UPDATE` writes a new version of every row first, so it needs free space while it runs; this is one reason to stop well below the ceiling.
- C and the 60% figure need measuring on blocks above 620,000, which prod does not hold yet: a sample read from our node of a few thousand blocks across 650,000 to 950,000.

## 4. Heights until the plan lands

Options: continue, cap at a height, or index headers and spends only past some block.

**Recommended: cap at 400,000, by pausing the sync when `complete_through` reaches it, or at 650 GB used if that comes first.**

- Continuing reaches infra's 850 GB pause in about 11 days and the ceiling soon after, with nothing gained: every row it writes is in the shape this plan replaces, and makes the final dump and any trim larger.
- Headers and spends only does not fit either: `spend_index` alone is about 360 bytes an input, about 5 TB at tip (est.), and the code has no such mode today.
- A cap is the existing pause (`Sync.set_paused/1`, `paused` on `/api/v1/status`): no code change, header sync to tip keeps running, and every page stays correct, since the site already says it is complete through block X.
- 400,000 (February 2016) is a clean boundary, reached around 2026-11-19 to 11-21, at about 620 GB (est.), which leaves about 380 GB for the trim backfill and the indexes it rebuilds.
- Sync resumes in the new shape once A, B and D are built and tested; C decides how far past 400,000 it then goes.

## 5. Fit with the 2026-12-31 spin-down

`pg_dump` writes table data and index definitions, not index contents or dead rows, so the dump is about the heap and TOAST size.

| Database at | Data to dump (est.) | Compressed (est.) | Time on db.m7g.large (est.) | Glacier Deep Archive a month |
|---|---|---|---|---|
| 400,000 cap, as is (about 620 GB) | about 370 GB | 150 to 190 GB | 2 to 4 hours | about $0.20 |
| 400,000 cap, `raw`, `inputs`, `outputs` left out | about 120 GB | 50 to 60 GB | under 1 hour | about $0.06 |
| ceiling (about 1,000 GB) | about 600 GB | 250 to 300 GB | 4 to 6 hours | about $0.30 |
| full tip, as is (about 80 TB) | about 65 TB | about 25 TB | about 12 days | about $25 |

`transactions` is one table, so a parallel dump (`-j`) does not speed it up; one stream at 40 to 80 MB/s is the estimate.
To leave the raw columns out: `pg_dump --exclude-table-data=transactions` for everything else, plus `\copy (SELECT <every column but raw, inputs, outputs> FROM transactions) TO PROGRAM 'zstd …'`.
The raw bytes are already in the S3 block objects; keep that bucket (or move it to Glacier) alongside the dump, and first confirm every completed block has its object (Q6, `Release.tx_store_reconcile/3`).
With the 400,000 cap, the plan and the spin-down agree: the database never passes about 650 GB, and the last copy is small either way.

## SQL to finalize the numbers

Read-only, for infra to run on prod through `app-db-query.sh` with Ryan's OK.
Q3 and Q4 read a 0.05% block sample (`TABLESAMPLE SYSTEM`), so they finish in seconds to minutes.

```sql
SET statement_timeout = '10min';
SET default_transaction_read_only = on;

-- Q1. The database, and the 15 largest tables: heap, TOAST, indexes, live and dead rows.
SELECT pg_size_pretty(pg_database_size(current_database())) AS database;

SELECT c.relname,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
       pg_size_pretty(pg_relation_size(c.oid)) AS heap,
       pg_size_pretty(coalesce(pg_total_relation_size(c.reltoastrelid), 0)) AS toast,
       pg_size_pretty(pg_indexes_size(c.oid)) AS indexes,
       s.n_live_tup, s.n_dead_tup
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE n.nspname = 'public' AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT 15;

-- Q2. Every index on the two big tables, largest first, with how often each is used.
SELECT s.relname, s.indexrelname,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS size,
       s.idx_scan
FROM pg_stat_user_indexes s
WHERE s.relname IN ('transactions', 'spend_index')
ORDER BY pg_relation_size(s.indexrelid) DESC;

-- Q3. Bytes per column of a transactions row, by era of 100,000 blocks.
SELECT width_bucket(block_height, 0, 400000, 4) AS era,
       count(*) AS rows,
       round(avg(size_bytes)) AS tx_bytes,
       round(avg(pg_column_size(t.*))) AS row_bytes,
       round(avg(pg_column_size(raw))) AS raw,
       round(avg(pg_column_size(inputs))) AS inputs,
       round(avg(pg_column_size(outputs))) AS outputs,
       round(avg(pg_column_size(input_txids))) AS input_txids,
       round(avg(pg_column_size(output_addresses))) AS output_addresses,
       round(avg(pg_column_size(output_script_hashes))) AS script_hashes,
       round(avg(pg_column_size(output_template_hashes))) AS template_hashes,
       round(avg(pg_column_size(output_types))) AS output_types,
       round(avg(input_count), 2) AS ins,
       round(avg(output_count), 2) AS outs,
       round(100.0 * avg((pg_column_compression(raw) IS NOT NULL)::int), 1) AS raw_pct_compressed,
       round(100.0 * avg((raw_offset IS NOT NULL)::int), 1) AS pct_with_offsets
FROM transactions t TABLESAMPLE SYSTEM (0.05)
GROUP BY 1 ORDER BY 1;

-- Q4. Share of tx bytes in txs with an OP_RETURN output, and in txs over 100 KB and 1 MB.
SELECT round(100.0 * sum(size_bytes) FILTER (WHERE output_types ? 'op_return') / sum(size_bytes), 1) AS pct_bytes_op_return_txs,
       round(100.0 * avg((output_types ? 'op_return')::int), 1) AS pct_txs_op_return,
       round(100.0 * sum(size_bytes) FILTER (WHERE size_bytes > 100000) / sum(size_bytes), 1) AS pct_bytes_over_100k,
       round(100.0 * sum(size_bytes) FILTER (WHERE size_bytes > 1000000) / sum(size_bytes), 1) AS pct_bytes_over_1m
FROM transactions TABLESAMPLE SYSTEM (0.05);

-- Q5. spend_index: rows, and bytes per row with its indexes.
SELECT reltuples::bigint AS rows,
       round(pg_total_relation_size('spend_index')::numeric / greatest(reltuples, 1)) AS bytes_per_row
FROM pg_class WHERE oid = 'spend_index'::regclass;

-- Q6. What the totals divide by, and how many completed blocks have their object in S3.
SELECT reltuples::bigint AS tx_rows_estimate FROM pg_class WHERE oid = 'transactions'::regclass;

SELECT count(*) FILTER (WHERE sync_state = 'completed') AS completed,
       count(*) FILTER (WHERE sync_state = 'completed' AND raw_object_stored_at IS NOT NULL) AS completed_with_object,
       sum(num_tx) FILTER (WHERE sync_state = 'completed') AS txs_in_completed
FROM blocks;
```

What each replaces: Q1 and Q6 give the real bytes per tx (total over `txs_in_completed`) and the raw-and-JSON share; Q3 the per-column table in section 1; Q2 the index list in move D; Q4 how much of the stored bytes C and the 1 MB threshold touch; Q5 the `spend_index` cost.
Once they're in, the estimates above are recomputed and this draft becomes the plan.
