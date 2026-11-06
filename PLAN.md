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
`/syncing` has a durable pause, and `/syncing` and `/status` lead with one health line (`BitblocksWeb.HealthLine`, from `Ops.health/0`).

Ops queue: **#1 OPS-ROLLOUT**.
Script analysis to v7 runs as backfill chain #1 on prod (`Release.start_backfill`, [docs/DERIVED_DATA.md](docs/DERIVED_DATA.md#backfill-chains)), which also indexes Bitcom commands, so `/bitcom` gains proofs, files and routes as it goes.
Watch it with `Release.backfill_status(1)` and `GET /api/v1/status/derivations`.
When it finishes, run the completeness audit and repair (commands in #1); #1 closes when the audit reports zero deficit blocks.

Sync (2026-11-04): one loop, led by `Sync.Coordinator`, works upward from genesis and reports "Complete through block X of N known" ([docs/SYNCING.md](docs/SYNCING.md)).
Blocks up to 32 MB are one raw-block request each (node REST, `rest=1`); the 768 failed blocks and the gap above 957,301 are reached in order with no manual steps.
Follow-up: stream blocks over 32 MB through a bounded parser instead of the per-tx path.

## Shipped 2026-10-21 (closed)

#2 · #3 · #4 · #5 · #6 · #7 · #8 · #10 · #11 · #19 · #20 · #23.

Partly built: #21 export, with versioned snapshots at `/api/v1/bitcom/snapshots` (anchoring a hash needs a bitblocks-owned funded address) · #22 bit:// resolver and `GET /b/:txid` (adding the route needs that address) · #26 sponsorship: the ask moved off-site; bitblocks serves live numbers at `GET /api/v1/support` and a footer link (next steps in [docs/DONATION_ADDRESS.md](docs/DONATION_ADDRESS.md#fundraising-next-steps)).

## Built 2026-11-05, on prod once deployed

#35 the block stream and confirmation-order feeds · #34 tip-hash reorgs and a tx is confirmed only while its block is the chain's · #39 one sync writer, `NODE_ROLE=reader` · #17 BEEF at `/api/v1/txs/:txid/beef`, with Atomic BEEF by `?format=atomic`.
BEEF from anyone at `POST /api/v1/beef/verify` (inclusion only), and headers at `/api/v1/headers` ([docs/MERKLE_PROOFS.md](docs/MERKLE_PROOFS.md)).
#15 BCat files at `/content/bcat/:txid`: a real on-chain file is still to be checked.
#24 `Release.discover_bitcom`: built, for an operator to run.
#51 first seen and adoption per type on `/types/:id`, and `Release.type_candidates`: `propose_type` and the research export are still to come.

## Needs decision

#12 API-SURFACE · #13 EDGE-RATE.
#38: signed-out read-only block and transaction pages (the pages are built; the gate is Ryan's call).
A bitblocks-owned funded address (#21, #22, #26): the code is ready for it ([docs/BITCOM.md](docs/BITCOM.md#waiting-on-a-bitblocks-owned-funded-address)).
`/start` builder onboarding: built, admin only until published, Draft guidance and self-serve keys to decide ([docs/DEMOS_CAMPAIGN.md](docs/DEMOS_CAMPAIGN.md)).

## Next

Operator tools (#50): `/api/v1/ops/*` and `POST /api/v1/ops/mcp`, read-only, behind an `ops_read` key ([docs/OPS_API_AND_MCP.md](docs/OPS_API_AND_MCP.md#the-operator-api)).
Needs on prod: one key registered from its hash.
#25 REVIVE: unwriter's stack, one sprint per piece.
#29 PROJECTIONS: shared managed projections, prototype slice ([docs/MANAGED_SERVICES.md](docs/MANAGED_SERVICES.md)).
Steps 1–4 are built: the projection record (`Bitblocks.Projections`), hydrate (`GET /api/v1/projections/:id/txs`), status (`/status`) and webhook follow (`ProjectionWebhookWorker`).
From step 5, webhook SSRF protection is built (`Projections.WebhookTarget`), and hydrate and status follow the stable-prefix contract; requiring a tenant's key to read a projection needs #12 decided.
#30 COLLECTIONS: collections as projections. Grand Tardinians first (qart's holder check), then the Rexxie indexer ported in.
Grand Tardinians is live (`/api/v1/collections/grand-tardinians`, synced on prod 2026-10-29), with explicit verified membership and batch lookup for qart.
Rexxies (Run) is built on the same engine (`/api/v1/collections/rexxies`): membership proven on the class chain, holders traced by Run payload; traits stay catalog data.
`/collections` is the HTML index, with source links; `/collections/:id` lists any collection's items and holders.
Grand Tardinians is 999 items: the 1,494 in #30 counted transfers ([field note](docs/field-notes/2026-11-02-the-495-tardinians.md)).
#33 TXSTORE: raw tx bytes in S3 (one immutable CDN URL per txid), collections first; images parsed from raw txs on the fly at `/content/:outpoint`.
#32 BAP identity index is built ([docs/BAP.md](docs/BAP.md)): `/api/v1/bap/:bap_id`, with the rules for valid, accepted, rotation and newest written down.
Open: a real mainnet identity, by txid or once the sync reaches that era.
#49 TYPES: a public page per transaction type, then every tx typed (unmatched is `custom`), then types as CRUD resources.
Phase 1 is built: `/types`, `/types/:id` and `/api/v1/types`, with examples read only from existing indexes, and token and collection badges linking to their type.
Phase 2 is built (2026-11-04): stable template hashes (script analysis v7), `Bitblocks.TxTypes.Classifier` passing every vector in `priv/data/tx_types/output_types_v1.json`, the `classify_outputs` and `type_counts` pipeline steps, and counts per type (with `custom`) on `/types` and `/api/v1/types`.
P2PK and P2SH are types (classifier v2), so early coinbases no longer read `custom`.
Needs on prod, with Ryan's OK: the tx_types backfill (`Release.start_backfill("tx_types", ...)`) over completed blocks, once script analysis chain #1 finishes; until then `/types` says no block is typed yet.
Open: named combinations such as a listing, and the canonical opcode names agreed with the wallet project.
#48 SCRUBBER: admin three.js scrub from genesis to tip, and the first surface for accounting for misspends and burns.
Built: tile pyramid, incremental builds, `/chain-scrubber`, and reorg, classified-loss and burn layers ([docs/CHAIN_SCRUBBER.md](docs/CHAIN_SCRUBBER.md)).
Needs on prod: `Release.build_chain_tiles()` once, then a browser pass on the WebGL scene.
Shipped (2026-11-04): `/tx-graph` is the transaction flow space (every input an arc, scrubbed by a playhead), and `/annotations` places events on the chain, with an admin API ([docs/TX_FLOW.md](docs/TX_FLOW.md)).
Next: binary flow tiles for ranges past 50,000 txs, and growing the scene as new blocks complete.


## Deferred

#14 APP-SUPPORT · #27 personal funding.
