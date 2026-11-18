# Storage plan for bitblocks-db

Status: final draft for Ryan's approval, 2026-11-17, tracked in https://github.com/afomi/bitblocks/issues/96.
Ryan's decisions: pending (recorded here once made, one line per item in [Decisions for Ryan](#decisions-for-ryan)).
It answers infra's request of 2026-11-11 (`from-infra-2026-11-11-db-growth-storage-plan.md`) on prod's measurements of 2026-11-13 and 2026-11-15.

Every figure names its source.
**Measured** means read from prod, the code or public chain data; **derived** means computed from measured figures, with the arithmetic shown; **est.** means an estimate no query has checked yet.
The inbox notes cited are infra's, in the main checkout's `.claude/inbox/`: `2026-11-13-measurements` is `from-infra-2026-11-13-storage-plan-measurements.md`, and `2026-11-15-q3` is `from-infra-2026-11-15-backfills-and-q3.md`.
Related: [TX_STORAGE.md](TX_STORAGE.md) (the tx store and its order of work), [DERIVED_DATA.md](DERIVED_DATA.md), [SYNCING.md](SYNCING.md).

## Summary

- Bitblocks stores **5.3 KB per tx** (measured: 370 GB over 69,840,462 txs, 2026-11-13-measurements), about 8 times the average tx's 671 bytes (Q4, 2026-11-15-q3).
- The tx's own bytes, held as hex `raw` and again as hex scripts in the decoded `inputs` and `outputs` JSON, are **71% of a `transactions` row** (Q3, 2026-11-15-q3), about 2.5 KB of the 5.3 KB (derived, section 1).
  The other 2.8 KB a tx is metadata, indexes and `spend_index`, and it stays even when the raw bytes leave.
- At full tip, a row for every tx in today's shape is about **30 to 73 TB** (derived, section 2), $3,400 to $8,400 a month in gp3, and the top of that range is past RDS's 64 TiB limit.
  Even with the raw bytes, the JSON and the duplicate indexes gone, a row for every tx is about 17 TB.
