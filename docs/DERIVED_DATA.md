# Derived data and its provenance

What Bitblocks adds to a transaction or block after ingesting it, which version of the code computed it, and how older rows are brought up to date.
This doc is authoritative for derived data; the code is `Bitblocks.Chain.TxPipeline` (the steps and their versions) and `Bitblocks.Derivations` (the run record).
`test/bitblocks/chain/derived_data_doc_test.exs` fails when the step table below lists anything other than `TxPipeline.steps/0` at their current versions.

Related: `docs/TX_PIPELINE.md` (what each step does, in order), `docs/TYPING_PIPELINE.md` (the typing steps to come), `docs/SYNCING.md` (how blocks and their txs arrive).

## The principle

Bitblocks holds two kinds of data.

**Ingested data** is what the chain says: block headers, txid lists and raw transaction bytes.
It is verified, not computed: a body must hash to its txid, and a block's txids must rebuild its merkleroot.
It never changes for a given block.

**Derived metadata** is what Bitblocks works out from it: output types, protocols, sats in and out, fees, burned sats, block totals.
It is value added after ingestion, and it depends on the code that computed it.
Better code gives better answers, so derived data can change while the chain does not.

So every derived value carries its provenance: what computed it, at which version, and when.
That is what lets a research claim stand up.
"Type X first appeared at block H" is only reproducible as "first seen at block H, computed by script analysis v7, over blocks verified complete through H".
A reader can then check the claim, rerun it, or see that a later version changes it.

## Versions

Every step of the pipeline has a `version/0`, a positive integer bumped whenever its output for the same input would change.
A **derivation** is a group of steps whose output a row records with one stamp.
Its version is the sum of its steps' versions, and so is a stage's (`TxPipeline.version/1`).

A sum reads at a glance ("tallies v4: four steps at v1"), and it only goes up.
A bump in any step, or a new step, raises it, so every row stamped with the old sum is below it.
Removing a step would lower it, so a removal also bumps a remaining step of the same derivation by at least the removed step's version.

### Steps

| Step | Stage | Version | Derivation | Writes |
| --- | --- | --- | --- | --- |
| `script_analysis` | chunk | 7 | `script_analysis` | `output_types`, `protocols`, `coinbase`, `output_script_hashes`, `output_template_hashes`, `aip_signers` |
| `sats_out` | chunk | 1 | `tallies` | `total_output_satoshis` |
| `burned` | chunk | 1 | `tallies` | `burned_satoshis` |
| `sats_in` | chunk | 1 | `tallies` | `total_input_satoshis` |
| `fee` | chunk | 1 | `tallies` | `fee_satoshis` |
| `classify_outputs` | chunk | 3 | `tx_types`, `type_counts` | `tx_types` |
| `record_spends` | tx | 1 | none | `spend_index` rows |
| `index_tokens` | tx | 3 | `token_recipients` | `protocol_instances`, the token index, with who holds each output and each BSV-21 transfer's validation status |
| `index_bitcom` | tx | 1 | none | `bitcom_commands` |
| `index_bap` | tx | 1 | none | `bap_records` |
| `block_totals` | block | 2 | `block_totals` | `blocks.sats_out`, `fees`, `miner_reward`, `subsidy`, `burned`, `fees_verified` |
| `type_counts` | block | 1 | `type_counts` | `blocks.type_counts` |

