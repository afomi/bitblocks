# Chain scrubber

Admin exploration (#48): scrub the chain from genesis to tip in three.js, and the first visible surface for accounting for misspends and burns.
Route: `/chain-scrubber` (admin only; not in the sitemap).
Code: `Bitblocks.ChainTiles` (tiles), `Bitblocks.ChainScrubber` (rest and annotations), `BitblocksWeb.ChainScrubberLive`, `BitblocksWeb.ChainTileController`, `assets/js/chain_scrubber/tiles.mjs` (pure client logic), `assets/js/hooks/chain_scrubber.js` (WebGL).

## Decisions

**Block form: a column.**
Height is log10 of tx count, depth is log10 of size, colour is state.
Tx counts span seven orders of magnitude; the page says "log10 scale" on screen.
A rolled-up bucket draws its largest block (`tx_max`) as the column, with a thin inner column at the mean, and reddens by its share of blocks not completed.
A slab whose depth is size made the first 500,000 blocks vanish; a point on a line hid the gaps.

**Density field: grouped by tx class and value, not hashed by txid.**
Hashing txids into a grid is uniform noise and reads as texture only.
The grid is fixed at 16 rows by 64 columns: rows are tx classes (coinbase, plain transfer, one row per protocol by frequency, other), columns are log2 of output value.
Counted over the capped sample, so its size never depends on the block's tx count.

**Tiles live in Postgres, served from ETS.**
The container's disk does not survive a deploy (`restart.yml` replaces the container; no volume), and the S3 bucket for #33 is not provisioned yet.
`chain_tiles` is about a thousand rows and 17.5 MB.
`Bitblocks.ChainTiles.Cache` holds a copy in ETS, warmed at boot in one query off the supervisor path, and written through by the builder, so a tile request never queries the database.
Moving the store to S3 later is an adapter, not a redesign.
The `/tx-graph` flow tiles share the table and the cache at level 100 (`Bitblocks.FlowTiles`, `docs/TX_FLOW.md`); this page's manifest reads levels 0 to 3 only.

**Unchanged input changes nothing.**
Tiles are content-addressed: the bytes carry no build time, so the same blocks encode to the same hash and the builder skips the write.
A historic block moving to `completed` during backfill, or a reorg replacing a header, changes its leaf tile and that tile's ancestors; nothing else.
The browser fetches a small manifest (`no-cache`) and tile URLs that carry the hash (`?v=`), served `immutable`; a stale hash is a 404 and the client refetches the manifest once.

**A block that isn't `completed` draws as a gap**, and a rolled-up bucket says how many of its blocks are gaps instead of averaging them away.
A gap draws red at its header tx count, the same height its bucket gives it, so zooming in never flattens a header-only stretch.
In the bucket holding the tip, heights above the tip are not counted as gaps.

**The axis fits the chain, not the viewport.**
The column axis spans `axisDecades(largest block)` powers of ten, read from the coarsest tile at load: 4 decades for the first 200,000 blocks, 7 for the whole chain.
It stays fixed while scrubbing, so columns remain comparable; the status line names the axis top.
`/chain-scrubber?from=0&to=200000` opens on that stretch, and the axis fits the stretch instead of the whole chain.

**Only classified losses appear.**
The loss layer reads `priv/data/losses.json`, derived from the field note each entry cites, strong-confidence entries only; the five open Rexxie doubts (#46) stay off the layer.
Nothing is computed or guessed at runtime; a test holds the file to the note's data.

## Tile format

Little-endian; 32-byte header then up to 1,024 records.
Header: magic `BBT1`, version (1), level, record size, first height, count, span (`32^level`), 12 reserved bytes.

| Level | Record | Bytes | Fields |
|---|---|---|---|
| 0 | one block | 16 | time u32, size f32, num_tx u32, state u8 (0 missing, 1 pending, 2 header_only, 3 header_synced, 4 txs_queued, 5 txs_syncing, 6 completed, 7 failed), 3 pad |
| 1..3 | `32^L` blocks | 64 | present u32, completed u32, time_min u32, time_max u32, size_sum f64, tx_sum f64, size_max f32, tx_max u32, hist 8 x u16, 8 reserved |

Rollup rules, per field: `present` and `completed` are counts (gap count = span minus completed); time is min and max; size and tx are sum and max; `hist` counts present blocks per `floor(log10(num_tx))` bin, clamped to eight bins.
A missing row counts in nothing.
Level `L` tile `t` covers heights `[t * 1024 * 32^L, (t + 1) * 1024 * 32^L)`; level 2 holds the whole chain in one tile until height 1,048,576, level 3 until 33 million.

The client picks the finest level whose visible records fit a 4,096 budget, fetches only the tiles its viewport covers, and draws one `InstancedMesh`.
The per-block density grid is computed on rest, never precomputed: 970,000 grids would be 2 GB of mostly noise, and a rest reads at most the capped sample anyway.

## Budget

Measured on a laptop with `mix test --only scale` (synthetic 970,000 blocks; real rows for the database path); prod figures are estimates and labelled.

| Item | Number | How |
|---|---|---|
| Leaf tile | 16,416 B (948 tiles, 15.5 MB) | measured |
| Level 1 | 30 tiles, 1.94 MB | measured |
| Level 2 (whole chain) | 1 tile, 60,704 B | measured |
| Level 3 | 1 tile, 1,952 B | measured |
| Total stored, 970k blocks | 17.5 MB in Postgres, the same in ETS | measured |
| First frame | manifest ~19 KB (980 16-char hashes) + level 2 tile 61 KB, about 80 KB | manifest estimated, tile measured |
| Pure pipeline, 970k blocks | encode leaves 47 ms, roll up three levels 516 ms, hash 5 ms | measured |
| Database path | 1.9 ms per leaf tile (one 1,024-row range read on the height index), 2 ms for an incremental no-op | measured on 50,000 rows |
| Full build, 948 leaves | ~2 s locally; 10 to 30 s on prod with wide rows and a loaded disk | estimated |
| Full build DB load | 948 index-range reads of 1,024 rows plus about 1,000 tiny hash reads and ~1,000 upserts; `blocks` only | by construction |
| Incremental build | one `updated_at` index probe; when the tip moved, 1 leaf read + 3 rollups, well under a second | measured no-op, structure for the rest |

## Rest (the one tx-level read)

`Bitblocks.ChainScrubber.rest/2` reads the block row by height, then at most 2,000 transactions by `block_hash` under `SET LOCAL statement_timeout = 2000`.
A cancelled read answers `kind: "unavailable", reason: "timeout"`; it never hangs.
Below 10,000 txs the answer is one mark per tx (the sample); above, the density grid.
No new `transactions` index; no `OFFSET`.

## Annotations

`Bitblocks.ChainScrubber.annotations/0`: every `reorgs` row at its `fork_height` (evidence `/reorgs`), every classified loss at the spending tx's height (evidence `/transactions/:txid`, plus the field note URL), and each placed chain annotation.
Burns are not marked here: each is a block total rather than one tx, so they live on the admin page `/burns` (`Bitblocks.Burns`), which lists the blocks and opens each to the stored txs that burned.
Reading `blocks` keeps the layer off `transactions`; a read over 5 seconds drops the layer and logs it.
The client draws them as markers above the column; a click opens the evidence.

## Ops

```bash
# once, after the migration; queued on the chain_tiles lane (concurrency 1)
bin/bitblocks rpc 'Bitblocks.Release.build_chain_tiles()'
# or in this shell, printing the elapsed time
bin/bitblocks rpc 'Bitblocks.Release.build_chain_tiles(inline: true)'
# tile counts per level, cache size, last builds
bin/bitblocks rpc 'Bitblocks.Release.chain_tiles_status()'
```

The cron (`*/5 * * * *`) runs `ChainTilesWorker` in incremental mode: a no-op until a full build exists and when no block changed.
Nothing starts on deploy.
Migrations: `chain_tiles` and `chain_tile_builds` (new, small), and a concurrent index on `blocks (updated_at)`.

Tests: `test/bitblocks/chain_tiles/codec_test.exs`, `test/bitblocks/chain_tiles_test.exs`, `test/bitblocks/chain_scrubber_test.exs`, `test/bitblocks/workers/chain_tiles_worker_test.exs`, `test/bitblocks_web/controllers/chain_tile_controller_test.exs`, `test/bitblocks_web/live/chain_scrubber_live_test.exs`, `cd assets && npm test`.
