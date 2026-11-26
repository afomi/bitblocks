# Indexes on `transactions`

Which indexes on `transactions` the code reads, and which it no longer needs.
The code wins when this doc and it disagree.

Every index on `transactions` is written on each insert and on each non-HOT update, so one nothing reads still costs every sync insert and every backfill update.
GIN indexes cost more again: with `fastupdate` on, new entries go to a pending list that `Bitblocks.DB.GinPending` merges in, and that merge was measured on prod as the single largest share of database load.

## Ready to drop

These three GIN indexes have no reader in `lib/`.
The app answers the same with them or without them, and the tests run every changed path with them present.
The columns stay, and the parser keeps writing them (`TransactionParser`, `TxIngest`, the script analysis backfill), so any of these indexes can be rebuilt later with `CREATE INDEX CONCURRENTLY`.

| Index | Column | What read it | What reads instead |
|---|---|---|---|
| `transactions_input_txids_index` | `input_txids` | `/graph`'s forward walk (`Chain.TxGraph`, `children/1`): `input_txids && frontier` | `spend_index` by `txid`, its `(txid, vout)` index, which the pipeline fills for every input it stores (`record_spends`) |
| `transactions_output_script_hashes_index` | `output_script_hashes` | `GET /api/v1/script/:scripthash/history` and `/unspent`, and projection filters | The two endpoints answer a 400 saying script hash lookups aren't indexed, naming the address endpoints; a projection may use it only next to an indexed column, and matches it with `= ANY`, which no GIN index serves |
| `transactions_aip_signers_index` | `aip_signers` | projection filters only | As `output_script_hashes`: a narrowing column, never alone |

Other readers of `input_txids` look a row up by `txid` and read the column from it, so they never needed its GIN index: `TxGraph`'s backward walk (`parents/1`), `Chain.spend_depth/2`, and the flow tiles' input count (`FlowTiles`).

A scripthash is the sha256 of a script, so it can't be turned back into an address.
A caller with a P2PKH or P2PK script derives its address and uses `/api/v1/addresses/:address/history` and `/utxos`, which `transactions_output_addresses_index` serves.
That index stays: address pages and the address API read it.

### Projections

A projection's filter must name at least one indexed tag column: `output_addresses`, `protocols` or `output_template_hashes` (`Projection.indexed_columns/0`).
`output_script_hashes` and `aip_signers` only narrow those rows (`Projection.narrowing_columns/0`), so qart's filter, `protocols @> [MAP]` and its AIP signer, still works.
A filter on a narrowing column alone is refused when it's created, with the changeset error "… can't be filtered on alone, since lookups on it aren't indexed".
The filter is the definition and never changes, so a projection created earlier with such a filter would still load; check for one before the drop:

```sql
SELECT id, tenant, name, filter
FROM projections
WHERE source = 'transactions'
  AND (filter ? 'output_script_hashes' OR filter ? 'aip_signers')
  AND NOT (filter ? 'output_addresses' OR filter ? 'protocols' OR filter ? 'output_template_hashes');
```

No row means no projection depends on these indexes.

### The drop

Ryan decides, and infra runs it by hand on prod, under a push freeze.
Run each statement on its own: `DROP INDEX CONCURRENTLY` can't run inside a transaction block.
`IF EXISTS` makes each safe to run again, and lets a later migration use the same names.

```sql
DROP INDEX CONCURRENTLY IF EXISTS transactions_output_script_hashes_index;
```

```sql
DROP INDEX CONCURRENTLY IF EXISTS transactions_input_txids_index;
```

```sql
DROP INDEX CONCURRENTLY IF EXISTS transactions_aip_signers_index;
```

- Drop before an anti-wraparound vacuum of `transactions` starts: that vacuum doesn't yield its lock, so a concurrent drop would wait behind it.
- A concurrent drop waits for every transaction that touches `transactions` to finish, the sync's included; it doesn't block new inserts while it waits.
- A drop that is cancelled can leave the index marked invalid; run the same statement again.
- Check afterwards: `SELECT indexrelid::regclass FROM pg_index WHERE indrelid = 'transactions'::regclass;` no longer lists it.

`Bitblocks.DB.GinPending` finds the GIN indexes on `transactions` from `pg_index` on every run, so it stops cleaning a dropped index on its next run with no code change.
An index dropped while a run is under way fails that one cleanup, which is logged and doesn't stop the rest.

No migration drops these yet.
Dev and test databases keep them until one does, which is the pattern of `20261120000120_drop_unused_transactions_indexes` (https://github.com/afomi/bitblocks/issues/92): `DROP INDEX CONCURRENTLY IF EXISTS`, a no-op where infra dropped them first.