- The database was **about 563 GB used on 2026-11-17** (infra, 2026-11-17), at `complete_through` 378,842 ([/api/v1/status](https://bitblocks.app/api/v1/status), 2026-11-18 00:35 UTC).
- The sync stops at **400,000** until this plan lands (`config/prod.exs`, `:sync_stop_at_height`); headers keep reaching the tip.
  At the growth since 2026-11-13, 400,000 lands at about 680 to 700 GB (derived, section 4), so infra's 650 GB alarm comes first, near 392,000 to 395,000.
- **Recommendation:** stop at 400,000 or 650 GB used, whichever comes first, as the draft said; then raw bytes to S3 (A), no decoded JSON (B) and the duplicate indexes dropped (D), applied through a dump and restore into a new instance, which is also the spin-down's last copy.
- Five unused `transactions` indexes were dropped on prod on 2026-11-17, freeing about **6.7 GB** (https://github.com/afomi/bitblocks/issues/92); `transactions_script_analysis_version_index` is kept.

## Measured on prod

### 2026-11-13: Q1, Q2, Q4, Q5, Q6 (2026-11-13-measurements)

Infra ran them read-only at about 19:40 UTC, at `complete_through` 348,921.

- **Database: 370 GB**, 69,840,462 txs in 353,645 completed blocks, so 5.3 KB per stored tx.
- `transactions` is 308 GB: heap 123 GB, TOAST 125 GB, indexes 60 GB, 71,942,781 live rows.
- `spend_index` is 60 GB (29 GB heap, 31 GB indexes), 158,824,192 rows, 405 bytes per row with its indexes (Q5).
- `blocks` is 1,665 MB; everything else is under 25 MB.
- RDS storage autoscaling is on: 433 GB allocated of a 1,000 GB max, gp3, db.m7g.large with 8 GB of RAM.
  Each step up is permanent until a dump and restore.
- Only **167,242 of 353,645 completed blocks (47%)** had their S3 block object (`raw_object_stored_at`), so 186,403 need one before any move that drops `raw`.
  The backfill chain for them shipped in 6503f6d (https://github.com/afomi/bitblocks/issues/94); blocks over 32 MB are counted and left for multipart upload.

### 2026-11-15: Q3 and the corrected Q4 (2026-11-15-q3)

Run at about 16:43 UTC on a `TABLESAMPLE SYSTEM (0.05)` sample.
Q3, average bytes per column of a `transactions` row (`pg_column_size`, so after TOAST compression), by era of 100,000 blocks:

| Era (heights) | Rows sampled | Tx bytes | Row | `raw` | `inputs` | `outputs` | `input_txids` | `output_addresses` | Script hashes | Template hashes | `raw` % compressed |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 to 99,999 | 109 | | 1,765 | 430 | 429 | 376 | | | 101 | 89 | 3.7 |
| 100,000 to 199,999 | 3,526 | | 2,742 | 789 | 725 | 389 | 161 | 111 | 176 | 93 | 68.5 |
| 200,000 to 299,999 | 15,438 | 475 | 2,931 | 848 | 764 | 375 | 172 | 117 | 189 | 90 | 94.1 |
| 300,000 to 399,999 | 19,323 | 599 | 3,501 | 1,022 | 881 | 494 | 199 | 161 | 275 | 92 | 92.6 |
| 400,000 and up | 2,090 | 6,719 | 5,169 | 1,673 | 1,615 | 1,380 | 117 | 53 | 178 | 159 | 10.7 |
| no height | 2,321 | | 2,373 | 715 | 504 | 840 | 94 | 69 | | | 30.1 |

What it shows (derived from the table):

- Over all 42,807 sampled rows, a row averages 3,249 bytes: `raw` 954 (29%), `inputs` and `outputs` 1,344 (41%), so **71% of the row is the tx's bytes as hex, twice over**.
  In 200,000 to 399,999 that share is 68%.
- `raw` costs 1.7 to 1.8 times the tx's bytes (848 over 475, 1,022 over 599): hex doubles it, and pglz wins back only 10 to 15%, though 93% of those values are compressed.
  With `inputs` and `outputs`, a tx costs about 4.0 to 4.2 times its own bytes before its metadata.
- Above 400,000 the rows are presumably tip blocks synced before the stop height (2026-11-15-q3); their `raw` averages 1,673 bytes against 6,719-byte txs, so those large txs compress far better than the early chain or are stored without `raw`; Q3 does not settle which.
- `size_bytes` is null below 200,000 and `input_count` and `output_count` are null above 99,999, so tx bytes come from `raw` there (`Release.backfill_tx_sizes/1` fills them).

Q4, corrected to fall back to `octet_length(raw) / 2` where `size_bytes` is null:

| Sampled | No `size_bytes` | No size at all | % bytes in OP_RETURN txs | % txs with OP_RETURN | % bytes in txs over 100 KB | % bytes in txs over 1 MB | Average tx bytes |
|---|---|---|---|---|---|---|---|
| 42,914 | 8,362 | 0 | 1.4 | 3.7 | 20.79 | 19.71 | 671 |

- OP_RETURN txs are 3.7% of rows and 1.4% of bytes below the stop height, so move C saves little there.
- About a fifth of the stored bytes sit in txs over 1 MB, the size `Transaction.raw_in_db_max_bytes/0` names; a system sample reads whole pages, so a few large txs swing this figure.

### 2026-11-16 and 2026-11-17

- 451 GB used on 2026-11-16 at about 05:40 UTC (2026-11-15-q3, update of that time).
- About 563 GB used on 2026-11-17 (infra, 2026-11-17).
  The day between includes the tx_types apply (chain 18), which changed about 6.2M rows with non-HOT updates and left about 30 GB of dead versions until autovacuum reuses them (infra's estimate, 2026-11-15-q3), and the script_analysis backfill.
- Five indexes dropped by hand on prod on 2026-11-17 with Ryan's go, `DROP INDEX CONCURRENTLY`, about **6.7 GB freed**, `transactions` from 21 indexes to 16 (https://github.com/afomi/bitblocks/issues/92):

  | Index | Size | Scans |
  |---|---|---|
  | `transactions_total_output_satoshis_index` | 1,913 MB | 0 |
  | `transactions_total_input_satoshis_index` | 1,839 MB | 0 |
  | `transactions_inserted_at_index` | 1,050 MB | 0 |
  | `transactions_output_count_index` | 936 MB | 0 |
  | `transactions_input_count_index` | 934 MB | 0 |

- `transactions_script_analysis_version_index` (1,025 MB) is **kept**: it had 392 scans by 2026-11-17, from that day's script_analysis backfill, which selects by version through it.
  The held migration for https://github.com/afomi/bitblocks/issues/92 must leave it out before it ships.
- Still at 0 scans on 2026-11-13 and kept on purpose: `transactions_output_script_hashes_index` (9,622 MB), which serves `/api/v1/script/:scripthash/*` and projection filters, and `transactions_aip_signers_index` (106 MB), which Qart's projection filters on.

## 1. What fills the database

At 2026-11-13, per stored tx (derived from Q1 and Q3: each part over 69,840,462 txs, and Q3's row shares applied to `transactions` heap and TOAST, 248 GB):

| Part | Size, 2026-11-13 | Bytes per tx | Duplicate of the tx's bytes? |
|---|---|---|---|
| `transactions.raw` | about 73 GB | about 1,040 | yes, as hex |
| `transactions.inputs`, `outputs` (one JSON string per vin and vout, scripts as hex) | about 103 GB | about 1,470 | yes, the scripts again, as hex |
| the rest of the row: `input_txids` (about 180), `output_addresses`, script and template hashes, txid, block hash, tallies, types, stamps, offsets | about 73 GB | about 1,040 | `input_txids` repeats `spend_index` |
| `transactions` indexes | 60 GB, 6.7 GB less since 2026-11-17 | about 860 | `txid_prefix_idx` (8.4 GB) near-duplicates the unique `txid` index (8.4 GB); the `input_txids` GIN (9.3 GB, 45 scans) repeats `spend_index` |
| `spend_index`, heap and indexes | 60 GB | about 860 | no |
| everything else | about 2 GB | about 30 | no |
| **total** | **370 GB** | **5,300** | |

So the tx's bytes are held twice over in hex, about 2.5 KB a tx and 47% of the database; the other 2.8 KB a tx is a fixed cost that any row for a tx carries.

Hot paths that stay: `spend_index_txid_vout` (19 GB) and `spend_index_spending_txid` (8.8 GB) answer spends; the unique `txid` index, `pkey` and `block_hash` serve every page (Q2, 2026-11-13-measurements).

## 2. Projected size at full tip, if nothing changes

Public chain totals: **7,524,524,627 txs** (`sum(num_tx)` over 973,549 headers, 2026-11-05) and **12.95 TB** of raw block files on our node, an upper bound on the tx bytes (measured, TX_STORAGE.md).

| Part | Formula (derived) | Size | gp3 a month at $115/TB |
|---|---|---|---|
| fixed cost per row | 7.52B × 2.8 KB (section 1) | about 21 TB | about $2,400 |
| `raw`, `inputs`, `outputs` | 12.95 TB × 0.69 (Q3, era 400,000 and up) to × 4.0 (Q3, era 300,000 to 399,999) | about 9 to 52 TB | about $1,000 to $6,000 |
| **total** | | **about 30 to 73 TB** | **about $3,400 to $8,400** |

The range is wide because Q3 holds only 2,090 rows above 400,000, all from recent tip blocks; a sample across 650,000 to 950,000 would narrow it.
Either end is beyond a small budget, and 73 TB is past RDS's 64 TiB limit.

## 3. What moves out of Postgres

Each move, sized at a 400,000 stop (about 106M txs, est., the draft's 20% sample of `num_tx` from `/api/v1/headers`) and at full tip (7.52B txs), at gp3's $115/TB a month:

| Move | Saves at 400,000 (derived) | Saves at full tip (derived) | Costs instead |
|---|---|---|---|
| A. `raw` to S3: blocks up to 32 MB are written as verified block objects (`blocks/<height>-<hash>.bin`), and `TxStore.raw/1` reads a tx back by range | 106M × 1,040 bytes, about **110 GB, $13 a month** | 12.95 TB × 1.75 (Q3 `raw` over tx bytes), about 23 TB, $2,600 a month; less if tip txs compress as Q3's era 5 does | S3 at $0.023/GB: about 66 GB through 400,000 is $1.50 a month (TX_STORAGE.md); 12.95 TB at tip is about $300 a month |
| B. Drop the decoded `inputs` and `outputs` JSON; parse from raw when a page needs it (`Chain.RawTx`), and keep a compact per-output summary only where an index needs it | 106M × 1,470 bytes, about **156 GB, $18 a month** | 12.95 TB × 2.3 (Q3), about 30 TB, $3,400 a month, with the same caveat | parse cost on read |
| C. No row for bulk data-carrier txs: a tx whose only outputs are OP_RETURN data and change, matching no indexed protocol, keeps its bytes in the block object and is found through a txid locator | at most 3.7% of rows (Q4) × 106M × 5.3 KB, about **21 GB, $2 a month** | about 18 TB if 60% of the remaining txs qualify (est., unmeasured), $2,100 a month | a txid locator: 7.52B × about 40 bytes, about 300 GB as sorted files in S3 ($7 a month) or about 600 GB with its index in Postgres ($70 a month) |
| D. Drop the duplicate indexes and column: `txid_prefix_idx` (117 bytes a row), the `input_txids` GIN (130 bytes a row) and the `input_txids` column (about 180 bytes), since `spend_index` answers it | 106M × 427 bytes, about **45 GB, $5 a month** | 7.52B × 427 bytes, about 3.2 TB, $370 a month | the `?txid=` prefix query needs the unique index to serve it (check its collation first); slower ad hoc queries on `input_txids` |
| Done: five unused indexes (https://github.com/afomi/bitblocks/issues/92) | 6.7 GB freed on 2026-11-17, about 93 bytes a row | about 0.7 TB | none: 0 scans each |

What it leaves at full tip, with A, B and D: about 2.3 KB a row (5.3 KB less 2.5, 0.43 and 0.09), so about **17 TB** for a row per tx ($2,000 a month), or about **6.9 TB** ($790 a month) if C's 60% holds, plus about $300 a month in S3 (derived).
Within a 1 TB database the whole chain allows about 133 bytes a tx, less than a txid and its index.
The shape that fits is headers and block totals for every block, a txid locator for every tx, and full rows only for the txs an index serves (protocols, tokens, the addresses and scripts asked about).

Before any move:

- Every completed block needs its block object before `raw` leaves a row: 186,403 lacked one on 2026-11-13; the backfill chain is https://github.com/afomi/bitblocks/issues/94, and `Release.tx_store_reconcile/3` confirms the count.
- Blocks over 32 MB get no block object today, and they hold most of the bytes above 650,000 (est.); `Chain.BlockStream` already reads any block as a stream, so they can go to S3 as multipart uploads.
- RDS allocated storage never shrinks: trimming rows frees space for new rows, not money.
  The saving becomes money only through a dump and restore into a new, smaller instance, which the spin-down's dump already does (section 5).
- Trimming in place by `UPDATE` writes a new version of every row first, needing free space while it runs, and on 2026-11-15 a non-HOT update cost an insert into each of 21 indexes (16 since the drop) on a table that RAM can't hold (2026-11-15-q3); a restore that leaves the columns out avoids both.
- C and its 60% need measuring on blocks above 620,000, which prod does not hold yet: a sample read from our node of a few thousand blocks across 650,000 to 950,000.

## 4. Heights until the plan lands

The sync stops at 400,000 (`config/prod.exs`, since 2026-11-13); `SYNC_STOP_AT_HEIGHT` moves it at runtime and the pause on /syncing (`Sync.set_paused/1`) stops dispatch at once.
Headers keep reaching the tip either way, and every page says how far it is complete.
Live: `complete_through` 378,842, `stop_height` 400,000 ([/api/v1/status](https://bitblocks.app/api/v1/status), 2026-11-18 00:35 UTC).

Growth since 2026-11-13 (derived): 370 GB at 348,921 to about 563 GB at 378,842 is about 193 GB over 29,921 blocks, **about 6.5 GB per 1,000 blocks**, or about 5.5 GB without the tx_types apply's 30 GB of dead versions.
So the 21,158 blocks left to 400,000 add about 115 to 137 GB, landing at **about 680 to 700 GB**, and 650 GB used arrives near 392,000 to 395,000.

| Stop at | Used at the stop (derived) | Extra gp3 a month over today's 563 GB | Fits infra's 650 GB alarm? |
|---|---|---|---|
| now (about 379,000) | about 563 GB | $0 | yes |
| 650 GB used (about 392,000 to 395,000) | 650 GB | about $10 | yes, at the line |
| 400,000 | about 680 to 700 GB | about $14 to $16 | no: the alarm moves, or the sync stops first |
| continue to the 1,000 GB ceiling | 1,000 GB near 440,000 to 460,000 | about $50 | no, and writes fail at the ceiling |

**Recommended: stop at 400,000 or 650 GB used, whichever comes first**, which on today's growth is 650 GB.
Every row written before the moves is in the shape this plan replaces and makes the last dump larger, and the dollars between the options are small; the alarm, the permanent allocation and the dump size are what differ.
Sync resumes in the new shape once A, B and D are built and tested; C decides how far past 400,000 it then goes.

## 5. Fit with the 2026-12-31 spin-down

Without funding, Bitblocks spins down by 2026-12-31, and its last copy is a dump to S3 Glacier (https://github.com/afomi/bitblocks/issues/55).
`pg_dump` writes table data and index definitions, not index contents or dead rows, so the dump is about the heap and TOAST size: 277 GB on 2026-11-13 (`transactions` 248 GB and `spend_index` 29 GB), about 4.0 KB a tx (derived).

| Database at | Data to dump (derived) | Compressed (est., zstd on hex about 2:1) | Time on db.m7g.large (est., one stream at 40 to 80 MB/s) | Glacier Deep Archive a month |
|---|---|---|---|---|
| 400,000, as is | 106M × 4.0 KB, about 420 GB | about 170 to 210 GB | about 1.5 to 3 hours | about $0.20 |
| 400,000, `raw`, `inputs`, `outputs` left out | 420 GB less 106M × 2.5 KB, about 155 GB | about 50 to 80 GB (est., 2 to 3:1 without the hex) | about 30 minutes to 1 hour | about $0.07 |
| full tip, as is | about 30 to 70 TB | about 15 to 35 TB | about 5 to 20 days | about $15 to $35 |

`transactions` is one table, so a parallel dump (`-j`) does not speed it up.
To leave the raw columns out: `pg_dump --exclude-table-data=transactions` for everything else, plus `\copy (SELECT <every column but raw, inputs, outputs> FROM transactions) TO PROGRAM 'zstd …'`.
The raw bytes are in the S3 block objects; keep that bucket (or move it to Glacier) alongside the dump, once every completed block has its object.
So the stop height and the spin-down agree: the database stays near 650 GB, and the last copy is under about 210 GB either way.

## Decisions for Ryan

Each item, with its measured or derived cost; the status line records each answer.

1. **Stop height.** Recommended: 400,000 or 650 GB used, whichever comes first.
   Options: stop now (about 563 GB, $0 more a month); at 650 GB used (near 392,000 to 395,000, about $10 a month more); at 400,000 (about 680 to 700 GB, about $15 a month more, past infra's alarm).
2. **`transactions_script_analysis_version_index`** (1,025 MB, 392 scans on 2026-11-17). Recommended: keep it, and take it out of the held migration for https://github.com/afomi/bitblocks/issues/92.
   Dropping it saves about 1 GB, and script_analysis backfills would scan by block range instead.
3. **A. `raw` to S3.** Saves about 110 GB at 400,000 ($13 a month) and about 23 TB at tip ($2,600 a month), for $1.50 a month of S3 at 400,000.
   It first needs every completed block's object (https://github.com/afomi/bitblocks/issues/94) and, past 400,000, multipart objects for blocks over 32 MB.
4. **B. No decoded `inputs` and `outputs` JSON.** Saves about 156 GB at 400,000 ($18 a month) and about 30 TB at tip ($3,400 a month), for parse cost on read.
5. **C. No row for bulk data-carrier txs.** Saves at most about 21 GB at 400,000 ($2 a month); at tip about 18 TB if 60% qualify, which is unmeasured.
   Recommended: decide after the 650,000 to 950,000 sample, before the sync resumes past 400,000.
6. **D. Drop `txid_prefix_idx`, the `input_txids` GIN and column.** Saves about 45 GB at 400,000 ($5 a month) and about 3.2 TB at tip ($370 a month).
7. **How the savings land.** Recommended: a dump that leaves `raw`, `inputs` and `outputs` out (about 50 to 80 GB compressed), restored into a new, smaller instance, and the same dump as the Glacier copy (https://github.com/afomi/bitblocks/issues/55).
   Trimming in place frees space but not money, since RDS allocation never shrinks.

## SQL behind the numbers

Read-only, run by infra on prod through `app-db-query.sh` with Ryan's OK: Q1, Q2, Q4 (first form), Q5 and Q6 on 2026-11-13, Q3 and the corrected Q4 on 2026-11-15.
Q3 and Q4 read a 0.05% sample (`TABLESAMPLE SYSTEM`), so they finish in seconds to minutes.

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
-- size_bytes is null on most older rows, so the size falls back to the hex in raw.
WITH s AS (
  SELECT coalesce(size_bytes, octet_length(raw) / 2) AS bytes,
         output_types ? 'op_return' AS op_return,
         size_bytes IS NULL AS no_size,
         raw IS NULL AS no_raw
  FROM transactions TABLESAMPLE SYSTEM (0.05)
)
SELECT count(*) AS sampled,
       count(*) FILTER (WHERE no_size) AS no_size_bytes,
       count(*) FILTER (WHERE bytes IS NULL) AS no_size_at_all,
       round(100.0 * sum(bytes) FILTER (WHERE op_return) / nullif(sum(bytes), 0), 1) AS pct_bytes_op_return_txs,
       round(100.0 * avg(op_return::int), 1) AS pct_txs_op_return,
       round(100.0 * coalesce(sum(bytes) FILTER (WHERE bytes > 100000), 0) / nullif(sum(bytes), 0), 2) AS pct_bytes_over_100k,
       round(100.0 * coalesce(sum(bytes) FILTER (WHERE bytes > 1000000), 0) / nullif(sum(bytes), 0), 2) AS pct_bytes_over_1m,
       round(avg(bytes)) AS avg_tx_bytes
FROM s;

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

Rerunning Q1 and Q6 after the stop gives the final bytes per tx at 400,000, and Q6 again after https://github.com/afomi/bitblocks/issues/94 confirms every completed block has its object.
