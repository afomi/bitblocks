# WhatsOnChain use

Where Bitblocks calls WhatsOnChain (`Bitblocks.Woc`), what each call serves, and what our own index would answer instead.
Current system for the rule and the collection trace; the table lists the uses still to decide.

## The rule

Ryan, 2026-11-10:

> at this point, we should not fall back to whats on chain except for rawtx. we shouldn't be caching their stuff. sometimes they offer endpoints we can't accurately provide yet.

How we apply it:

- **WhatsOnChain is a raw-tx source.** Fetching a tx's bytes by txid (`Woc.txs/1`) is fine once the bytes hash to the txid: then they are the chain's bytes, and ours.
- **Every other answer comes from our own data:** spent-by and unspent (`spend_index`, by the `Bitblocks.Chain.Utxos` rule), owner, values and history (stored txs).
- **Where our index can't answer yet, say so.** A spend may sit above `Sync.complete_through/0`; the answer is `unknown`, `partial` or `untraced`, with a reason naming the height our index reaches, never WhatsOnChain's answer.
- **Don't store WhatsOnChain's facts as ours.** A row built from a WhatsOnChain tx is built from its verified bytes, not from WhatsOnChain's decoded JSON.

## Collection tracing (done)

`Bitblocks.OrdinalCollections` no longer calls `Woc.spent/2`.

- The walk (`sync/3`, past the hint) and the trace (`trace/2`, `trace_batch/1`) ask `Chain.Utxos.outpoints/2` where each outpoint went.
- A spend row whose spender is in a block we store is followed; no row is unspent only when our index is complete through our tip.
- Anything else stops there: the trace says `partial` (or `untraced`, for an item never placed past its origin) with a reason such as "no spend of `<outpoint>` in our spend index, which is complete through block N of M; a spend from block N+1 on isn't indexed yet".
  A walk that stops there is not `complete`, so `absence/2` answers `unknown` rather than `false`.
