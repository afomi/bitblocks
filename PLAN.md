# Bitblocks — Plan

Tasks live in GitHub Issues: https://github.com/afomi/bitblocks/issues
Labels carry status: `now` (single active thread), `next`, `needs-decision`, `deferred`; `from-inbox` marks handoff-sourced work.
Docs entrypoint: `docs/INDEX.md`.
Design rules (authoritative for every page's look and markup): [DESIGN.md](DESIGN.md).
Completed-work history (pre-Issues): `product-cycle/BACKLOG.md`.

## Now

**Full speed until about 2026-11-19 (Ryan, 2026-11-05), then archive.**
See how far two weeks gets us: backfills, the size work, more worker slots, block objects and CloudFront all go ahead.
Then archive to S3, and restore and resync when funded; the sync carries on from `complete_through` by itself.
Rehearse a restore early, while the database is small: an archive that has never been restored isn't a backup yet.
What to measure: the header totals, which say what the whole chain costs to hold.

**#18 BITCOM**: be a live, maximally useful Bitcom registry (unwriter's Bitcom), then keep reviving the rest of his stack (#25).
Current system doc: `docs/BITCOM.md`.

Closed 2026-11-04: #36 · #37 · #40 · #41 · #43 · #44 · #46.
`/sync` has a durable pause, and `/sync` and `/status` lead with one health line (`BitblocksWeb.HealthLine`, from `Ops.health/0`).

Ryan's ops queue: **#1 OPS-ROLLOUT**. The code is deployed (b8b7757, 2026-10-21).
Run one `Release.analyze_transactions/1` pass on prod to reach v6; it also indexes Bitcom commands, so `/bitcom` gains proofs, files and routes.
It runs for hours, so start it detached (see #1).
Then run the completeness audit and repair, and confirm zero deficit blocks.

Sync (2026-11-04): one loop, led by `Sync.Coordinator`, works upward from genesis and reports "Complete through block X of N known" ([docs/SYNCING.md](docs/SYNCING.md)).
Blocks up to 32 MB are one raw-block request each (node REST, `rest=1`); the 768 failed blocks and the gap above 957,301 are reached in order with no manual steps.
Follow-up: stream blocks over 32 MB through a bounded parser instead of the per-tx path.

## Shipped 2026-10-21 (closed)

#2 · #3 · #4 · #5 · #6 · #7 · #8 · #10 · #11 · #19 · #20 · #23.

Partly built: #21 export (snapshot anchoring needs a bitblocks-owned address) · #22 bit:// resolver (acting as a provider needs #15 and that address) · #26 sponsorship: the ask moved off-site; bitblocks serves live numbers at `GET /api/v1/support` and a footer link (next steps in [docs/DONATION_ADDRESS.md](docs/DONATION_ADDRESS.md#fundraising-next-steps)).

## Needs decision

#9 seeded protocols vs. on-chain proof (/bitcom already derives tiers from proof; decide whether /protocols follows) · #12 API-SURFACE · #13 EDGE-RATE.

## Next

#25 REVIVE: unwriter's stack, one sprint per piece.
#29 PROJECTIONS: shared managed projections, prototype slice ([docs/MANAGED_SERVICES.md](docs/MANAGED_SERVICES.md)).
Steps 1–4 are built: the projection record (`Bitblocks.Projections`), hydrate (`GET /api/v1/projections/:id/txs`), status (`/status`) and webhook follow (`ProjectionWebhookWorker`).
Step 5 (tenant keys and quotas, with SSRF protection on webhook URLs) is next; it needs #12 and #13 decided.
#30 COLLECTIONS: collections as projections. Grand Tardinians first (qart's holder check), then the Rexxie indexer ported in.
Grand Tardinians is live (`/api/v1/collections/grand-tardinians`, synced on prod 2026-10-29), with explicit verified membership and batch lookup for qart.
Rexxies (Run) is built on the same engine (`/api/v1/collections/rexxies`): membership proven on the class chain, holders traced by Run payload; traits stay catalog data.
`/collections` is the HTML index, with source links; `/collections/:id` lists any collection's items and holders.
Grand Tardinians is 999 items: the 1,494 in #30 counted transfers ([field note](docs/field-notes/2026-11-02-the-495-tardinians.md)).
#33 TXSTORE: raw tx bytes in S3 (one immutable CDN URL per txid), collections first; images parsed from raw txs on the fly at `/content/:outpoint`.
Queued after #30: #32 BAP identity index (qart request).
#49 TYPES: a public page per transaction type, then every tx typed (unmatched is `custom`), then types as CRUD resources.
Phase 1 is built: `/types`, `/types/:id` and `/api/v1/types`, with examples read only from existing indexes, and token and collection badges linking to their type.
Phase 2 is built (2026-11-04): stable template hashes (script analysis v7), `Bitblocks.TxTypes.Classifier` passing every vector in `priv/data/tx_types/output_types_v1.json`, the `classify_outputs` and `type_counts` pipeline steps, and counts per type (with `custom`) on `/types` and `/api/v1/types`.
Needs on prod, with Ryan's OK: `Release.backfill_script_analysis` to v7 (re-decodes every row) and `Release.backfill_tx_types` over completed blocks; until then `/types` says no block is typed yet.
Open: P2PK and P2SH types (early coinbases read `custom` until they exist), named combinations such as a listing, and the canonical opcode names agreed with the wallet project.
#48 SCRUBBER: admin three.js scrub from genesis to tip, and the first surface for accounting for misspends and burns.
Built in the working tree (2026-11-03): tile pyramid, incremental builds, `/chain-scrubber`, reorg and classified-loss layers ([docs/CHAIN_SCRUBBER.md](docs/CHAIN_SCRUBBER.md)).
Needs on prod, after deploy: `Release.build_chain_tiles()` once; a browser pass on the WebGL scene.
Shipped (2026-11-04): `/tx-graph` is the transaction flow space (every input an arc, scrubbed by a playhead), and `/annotations` places events on the chain, with an admin API ([docs/TX_FLOW.md](docs/TX_FLOW.md)).
Next: binary flow tiles for ranges past 50,000 txs, and growing the scene as new blocks complete.


## Deferred

#14 APP-SUPPORT · #15 BCAT-REASSEMBLE · #17 BEEF · #24 historical Bitcom discovery · #27 personal funding.