The `script_analysis` step's version is `TransactionParser.script_analysis_version/0`, and `classify_outputs`'s is `TxTypes.Classifier.version/0`: one number each, kept beside the code it versions.
v7 (#49) names each opcode byte once in `output_template_hashes` (`Bitblocks.Script.opcode_name/1`: `OP_1`, `OP_NOP2`, `OP_NOP3`).
Before it, a shape holding byte 81, 177 or 178 got whichever name `BSV.OpCode` picked at boot, so one shape could carry two hashes.
On the dev DB, 1,186 of 7,641 decodable txs hold such a shape (13 shapes), and 65 of them were stamped with a hash v7 no longer produces.
Until the v7 backfill has run, `TxTypes.template_hash_variants/1` still matches both names.
`classify_outputs` v2 (#49) adds the `p2pk` and `p2sh` types, so early coinbases stop reading `custom`.
`classify_outputs` v3 (#78) adds `stas`, matched by the STAS contract bytes (`Bitblocks.Stas`).
`block_totals` v2 stamps a block only once its coinbase is known; v1 stamped blocks whose rows hadn't been through script analysis, leaving `miner_reward` and `fees_verified` nil and the coinbase counted in `sats_out`.
A block left unstamped stays below the version, so the tally backfill finds it again after script analysis has run, and reports it under `reward_unknown` until then.
`index_tokens` v3 (#69) reads the lock on either side of the inscription envelope, names a cosign lock's owner, and records holders on classic deploys and mints too.

### Derivations

| Derivation | Steps | Version | Stamped in | Backfill |
| --- | --- | --- | --- | --- |
| `script_analysis` | `script_analysis` | 7 | `transactions.script_analysis_version` | `Release.backfill_script_analysis/3` |
| `tallies` | `sats_out`, `burned`, `sats_in`, `fee` | 4 | `transactions.tallies_version` | `Release.backfill_tx_tallies/3` |
| `block_totals` | `block_totals` | 2 | `blocks.tallies_version` | `Release.backfill_tx_tallies/3` |
| `tx_types` | `classify_outputs` | 3 | `transactions.tx_types_version` | `Release.backfill_tx_types/3` |
| `type_counts` | `classify_outputs`, `type_counts` | 4 | `blocks.type_counts_version` | `Release.backfill_tx_types/3` |
| `token_recipients` | `index_tokens` | 3 | `protocol_instances.recipient_version` | `Release.backfill_token_recipients/3` |

Stage versions today: chunk 14, tx 6, block 3.
`GET /api/v1/status/derivations` answers all of these live.

`type_counts` sums the classifier's version with its own, because a block's counts change when the classifier does: a classifier bump marks every block's counts below the version too, and the one backfill re-types the txs and rewrites the counts.
A block is stamped only when every one of its txs is typed at the current version, so `/types` can say exactly which blocks its counts cover.

### Where the stamps are written

- **At ingest** (`Chain.TxIngest.store_chunk/2`): `script_analysis` and `classify_outputs` stamp each tx that decodes, and the pipeline stamps `tallies_version` on every row once all four tally steps ran.
  A tally step that raises leaves the chunk's rows unstamped, so the backfill picks them up.
- **At completion**: `block_totals` stamps `blocks.tallies_version` in the same update that writes the totals, and `type_counts` stamps `blocks.type_counts_version` when every tx of the block is typed.
- **By a backfill**: every row it picks gets the current version in the same statement that writes its values.

A row with a nil stamp (computed before versions existed, or not computed) or an older one is what a backfill picks up.

### When

A tx's tallies date is the row's `updated_at`: set when it was stored, and when the tallies backfill stamps it.
The script analysis backfill never sets `updated_at`.
Moving a tx off an orphaned block after a reorg also sets it (#34), so read the date as "computed on or before".
The tx page shows "Tallies v4 · computed 2026-11-05 · Script analysis v7"; the block page shows "Totals v1".

A backfill run is dated exactly, in `derivation_runs`.

## Every derived field

| Field | Step | Source | Stamp | Cost to compute | Backfill |
| --- | --- | --- | --- | --- | --- |
| `transactions.output_types` | `script_analysis` | raw bytes | `script_analysis_version` | CPU: one decode per tx | `Release.backfill_script_analysis/3` |
| `transactions.protocols` | `script_analysis` | raw bytes | `script_analysis_version` | CPU, same decode | `Release.backfill_script_analysis/3` |
| `transactions.coinbase` | `script_analysis` | raw bytes | `script_analysis_version` | CPU, same decode | `Release.backfill_script_analysis/3` |
| `transactions.output_script_hashes` | `script_analysis` | raw bytes | `script_analysis_version` | CPU: a SHA-256 per output | `Release.backfill_script_analysis/3` |
| `transactions.output_template_hashes` | `script_analysis` | raw bytes | `script_analysis_version` | CPU: a skeleton hash per output | `Release.backfill_script_analysis/3` |
| `transactions.aip_signers` | `script_analysis` | raw bytes | `script_analysis_version` | CPU: signature checks on AIP-tagged txs only | `Release.backfill_script_analysis/3` |
| `transactions.tx_types` | `classify_outputs` | raw bytes, against `types.json` | `tx_types_version` | CPU: one tolerant decode, a pattern match per output | `Release.backfill_tx_types/3` |
| `transactions.total_output_satoshis` | `sats_out` | raw bytes | `tallies_version` | CPU: a byte walk | `Release.backfill_tx_tallies/3` |
| `transactions.burned_satoshis` | `burned` | raw bytes | `tallies_version` | CPU: a byte walk | `Release.backfill_tx_tallies/3` |
| `transactions.total_input_satoshis` | `sats_in` | each input's previous output, stored | `tallies_version` | one indexed lookup per page of txs | `Release.backfill_tx_tallies/3` |
| `transactions.fee_satoshis` | `fee` | sats in and sats out | `tallies_version` | CPU only | `Release.backfill_tx_tallies/3` |
| `blocks.sats_out`, `fees`, `miner_reward`, `subsidy`, `burned`, `fees_verified` | `block_totals` | the block's tx rows | `blocks.tallies_version` | one aggregate on the `block_hash` index | `Release.backfill_tx_tallies/3` |
| `blocks.type_counts` | `type_counts` | the block's `tx_types` | `blocks.type_counts_version` | one aggregate on the `block_hash` index | `Release.backfill_tx_types/3` |
| `spend_index` rows | `record_spends` | the tx's inputs | none yet | one insert per input | none: written at ingest only |
| `protocol_instances` (tokens) | `index_tokens` | BSV-20/21 inscriptions; for a transfer, the token rows its spent outpoints hold | none yet | none for untagged txs; a few indexed lookups per transfer | transfer statuses: `Release.revalidate_token_transfers/1` |
| `parsed_data` `recipient`, `lock`, `cosigner` (tokens) | `index_tokens` | the output's lock, from raw bytes | `recipient_version` | CPU: one decode per tx with a row below the version | `Release.backfill_token_recipients/3` |
| `bitcom_commands` | `index_bitcom` | Bitcom `$` commands | none yet | none for untagged txs | re-indexed by `Release.backfill_script_analysis/3` |
| `bap_records` | `index_bap` | BAP records with a valid AIP signature | `version` | none for a tx with no AIP signer | `Release.backfill_bap/3` |

The tx steps write rows in other tables keyed by txid, so most have versions but no per-row stamp yet.
When one of them changes its output, it gains a stamp column and a backfill in the same change.

`input_txids` and `output_addresses` are extracted from the node's JSON at insert (`TxIngest`), outside the pipeline, and carry no version.

## A version bump triggers a backfill

1. Change the step, bump its `version/0`, and update the tables above (the doc test fails until you do).
2. Deploy.
   New rows are stamped with the new version as they come in, and every older row is now below it.
3. Dry run over the completed range, `0..complete_through` (`Release.sync_status()` prints it), and read the counts.
4. Ryan approves prod data changes: send him the dry-run output.
5. Apply in ascending height ranges.
   Ascending matters for the tallies: a range's previous outputs must be stored before it.
6. Verify: the dry run over the whole range reports 0 rows below the version.

A backfill picks rows by version, so it is idempotent and resumable.
A rerun after a full apply finds nothing, and a run stopped partway resumes from the rows still below the version.
`force: true` recomputes every row in a range, whatever its stamp.

### The commands

```bash
# Tallies and block totals of completed blocks, dry run, then apply
bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_tallies(0, 10_000)'
bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_tallies(0, 10_000, apply: true)'

# Script analysis of stored txs by block_height, dry run, then apply
bin/bitblocks rpc 'Bitblocks.Release.backfill_script_analysis(0, 10_000)'
bin/bitblocks rpc 'Bitblocks.Release.backfill_script_analysis(0, 10_000, apply: true)'

# Transaction types of completed blocks, and their per-block counts (#49)
bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_types(0, 10_000)'
bin/bitblocks rpc 'Bitblocks.Release.backfill_tx_types(0, 10_000, apply: true)'

# Who holds each token output (#69), dry run, then apply
bin/bitblocks rpc 'Bitblocks.Release.backfill_token_recipients(0, 980_000)'
bin/bitblocks rpc 'Bitblocks.Release.backfill_token_recipients(0, 980_000, apply: true)'

# The runs, newest first
bin/bitblocks rpc 'Bitblocks.Release.derivation_runs()'
```

`Release.analyze_transactions/1` still works: it applies script analysis over every stored tx, paged by id, and records its run.

### Bounded batches

- The tallies backfill walks completed blocks in height order, `block_batch` (100) at a time, and each block's txs by id, `tx_batch` (1,000) at a time.
- The tx types backfill walks completed blocks the same way, `block_batch` (100) at a time, each block's txs by id, `tx_batch` (1,000) at a time.
- The script analysis backfill walks the stored blocks in the range, `block_batch` (100) at a time, and each block's txs on the `block_hash` index, paged by id, `batch_size` (500) at a time.
  It selects through the block because older rows have a NULL `block_height`, and it fills that column on each row it writes.
- Each page is one short transaction under `SET LOCAL statement_timeout` (`statement_timeout_ms`, default 60,000).
- After each page it writes, it sleeps `pause_ms` (default 50, `config :bitblocks, :derivation_pause_ms`).
  Most updates on `transactions` are not HOT (the table carries many indexes, and pages are full), so each one leaves a dead tuple per index; the pause lets autovacuum keep up.
  Raise it if tip sync slows, or lower `tx_batch`.

### Cost

The tallies backfill reads every tx row in its range once, for the block sums, but reads raw bytes only for the rows it picks.
So a rerun over a finished range costs one index scan per block and no raw reads.
The script analysis backfill reads only the rows below the version, on the `script_analysis_version` and `block_height` indexes.
The tx types backfill reads every tx row's stamp in its range, and raw bytes only for the rows below the version; on the dev DB, typing all 7,647 txs (412 MB of hex) takes 2.7 s of CPU.
Neither needs a new index on `transactions`.

## `derivation_runs`

Every backfill run writes one row, dry runs included (`Bitblocks.Derivations.Run`, migration `20261105100002_create_derivation_runs`):

| Column | Meaning |
| --- | --- |
| `derivation` | `tallies`, `script_analysis`, `tx_types`, `tx_steps`, `tx_size`, `bap` or `token_recipients` |
| `version` | the version the run brought rows up to |
| `from_height`, `to_height` | the inclusive height range; nil for a run over every stored tx |
| `applied` | false for a dry run |
| `rows_examined` | rows the run read |
| `rows_changed` | rows it stamped, or in a dry run would stamp |
| `rows_below_version` | rows in the range still below the version when it finished: 0 for a complete applied run |
| `blocks_examined` | blocks it walked (tallies) |
| `details` | per-derivation counts: `values_changed`, `sats_in_unknown`, `blocks_changed`, `blocks_below_version`, `unverified`; `undecodable` for script analysis; `types_changed`, `undecodable`, `blocks_changed`, `blocks_below_version` for tx types; `recipients_filled`, `cosign`, `unknown_lock`, `no_raw` for token recipients |
| `outcome` | `running`, `ok`, `partial`, `failed` or `abandoned` |
| `error` | what stopped a partial or failed run |
| `command` | the command as typed |
| `chain_id` | the backfill chain that ran this range; nil for a run started by hand |
| `started_at`, `finished_at` | when it ran |

`running` means in flight, or the process died before finishing.
`partial` means an error stopped it after at least one batch: those batches stay applied, and a rerun picks up the rest.
`failed` means it stopped before finishing any batch.
`abandoned` means it was `running` when its process died (a deploy restart, say) and an operator closed it: its applied batches stay applied, and a rerun of the range picks up the rest.
A block that completes over rows stored by an earlier sync gets a catch-up job (`Chain.TxPipeline.CatchUp`, queue `:derived`): the sync skips a stored txid, so those rows never meet the chunk steps, and the job runs the backfills over that one block, with no run record.
`Release.backfill_tx_steps/3` does the same for the `:tx` steps over a range, on rows that never recorded a spend (derivation `tx_steps`, stamped by no column; run script analysis over the range first).
Close such runs by id, dry run first, with `bin/bitblocks rpc 'Bitblocks.Release.close_abandoned_derivation_runs(ids: [1, 2])'`, then `bin/bitblocks rpc 'Bitblocks.Release.close_abandoned_derivation_runs([ids: [1, 2]], apply: true)'`; `started_before: ~U[2026-11-05 00:00:00Z]` names them by start time instead.

Read them with `Release.derivation_runs/1`, or `GET /api/v1/status/derivations` (the latest 20, with each error cut to its first line and any URL or IP address removed).

## Backfill chains

A backfill can run as a chain of Oban jobs, one range at a time, so it needs no open connection and carries on across a deploy (`Bitblocks.BackfillChains`, `Workers.BackfillChainWorker`, queue `:backfills`).
Each range is an ordinary backfill run with its own `derivation_runs` row, so the checks below read the same.

```bash
# Dry run first; the counts stay in derivation_runs, so they survive a restart
bin/bitblocks rpc 'Bitblocks.Release.start_backfill("tx_steps", 0, 180_830)'
bin/bitblocks rpc 'Bitblocks.Release.backfill_status(1)'
bin/bitblocks rpc 'Bitblocks.Release.start_backfill("tx_steps", 0, 180_830, apply: true)'

# Every stored tx, by id
bin/bitblocks rpc 'Bitblocks.Release.start_tx_sizes_backfill(apply: true)'

bin/bitblocks rpc 'Bitblocks.Release.backfill_status()'
bin/bitblocks rpc 'Bitblocks.Release.pause_backfill(1)'
bin/bitblocks rpc 'Bitblocks.Release.resume_backfill(1)'
bin/bitblocks rpc 'Bitblocks.Release.cancel_backfill(1)'
```

One job takes `step:` of the range: 10,000 heights or 1,000,000 ids.
A pause or cancel lands when the range in flight finishes.
Each derivation has one active chain at a time, so a second start is refused.

**Across a restart.**
A deploy kills the job mid-range and Lifeline rescues it within 30 minutes.
The rerun closes the run the dead job left `running` as `abandoned`, then picks up the rows still below the version.
So the wait after a deploy is up to 30 minutes, with no operator action.

**A range longer than 30 minutes.**
Lifeline also rescues a job that is still alive, so each batch beats `heartbeat_at` on the chain.
A rescued copy that finds a beat under 15 minutes old snoozes, and stops once `next_from` has moved on.

**When a range keeps failing.**
A range that errors is retried with a growing wait, up to 20 attempts, which restarts also spend.
Then the chain reads `failed`, with the error, and `resume_backfill/1` carries on from the same range.
`rows_changed` in the status sums finished ranges only; `rows_below_version` is the check.

## Verifying a backfill

Each run ends by printing, and recording, the rows it changed and the rows still below the version in its range.

```
APPLIED: tx tallies for completed blocks 0..10000, v4, derivation run #12
  ...
  0 transaction(s) and 0 block(s) below the version in the range
  outcome: ok
```

The acceptance check is a fresh dry run over the whole range: it must report 0 transactions and 0 blocks below the version, with outcome ok.
Then `Release.derivation_runs()` shows that dry run as the latest, with `below version 0`.

Two kinds of row are stamped without a full answer, by design:

- A tx whose sats in is unknown (a previous output isn't stored) is stamped: the version computed it as unknown from what was stored.
  The run counts these under `sats_in_unknown`; `force: true` over the range recomputes them once the previous txs are stored.
- A tx that doesn't decode keeps its old script analysis stamp, so it stays below the version; the run counts these under `undecodable`.
  So the script analysis acceptance check is rows below the version equal to `undecodable`, every one of them a decode failure.
  These are real txs whose scripts `BSV.Tx.from_binary` can't parse as opcodes (on dev, 6 of 4,527, all `:decode_raised`); an analyzer that reads outputs by bytes would stamp them, with a version bump.
- A token output under a lock that names no address is stamped with `lock: "other"`: the version computed it as unknown, and the run counts these under `unknown_lock`.
  A token output whose tx can't be read keeps its old stamp and counts under `no_raw`, so the acceptance check for token recipients is rows below the version equal to `no_raw`.