- Input values (the 1Sat sat offset, a Run jig's value outside Run) are read from stored txs; only the raw txs we lack are fetched from WhatsOnChain, in one bulk, deduplicated request per hop.
- `import_txs/1` builds each row from the verified bytes (`RawBlock.tx_json/2`), so its inputs, outputs and spend rows are read by us, and takes the block height from our own header when we hold the block.
- A trace batch (`CollectionTraceWorker`, 20 items) goes hop by hop across its items and logs its spend lookups, local tx reads, raw-tx fetches, WhatsOnChain requests and elapsed time.
  An item still where the last trace left it costs one lookup and no tx read.
- `trace_source` is `index` on every answer from here on; rows traced before keep `whatsonchain`.
- The test stub (`Bitblocks.WocStub`, `:woc_raw_tx_only`) raises on any endpoint but the raw-tx fetch, and every collection test runs with it set.

What changes: `current` now needs our index complete through our tip.
Until the sync reaches the tip, every item's trace ends `partial` at its last outpoint our index can place, with its owner cleared, and the walks of collections found by their chain alone stop at the first link our index can't answer for.

How it reads (landed 2026-11-19, https://github.com/afomi/bitblocks/issues/95):

- The known collections all sit above the sync's stop height (`Sync.stop_height/0`), so until the storage plan lets the sync climb to the tip, a re-traced item reads `partial` or `untraced` with no owner.
- An item answers with a reason naming the block our index is complete through, such as "no spend of `<outpoint>` in our spend index, which is complete through block N of M; a spend from block N+1 on isn't indexed yet".
- `/collections` and each collection's page say how far our index reaches and that an item past it reads "Owner unknown" until the sync gets there (`CollectionComponents.trace_coverage/1`); nothing shows once the index reaches our tip.
- `GET /api/v1/collections/:id/items` and the lookup carry `meta.indexed_through_height` and `meta.tip_height`.
- Nothing re-traces by itself: rows traced before keep their answer, with `trace_source` `whatsonchain`, until a collection sync (`Release.sync_ordinal_collection/1`) or an item's `?refresh=1` traces them again.

## The uses still to decide

"Ryan decides" is `pending` wherever the change would lose function.

| Use | Where | What it serves | Our own answer | Exists yet | Ryan decides |
| --- | --- | --- | --- | --- | --- |
| `Woc.spent/2` | `BitblocksWeb.Api.UtxoController` (`GET /api/v1/utxo/:txid/:vout/owner`) | Spent-by when our answer is `unknown` (spends above `complete_through`), or when we don't hold the tx; VoteSmash checks ticket ownership with it | `Utxos.outpoint/2` alone: `unknown` with `indexed_through_height` until the sync reaches the tip | Yes below `complete_through`; no above it | pending |
| `Woc.address_history/2` via `Woc.AddressHistory.above/2` | `Chain.AddressHistory` (`GET /api/v1/addresses/:address/history`) | Rows above `complete_through`, marked `source: whatsonchain`; cached in ETS for 5 minutes | Our rows through `complete_through`, `status: partial` above it | Yes below `complete_through`; no above it | pending |
| `Woc.address_history/2` via `Woc.AddressHistory.above/2` | `Support.Recent`, `Bitblocks.Support` (`GET /api/v1/support`) | BSV received above `complete_through`; the sats are read from WhatsOnChain's decoded `vin`/`vout` JSON, not the bytes; cached | Received through `complete_through`, `received_through_height` saying so | Yes below `complete_through`; no above it | pending |
| `Woc.address_history/2` | `Bitcom.Discovery` (#24, `Release.discover_bitcom/2`) | Historical Bitcom commands for an address; `bitcom_commands` rows stored with WhatsOnChain's block height | The sync reaching those blocks logs the same commands at ingest | Yes, as the sync climbs | pending |
| `Woc.chain_tip/0` | `SyncProgress` (/syncing), `Woc.AddressHistory` | A public reference tip beside ours, and how far WhatsOnChain's history reaches | Our node's tip and our headers | Yes | pending |
| `Woc.block_txids/1` | `Chain.TxidSource` (sync fallback) | A block's txid list when our node can't serve it; refused unless it rebuilds the header's merkleroot | Our node's `getblock(hash, 1)` | Yes when the node serves it | pending (verified like bytes; recommend keep) |
| `Woc.txs/1` decoded JSON | `Chain.TxSources` (sync fallback bodies) into `TxIngest` | Tx bodies when our node is pruned or down; the hex is checked against the txid, but the row's inputs, outputs and spend rows come from WhatsOnChain's decoded `vin`/`vout` | Rebuild the row from the verified bytes (`RawBlock.tx_json/2`), as `import_txs/1` now does | Yes | pending (no function lost; recommend fix) |
| WhatsOnChain's `blockhash` and `blockheight` | `OrdinalCollections.import_txs/1` (both), `TxTypes.Proposal` (height, in a draft) | Which block an imported tx sits in; a hash we don't hold makes the tx not in a stored block, so `Chain.Utxos` won't call it spent or unspent | A merkle proof against our header, or the sync storing the block | Partly (height from our header when we hold it) | pending |

Raw-tx fetches, kept: `OrdinalCollections.import_txs/1`, `TxStore.raw_or_fetch/1`, `Bcat`, `TxTypes.Proposal`, the tx fetch inside `Woc.AddressHistory`, and `UtxoController`'s output address (read from bytes checked against the txid).
`/api/v1/woc/*` (`BitblocksWeb.Api.WocController`) calls no WhatsOnChain endpoint: it serves our own data in WhatsOnChain's shapes.

A known cost: `import_txs/1` counts a tx as held only when its `raw` is in the row, so a tx whose bytes live only in the tx store is fetched again.

## Proposal: tracked outputs, kept current by ingest

Out of scope for the first branch; written up for a decision.

Today a collection is re-traced by polling: each sync walks every item from where it sat.
A table of the outputs we track lets ingest move an item the moment the sync stores the tx that spends it, with no polling and no WhatsOnChain.

### Schema sketch

```elixir
create table(:tracked_outputs) do
  # The outpoint an item sits at now (its current_outpoint).
  add :txid, :string, null: false
  add :vout, :integer, null: false
  # What sits there: a collection item today; tokens or listings could join.
  add :kind, :string, null: false
  add :ref_id, :bigint, null: false
  timestamps(updated_at: false)
end

create unique_index(:tracked_outputs, [:txid, :vout])
create index(:tracked_outputs, [:kind, :ref_id])
```

One row per item, written whenever a trace sets `current_outpoint` (and removed when an item ends).
It is small (one row per item, about 13,000 for the known collections), so a plain migration is fine; it doesn't touch `transactions`.

### Where it hooks

- A `:tx` step, `Bitblocks.Chain.TxPipeline.Steps.MoveTrackedOutputs`, one module plus one line in `@steps` after `RecordSpends` (docs/TX_PIPELINE.md, "Adding a step").
- `run/2` looks the tx's inputs up in `tracked_outputs` by `(txid, vout)`: one query per tx through the unique index, and nothing more for the many txs that spend no tracked output.
- For each hit, it runs the item's protocol `landing/4` on the tx it already holds, reading input values from stored txs, and writes the item's new `current_outpoint`, owner and trail, and the new `tracked_outputs` row.
  A landing that needs a tx we don't hold leaves the item `partial` with the reason, for the next trace.
- `Chain.TxPipeline.CatchUp` brings blocks completed before the step up to it, like any other step; the step's `version/0` and a derivation stamp make that visible on `GET /api/v1/status/derivations`.
- Reorgs: `Reorgs.Reconcile` already sends an item with a hop in a replaced block back to its origin (`OrdinalCollections.rewind_removed/1`); its `tracked_outputs` row goes back with it.

### What it changes

- `current` still needs our index complete through our tip; what goes away is the polling.
- A collection is traced once, then each item moves as the sync stores the block that moves it.
- The trace workers remain for a first trace and for items left `partial`.
