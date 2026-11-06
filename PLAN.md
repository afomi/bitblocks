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
Closed 2026-11-05 and 06: #9 · #12 · #13 · #14 · #17 · #21 · #22 · #30 · #34 · #35 · #38 · #39.
`/syncing` has a durable pause, and `/syncing` and `/status` lead with one health line (`BitblocksWeb.HealthLine`, from `Ops.health/0`).

Ops queue: **#1 OPS-ROLLOUT**.
Script analysis chain #1 finished 2026-11-06, so `tx_steps`, then tallies, then `tx_types` follow, each with Ryan's OK on its dry-run count.
#1 closes when the audit reports zero deficit blocks.
Every open issue labelled `ops` is one prod step away from closing: #24 · #47 · #48 · #50.

Sync (2026-11-04): one loop, led by `Sync.Coordinator`, works upward from genesis and reports "Complete through block X of N known" ([docs/SYNCING.md](docs/SYNCING.md)).
Blocks up to 32 MB are one raw-block request each (node REST, `rest=1`); the failed blocks and the gap above 957,301 are reached in order with no manual steps.
Larger blocks: #66.

## Shipped 2026-10-21 (closed)

#2 · #3 · #4 · #5 · #6 · #7 · #8 · #10 · #11 · #19 · #20 · #23.

## Built 2026-11-05, on prod once deployed

#35 the block stream and confirmation-order feeds · #34 tip-hash reorgs and a tx is confirmed only while its block is the chain's, with protocol rewinds in #52 and #53 · #39 one sync writer, `NODE_ROLE=reader` · #17 BEEF at `/api/v1/txs/:txid/beef`, with Atomic BEEF by `?format=atomic`.
BEEF from anyone at `POST /api/v1/beef/verify` (inclusion only), and headers at `/api/v1/headers` ([docs/MERKLE_PROOFS.md](docs/MERKLE_PROOFS.md)).
Interop kit, first version: open test vectors at `/interop/vectors/v1.json`, an admin check page at `/start/interop` and the pattern ([docs/INTEROP_KIT.md](docs/INTEROP_KIT.md)).
#15 BCat files at `/content/bcat/:txid`, read against real heads from the chain.
#24 `Release.discover_bitcom`: built, for an operator to run.
#69 token holders read from the lock on either side of the envelope, with `Release.backfill_token_recipients`: built, for an operator to run.
#51 first seen and adoption per type on `/types/:id`, and `Release.type_candidates`: `propose_type` and the research export are still to come.

## Needs decision

#58 a Bitblocks-owned funded address, which unblocks the registry anchor, the route provider and public accounts ([docs/BITCOM.md](docs/BITCOM.md#waiting-on-a-bitblocks-owned-funded-address)).
#59 publish `/start`, with trial keys ([docs/DEMOS_CAMPAIGN.md](docs/DEMOS_CAMPAIGN.md)).
#60 BEEF acceptance defaults · #61 pricing · #62 the bench link · #63 standards register entries.
#26 sponsorship: donation address, sponsor URL and cost lines; bitblocks serves live numbers at `GET /api/v1/support` ([docs/DONATION_ADDRESS.md](docs/DONATION_ADDRESS.md#fundraising-next-steps)).
#57 the size backfill's count · #54 the node runbook, on the box.

## Two-week push

#55 archive and rehearse a restore, by about 2026-11-19 · #56 sync throughput.

## Next

Operator tools (#50): `/api/v1/ops/*` and `POST /api/v1/ops/mcp`, read-only, behind an `ops_read` key ([docs/OPS_API_AND_MCP.md](docs/OPS_API_AND_MCP.md#the-operator-api)).
Needs on prod: one key registered from its hash, then a session reads `sync_live`.
#25 REVIVE: unwriter's stack, one sprint per piece.
#29 PROJECTIONS: shared managed projections, prototype slice ([docs/MANAGED_SERVICES.md](docs/MANAGED_SERVICES.md)).
Steps 1–4 are built: the projection record (`Bitblocks.Projections`), hydrate (`GET /api/v1/projections/:id/txs`), status (`/status`) and webhook follow (`ProjectionWebhookWorker`).
Step 5 is done: webhook SSRF protection (`Projections.WebhookTarget`), the stable-prefix contract, and a key or session to read. Step 6, the second and third tenants, is next.
#30 COLLECTIONS: collections as projections. Grand Tardinians first (qart's holder check), then the Rexxie indexer ported in.
Grand Tardinians is live (`/api/v1/collections/grand-tardinians`, synced on prod 2026-10-29), with explicit verified membership and batch lookup for qart.
Rexxies (Run) is built on the same engine (`/api/v1/collections/rexxies`): membership proven on the class chain, holders traced by Run payload; traits stay catalog data.
`/collections` is the HTML index, with source links; `/collections/:id` lists any collection's items and holders.
Grand Tardinians is 999 items: the 1,494 in #30 counted transfers ([field note](docs/field-notes/2026-11-02-the-495-tardinians.md)).
#33 TXSTORE: raw tx bytes in S3 (one immutable CDN URL per txid), collections first; images parsed from raw txs on the fly at `/content/:outpoint`.
#32 BAP identity index is built ([docs/BAP.md](docs/BAP.md)): `/api/v1/bap/:bap_id`, with the rules for valid, accepted, rotation and newest written down.
Real mainnet records pass as fixtures; on prod, `Release.import_bap` with a real txid is the one step left.
#49 TYPES: a public page per transaction type, then every tx typed (unmatched is `custom`), then types as CRUD resources.
Phase 1 is built: `/types`, `/types/:id` and `/api/v1/types`, with examples read only from existing indexes, and token and collection badges linking to their type.
Phase 2 is built (2026-11-04): stable template hashes (script analysis v7), `Bitblocks.TxTypes.Classifier` passing every vector in `priv/data/tx_types/output_types_v1.json`, the `classify_outputs` and `type_counts` pipeline steps, and counts per type (with `custom`) on `/types` and `/api/v1/types`.
P2PK and P2SH are types (classifier v2), so early coinbases no longer read `custom`.
Needs on prod, with Ryan's OK: the tx_types backfill (#1); until then `/types` says no block is typed yet.
Open: named combinations such as a listing. The canonical opcode names are agreed, and the OrdLock and CLTV hashes are pinned in the suite.
#48 SCRUBBER: admin three.js scrub from genesis to tip, and the first surface for accounting for misspends and burns.
Built: tile pyramid, incremental builds, `/chain-scrubber`, and reorg, classified-loss and burn layers ([docs/CHAIN_SCRUBBER.md](docs/CHAIN_SCRUBBER.md)).
Tiles are built on prod. Left: Ryan's browser pass on the WebGL scene.
Shipped (2026-11-04): `/tx-graph` is the transaction flow space (every input an arc, scrubbed by a playhead), and `/annotations` places events on the chain, with an admin API ([docs/TX_FLOW.md](docs/TX_FLOW.md)).
Next: #67 binary flow tiles and live growth.


## Deferred

#27 personal funding · #66 streaming blocks over 32 MB.
