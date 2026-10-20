# Bitblocks — Plan

Tasks live in GitHub Issues: https://github.com/afomi/bitblocks/issues
Labels carry status: `now` (single active thread), `next`, `needs-decision`, `deferred`; `from-inbox` marks handoff-sourced work.
Docs entrypoint: `docs/INDEX.md`.
Completed-work history (pre-Issues): `product-cycle/BACKLOG.md`.

## Now

**#18 BITCOM**: be a live, maximally useful Bitcom registry (unwriter's Bitcom), then keep reviving the rest of his stack (#25).
Current system doc: `docs/BITCOM.md`.

Ryan's ops queue: **#1 OPS-ROLLOUT**. Commit and deploy the working tree, then run one `Release.analyze_transactions/1` pass to reach v6.
That pass now also indexes Bitcom commands.
Then run the completeness audit and repair, and confirm zero deficit blocks.

## Awaiting commit (built and tested 2026-10-19 and 2026-10-20; close each issue on commit)

#19 Bitcom command log · #20 /bitcom pages · #23 command composer · #2 precommit alias + format catch-up · #3 sitemap (also fixes /apps, /resources, /did) · #4 BSV-21 by address + net holders · #5 SEC-HARDEN · #6 script cards · #7 AIP verify · #8 attribution · #10 template-hash contract · #11 outpoint yes/no/unknown.

Partly built: #21 export (snapshot anchoring needs a bitblocks-owned address) · #22 bit:// resolver (acting as a provider needs #15 and that address) · #26 sponsorship: the ask moved off-site; bitblocks serves live numbers at `GET /api/v1/support` and a footer link (next steps in [docs/DONATION_ADDRESS.md](docs/DONATION_ADDRESS.md#fundraising-next-steps)).

## Needs decision

#9 seeded protocols vs. on-chain proof (/bitcom already derives tiers from proof; decide whether /protocols follows) · #12 API-SURFACE · #13 EDGE-RATE · #16 brand-orange contrast.

## Next

#25 REVIVE: unwriter's stack, one sprint per piece.

## Deferred

#14 APP-SUPPORT · #15 BCAT-REASSEMBLE · #17 BEEF · #24 historical Bitcom discovery · #27 personal funding.
