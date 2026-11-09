# Transaction flow and chain annotations

Admin exploration beside the chain scrubber (#48).
`/tx-graph` draws a range of blocks as a space you fly through and scrub: every tx, every output and every input as an arc back to the output it spends.
`/annotations` places events on the chain (forks, upgrades, halvings, mintings, milestones, world events), and both scenes draw them.

Code: `Bitblocks.ChainFlow` (the graph for a range), `BitblocksWeb.ChainFlowController` (`GET /chain-scrubber/flow`), `BitblocksWeb.TxGraphLive`, `assets/js/tx_flow/layout.mjs` (pure placement and stats), `assets/js/hooks/tx_flow.js` (WebGL).
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

**Controls.**
The range form loads `?from=&to=` (at most `ChainFlow.max_blocks/0`, 5,000 blocks, and 50,000 txs, cut at a whole block).
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

### Scale

JSON and one draw call per layer carry tens of thousands of txs.
Ranges of millions need the binary tiles of the chain scrubber's design: a per-block flow summary (input age by value) for the far view, and fine tiles in S3 for the near one.
That is the next step, and the layout functions already work on flat typed arrays.

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

Tests: `test/bitblocks/chain_flow_test.exs`, `test/bitblocks/annotations_test.exs`, `test/bitblocks_web/controllers/chain_flow_controller_test.exs`, `test/bitblocks_web/controllers/api/annotation_controller_test.exs`, `test/bitblocks_web/live/tx_graph_live_test.exs`, `test/bitblocks_web/live/annotation_live_test.exs`, `cd assets && npm test`.
