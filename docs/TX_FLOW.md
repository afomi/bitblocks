# Transaction flow and chain annotations

Admin exploration beside the chain scrubber (#48).
`/tx-graph` draws a range of blocks as a space you fly through and scrub: every tx, every output and every input as an arc back to the output it spends.
`/annotations` places events on the chain (forks, upgrades, halvings, mintings, milestones, world events), and both scenes draw them.

Code: `Bitblocks.ChainFlow` (the graph for a range), `BitblocksWeb.ChainFlowController` (`GET /chain-scrubber/flow`), `Bitblocks.FlowTiles` and `Bitblocks.FlowTiles.Codec` (the far view's binary tiles), `BitblocksWeb.FlowTileController` (`GET /chain-scrubber/flow-tiles/*`), `Bitblocks.Workers.FlowTilesWorker`, `BitblocksWeb.TxGraphLive`, `assets/js/tx_flow/layout.mjs` (pure placement and stats), `assets/js/hooks/tx_flow.js` (WebGL).
Annotations: `Bitblocks.Annotations`, `BitblocksWeb.AnnotationLive`, `BitblocksWeb.Api.AnnotationController`, seed events in `priv/data/chain_annotations.json`.

## The flow space

**Placement is fixed by the data, never solved.**
Height runs along x.
A block's txs fill a sunflower disc around the spine, the coinbase at the centre and tx k at radius proportional to sqrt(k), at k times the golden angle.
Outputs sit just off their tx; an input is an arc from the output it spends, lifted by log2 of the coins' age in blocks.
A tx lands in the same place on every load, and scrubbing never moves a node.

**The playhead is a shader uniform.**
Every vertex carries the height it appeared at and, for an output, the height that spent it.
At playhead H, txs mined by H are lit and later ones are faint ghosts.
An output created by H and not yet spent glows gold (the live UTXO set); a spent one fades to ash.
An arc appears in the block that spends it, flashes, and settles.
Moving the playhead costs no CPU work and no refetch.
Reduced motion turns off the shimmer, the flash and camera easing.

**"Unspent" means "no spend stored yet".**
Spends come from `spend_index`, so they are only as complete as our sync; the payload names `spends_known_through` (`Sync.complete_through/0`), and the status line repeats it.

**The scene grows with the sync.**
When a block in the open range completes, or a reorg replaces one, `TxGraphLive` pushes `flow_grew` and the hook reads the range again, at most once every 10 seconds.
The camera, playhead and selection stay where they were, and since placement is fixed by the data, nothing already drawn moves.
Open a range that reaches past our tip, and its blocks join the scene as they complete.
In the far view a block joins once the flow tiles reach it, within five minutes of `complete_through` passing it.

**Controls.**
The range form loads `?from=&to=`, at most `FlowTiles.max_blocks/0`, 100,000 blocks.
A range within the near view's caps (`ChainFlow.max_blocks/0`, 5,000 blocks, and `ChainFlow.max_txs/0`, 50,000 txs) draws every tx; past them it draws the far view from the flow tiles.
Before the flow tiles are built, a long range falls back to the near view, cut at a whole block under its caps.
`?txid=` opens the 200 blocks around a stored tx and lights its lineage.
Drag to orbit, scroll to zoom, click a tx to light its ancestors and descendants in the range.
The minimap under the scene shows txs per block, spends and events; click or drag it to move the playhead.
Arrow keys step a block (Shift for ten), Space plays, F frames the range, Esc clears the selection.

### Payload

`GET /chain-scrubber/flow?from=0&to=999` (admin), arrays rather than objects:

| Key | Shape |
|---|---|
| `blocks` | `[height, time, num_tx, stored_txs]` |
| `txs` | `[height, txid, coinbase 0/1, n_in, sats_out]`, in block order |
| `outputs` | per tx, `[[sats, spent_height or -1], ...]` |
| `edges` | `[source, vout, target, sats or -1]`; a source below 0 is `external[-1 - source]` |
| `external` | `[txid, height or -1]`: sources outside the range |

Values are exact satoshis from each row's raw hex (`Chain.RawTx.flows/1`).
The read runs under an 8-second statement timeout and answers 503 on a timeout.

## The far view: flow tiles (#67)

Past 50,000 txs the scene draws one node per block, sized by the txs it holds, and one arc per age bin of the coins its inputs spend, from the spine at that age back to the block, brighter with more inputs.
A range of more than 3,000 blocks groups them, so a node is `ceil(span / 3000)` blocks and keeps their sums.
The playhead, the minimap, the annotations and live growth work as in the near view; the readout counts txs, spends and outputs made by the playhead.
A click on a node lights its arcs and links "Every tx", which opens those blocks in the near view.

**A tile request makes no query.**
The client reads `GET /chain-scrubber/flow-tiles/manifest` (`no-cache`), then `GET /chain-scrubber/flow-tiles/:idx?v=<hash>` (immutable) for each tile the range covers.
Both are served from `Bitblocks.ChainTiles.Cache` (ETS) behind the `:admin_data` gate; `test/bitblocks_web/controllers/flow_tile_controller_test.exs` holds that a range's manifest and tiles run no database query.

**A block's summary never changes once it is built.**
It is how the block spends: its inputs spend outputs of earlier blocks, all stored once the block is below `Sync.complete_through/0`.
So the builder walks upward from the highest height built to `complete_through` and never revisits a block.
What later spends a block's outputs is not in its summary, since that changes with every later block; the near view shows it.
A reorg or a reopened block below the built height needs `Release.build_flow_tiles(from: h)`.

**Storage: the `chain_tiles` table at level 100.**
No new table and no migration: the flow tiles share the chain scrubber's ETS cache, warmed at boot, written through by the builder and reconciled across nodes.
96 bytes a block: about 38 MB for 400,000 blocks, the same in ETS.
The chain scrubber's manifest reads its own levels only.

### Tile format

Little-endian; a 32-byte header then up to 1,024 records, one per block; tile `t` covers heights `[t * 1024, (t + 1) * 1024)`.
Header: magic `BBF1`, version (1) u8, age bins (16) u8, record bytes (96) u16, first height u32, count u32, 16 reserved bytes.

| Field | Type | Meaning |
|---|---|---|
| `time` | u32 | block time |
| `num_tx` | u32 | the header's tx count |
| `stored` | u32 | txs we hold |
| `n_in` | u32 | inputs of the non-coinbase txs |
| `n_out` | u32 | outputs |
| `unknown` | u32 | inputs whose source we don't hold, so no age |
| `sats_out` | f64 | sats out, or -1 when a tx in the block has no stored tally |
| `hist` | 16 x u32 | inputs by the age of the coins they spend: bin 0 is age 0, bin `b` is `2^(b-1) <= age < 2^b`, bin 15 is `age >= 16,384` blocks |

A record of zeros is a block not built.
The histogram counts inputs, not value: `spend_index` carries no amount, and reading every source tx's raw bytes would make the build far heavier.

### Build

Per batch of about 20,000 txs: the `blocks` rows, one grouped tally of `transactions` on the height index, and one grouped join of `spend_index` (on `spending_txid`) to the source rows (on `txid`) for the ages, under a 120-second statement timeout.
A run stops at a two-minute budget, at a block boundary, writing what it built; while behind, the worker queues the next run, so a long build is a chain of short jobs on the `:chain_tiles` lane that a deploy only pauses.
The cron (`2-59/5 * * * *`) resumes after the highest height built, and does nothing until a person starts a build.

```bash
# once: from genesis (or from: h) up to complete_through, as a chain of jobs
bin/bitblocks rpc 'Bitblocks.Release.build_flow_tiles()'
# how far they reach
bin/bitblocks rpc 'Bitblocks.Release.flow_tiles_status()'
```

## Annotations

An annotation has a kind, a title, notes, a source URL, and at least one anchor: a height, a txid, or a moment (`occurred_at`).
It draws at `resolved_height`, derived on every save:

1. a txid we hold: that tx's block height;
2. else the height given;
3. else the first block mined at or after `occurred_at`.

A date before the genesis block stays off the chain (`resolved_by: "before_genesis"`).
A tx we haven't synced yet, or a date past our tip, leaves it unplaced; "Place again" on `/annotations` (`Annotations.resolve_all/0`) retries.
Every change broadcasts on `"chain_annotations"`, so open scrubbers redraw.

"Add curated events" (`Annotations.seed/0`) loads `priv/data/chain_annotations.json`: the genesis block, the first spend, Pizza Day, the forks, the Genesis upgrade, the halvings and a few world events, each with a source.
It adds only what isn't there yet (matched on kind and title).

### API (admin session)

```
GET    /api/v1/annotations          ?from=&to= by drawn height, ?kind=
GET    /api/v1/annotations/:id
POST   /api/v1/annotations          {"annotation": {...}} or the fields at the top level
PATCH  /api/v1/annotations/:id
DELETE /api/v1/annotations/:id
```

Writes must be `application/json` (415 otherwise).
That is the CSRF guard: a browser sends the session cookie by itself, but a cross-site form can't send a JSON body, and a cross-site `fetch` with one needs a CORS preflight these routes never grant.

## The first spend

Block 170, 2009-01-12 03:30:25 UTC: `f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16` spends block 9's coinbase (50 coins), 10 to Hal Finney and 40 back.
`test/bitblocks/chain_flow_test.exs` holds that edge, from the real raw txs in `test/support/data/first_spend_txs.json`.

Tests: `test/bitblocks/chain_flow_test.exs`, `test/bitblocks/flow_tiles_test.exs`, `test/bitblocks/workers/flow_tiles_worker_test.exs`, `test/bitblocks_web/controllers/flow_tile_controller_test.exs`, `test/bitblocks/annotations_test.exs`, `test/bitblocks_web/controllers/chain_flow_controller_test.exs`, `test/bitblocks_web/controllers/api/annotation_controller_test.exs`, `test/bitblocks_web/live/tx_graph_live_test.exs`, `test/bitblocks_web/live/annotation_live_test.exs`, `cd assets && npm test`.
