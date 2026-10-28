# Bitblocks — Plan

Tasks live in GitHub Issues: https://github.com/afomi/bitblocks/issues
Labels carry status: `now` (single active thread), `next`, `needs-decision`, `deferred`; `from-inbox` marks handoff-sourced work.
Docs entrypoint: `docs/INDEX.md`.
Completed-work history (pre-Issues): `product-cycle/BACKLOG.md`.

## Now

**#18 BITCOM**: be a live, maximally useful Bitcom registry (unwriter's Bitcom), then keep reviving the rest of his stack (#25).
Current system doc: `docs/BITCOM.md`.

Ryan's ops queue: **#1 OPS-ROLLOUT**. The code is deployed (b8b7757, 2026-10-21).
Run one `Release.analyze_transactions/1` pass on prod to reach v6; it also indexes Bitcom commands, so `/bitcom` gains proofs, files and routes.
It runs for hours, so start it detached (see #1).
Then run the completeness audit and repair, and confirm zero deficit blocks.

## Shipped 2026-10-21 (closed)

#2 · #3 · #4 · #5 · #6 · #7 · #8 · #10 · #11 · #19 · #20 · #23.

Partly built: #21 export (snapshot anchoring needs a bitblocks-owned address) · #22 bit:// resolver (acting as a provider needs #15 and that address) · #26 sponsorship: the ask moved off-site; bitblocks serves live numbers at `GET /api/v1/support` and a footer link (next steps in [docs/DONATION_ADDRESS.md](docs/DONATION_ADDRESS.md#fundraising-next-steps)).

## Needs decision

#9 seeded protocols vs. on-chain proof (/bitcom already derives tiers from proof; decide whether /protocols follows) · #12 API-SURFACE · #13 EDGE-RATE · #16 brand-orange contrast.

## Next

#25 REVIVE: unwriter's stack, one sprint per piece.
#29 PROJECTIONS: shared managed projections, prototype slice ([docs/MANAGED_SERVICES.md](docs/MANAGED_SERVICES.md)).
Steps 1–4 are built: the projection record (`Bitblocks.Projections`), hydrate (`GET /api/v1/projections/:id/txs`), status (`/status`) and webhook follow (`ProjectionWebhookWorker`).
Step 5 (tenant keys and quotas, with SSRF protection on webhook URLs) is next; it needs #12 and #13 decided.

## Deferred

#14 APP-SUPPORT · #15 BCAT-REASSEMBLE · #17 BEEF · #24 historical Bitcom discovery · #27 personal funding.
