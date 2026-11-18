# Bitblocks — Plan

Tasks live in GitHub Issues: https://github.com/afomi/bitblocks/issues
Labels carry status: `now` (single active thread), `next`, `needs-decision`, `deferred`; `from-inbox` marks handoff-sourced work, `ops` a prod step.
This file links issues and doesn't restate them; when it and an issue disagree, the issue wins, and the code wins over both.
Docs entrypoint: `docs/INDEX.md`.
Design rules (authoritative for every page's look and markup): [DESIGN.md](DESIGN.md).
Completed-work history (pre-Issues): `product-cycle/BACKLOG.md`.

## Where it stands (2026-11-17)

Prod is `ok`: complete through block 377,241 of 975,927 known, stopping by itself at 400,000 until the storage plan lands (`index.stop_height` on `/api/v1/status`).
Headers and the donation scan reach the tip, since the node's `rpcservertimeout=600` (2026-11-16).
The sync loop is in [docs/SYNCING.md](docs/SYNCING.md); the measured storage numbers are in [docs/STORAGE_PLAN.md](docs/STORAGE_PLAN.md).

## Now

**The storage plan and the archive.**
Ryan's two-week push (2026-11-05) ends about 2026-11-19; then archive to S3, and restore and resync when funded.
Without funding, Bitblocks spins down by 2026-12-31.

1. Storage plan, final on measured numbers, for Ryan's approval: https://github.com/afomi/bitblocks/issues/96
2. Archive to S3 and rehearse a restore: https://github.com/afomi/bitblocks/issues/55
   The runbook is [docs/RESTORE.md](docs/RESTORE.md), with `Release.restore_check/1` to compare a restore with its source; the rehearsal itself is infra's.
3. Drop the six unused indexes, approved 2026-11-15: https://github.com/afomi/bitblocks/issues/92
4. Block objects for every completed block, before any move that drops `raw`: https://github.com/afomi/bitblocks/issues/94

The product thread stays the live Bitcom registry: https://github.com/afomi/bitblocks/issues/18 ([docs/BITCOM.md](docs/BITCOM.md)); every step is done but the funded address, https://github.com/afomi/bitblocks/issues/58.

## Fixes shipped, to verify on prod

https://github.com/afomi/bitblocks/issues/87 · https://github.com/afomi/bitblocks/issues/88 · https://github.com/afomi/bitblocks/issues/89 · https://github.com/afomi/bitblocks/issues/90 · https://github.com/afomi/bitblocks/issues/91

## Ops, each one prod step from done

- Derived data to version, then the audit: https://github.com/afomi/bitblocks/issues/1 (`tx_steps` and `tx_types` done; tallies left)
- The node runbook: https://github.com/afomi/bitblocks/issues/54
- `build_flow_tiles`, waiting on Ryan's go: https://github.com/afomi/bitblocks/issues/67
- Reorg edges, sweep found nothing: https://github.com/afomi/bitblocks/issues/73
- Donation scan at the tip, ready to close: https://github.com/afomi/bitblocks/issues/74
- Sync throughput: https://github.com/afomi/bitblocks/issues/56

## Needs decision

- A Bitblocks-owned funded address: https://github.com/afomi/bitblocks/issues/58
- `/start` is live with trial keys; Ryan reads the four pages and confirms or drops each Draft guidance view: https://github.com/afomi/bitblocks/issues/59
- Pricing: https://github.com/afomi/bitblocks/issues/61
- Sponsorship: the visibledao.com/bitblocks page is built; left are its launch, then `sponsor_url`: https://github.com/afomi/bitblocks/issues/26
- Collections traced from our own index (branch `own-index-tracing`): https://github.com/afomi/bitblocks/issues/95

## Next

- Payments: five lines, one Stripe account (`acct_1UdHHhLYRHWWpBFF`, [docs/STRIPE.md](docs/STRIPE.md)) and one Stripe groundwork.
  The groundwork is built once, before the first line that needs it: a Stripe client over Req, a customer per user, Checkout, the customer portal, and signature-checked webhooks idempotent on the event id.
  jurisdictional's `Jurisdictional.Billing` is the reference; agree with jurisdictional whether it becomes a shared library, as x402_ex did.
  1. AI crawlers pay per request, through x402 (below).
  2. Bulk downloads: one quoted, paid, resumable download of a block range: https://github.com/afomi/bitblocks/issues/111
  3. Monthly plans: three tiers and a custom high-volume plan, moving a user's keys to the tier: https://github.com/afomi/bitblocks/issues/112
     Ryan sets the tier prices; the issue proposes $25, $99 and $299.
  4. Cloud services: managed projections, filtered databases and dedicated instances, quoted and billed monthly: https://github.com/afomi/bitblocks/issues/113
  5. Consulting: rare, and outside the app's billing code; its channel is Ryan's call: https://github.com/afomi/bitblocks/issues/114
  Lines 3 and 4 need per-key use counting first (https://github.com/afomi/bitblocks/issues/61).
- Paid crawler access (x402), agreed with jurisdictional on 2026-11-18:
  - One shared library, `x402_ex` (`afomi/x402_ex`), protocol and verification only.
    bitblocks builds v0.1, including `X402.Stripe`, and jurisdictional gives it a security review before it is tagged.
    jurisdictional then builds MPP, as phase 2.
  - bitblocks adopts it behind the crawler 402 from https://github.com/afomi/bitblocks/pull/109.
    It adds `{:req, "~> 0.5"}`, and a ReplayGuard table with a unique index on the tx hash.
  - Stripe recording goes in a shared `X402.Stripe.record/2` helper.
    Each app keeps its own Stripe keys and webhooks.
  - bitblocks' Stripe account is `acct_1UdHHhLYRHWWpBFF`, separate from jurisdictional's.
    Its deposit address, one per app as x402_ex requires, gets recorded here once Stripe issues it.
  - x402_ex v0.1.0 is released: https://github.com/afomi/x402_ex/releases/tag/v0.1.0 (Apache-2.0, CI on Elixir 1.15 and 1.19).
    jurisdictional reviewed it and approved it for v0.1 at `74e6d07`; the release adds only open-source hygiene and a doc fix.
  - Keys and the sandbox run: [docs/STRIPE.md](docs/STRIPE.md).
  - Live mode waits on Ryan: Stripe's crypto approval, CDP keys, a price (proposed 0.01 USDC a request) and his go.
    Then infra lifts the ALB Meta rule.
- CI and deploys skip docs-only pushes: https://github.com/afomi/bitblocks/issues/93
- Large blocks, the stream's remaining edges: https://github.com/afomi/bitblocks/issues/86
- Transaction types, phase 2 done and proposed for closing: https://github.com/afomi/bitblocks/issues/49
- Interop, a BRC-237 statement and one live payment: https://github.com/afomi/bitblocks/issues/64
- REVIVE unwriter's stack: https://github.com/afomi/bitblocks/issues/25
- Managed projections: https://github.com/afomi/bitblocks/issues/29
- Tx store: https://github.com/afomi/bitblocks/issues/33
- Also open: https://github.com/afomi/bitblocks/issues/68 · https://github.com/afomi/bitblocks/issues/70 · https://github.com/afomi/bitblocks/issues/75 · https://github.com/afomi/bitblocks/issues/79 · https://github.com/afomi/bitblocks/issues/83

## Deferred

https://github.com/afomi/bitblocks/issues/57 · https://github.com/afomi/bitblocks/issues/62 · https://github.com/afomi/bitblocks/issues/81 · https://github.com/afomi/bitblocks/issues/84

## Closed since 2026-11-07

https://github.com/afomi/bitblocks/issues/24 · https://github.com/afomi/bitblocks/issues/32 · https://github.com/afomi/bitblocks/issues/48 · https://github.com/afomi/bitblocks/issues/51 · https://github.com/afomi/bitblocks/issues/60 · https://github.com/afomi/bitblocks/issues/63 · https://github.com/afomi/bitblocks/issues/65 · https://github.com/afomi/bitblocks/issues/66 · https://github.com/afomi/bitblocks/issues/67 · https://github.com/afomi/bitblocks/issues/69 · https://github.com/afomi/bitblocks/issues/76 · https://github.com/afomi/bitblocks/issues/77 · https://github.com/afomi/bitblocks/issues/78 · https://github.com/afomi/bitblocks/issues/80 · https://github.com/afomi/bitblocks/issues/82 · https://github.com/afomi/bitblocks/issues/85
Earlier closes are in the issue tracker's closed list.
