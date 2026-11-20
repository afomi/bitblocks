# Bitblocks — Plan

Tasks live in GitHub Issues: https://github.com/afomi/bitblocks/issues
Labels carry status: `now` (single active thread), `next`, `needs-decision`, `deferred`; `from-inbox` marks handoff-sourced work, `ops` a prod step.
This file links issues and doesn't restate them; when it and an issue disagree, the issue wins, and the code wins over both.
Docs entrypoint: `docs/INDEX.md`.
Design rules (authoritative for every page's look and markup): [DESIGN.md](DESIGN.md).
Completed-work history (pre-Issues): `product-cycle/BACKLOG.md`.

## Where it stands (2026-11-20)

Prod is `ok`: complete through block 394,132 of 976,334 known, stopping by itself at 600,000 until the storage plan says otherwise (`index.stop_height` on `/api/v1/status`).
The storage plan (https://github.com/afomi/bitblocks/issues/96), the index drops (https://github.com/afomi/bitblocks/issues/92) and the block objects (https://github.com/afomi/bitblocks/issues/94) are done and closed.
The sync loop is in [docs/SYNCING.md](docs/SYNCING.md); the measured storage numbers are in [docs/STORAGE_PLAN.md](docs/STORAGE_PLAN.md).

## Now

**The archive, then the election dogfood.**
Without funding, Bitblocks spins down by 2026-12-31, so an archive that restores comes first.

1. Archive to S3 and rehearse a restore: https://github.com/afomi/bitblocks/issues/55
   The runbook is [docs/RESTORE.md](docs/RESTORE.md), with `Release.restore_check/1` to compare a restore with its source; the rehearsal itself is infra's.
2. The election dogfood: the Public Blockchain Association elects its board on Bitblocks, then Modular City runs the same flow; design in [docs/ELECTION_DOGFOOD.md](docs/ELECTION_DOGFOOD.md).
   Epic: https://github.com/afomi/bitblocks/issues/140; the counting rule and its v0 vectors are live (https://github.com/afomi/bitblocks/issues/136), and so is the tip lane, dormant until an election projection exists and Ryan starts it (https://github.com/afomi/bitblocks/issues/139).
   Left for Ryan: one `app` name for the record format, and MIT or CC0 for the vectors.

The live Bitcom registry ([docs/BITCOM.md](docs/BITCOM.md)) is done but for the funded address, https://github.com/afomi/bitblocks/issues/58.

## Ops, each one prod step from done

- Derived data to version, then the audit: https://github.com/afomi/bitblocks/issues/1 (`tx_steps` and `tx_types` done; tallies left)
- The node runbook: https://github.com/afomi/bitblocks/issues/54
- Stripe webhook deliveries while Checkout is dormant: https://github.com/afomi/bitblocks/issues/143 (the endpoint, in Ryan's Stripe Dashboard)

## Needs decision

- A Bitblocks-owned funded address: https://github.com/afomi/bitblocks/issues/58
- Pricing: https://github.com/afomi/bitblocks/issues/61, after a week of usage rollups (about 2026-11-26)
- Sponsorship: the visibledao.com/bitblocks page is built; left are its launch, then `sponsor_url`: https://github.com/afomi/bitblocks/issues/26
- The WhatsOnChain uses still pending in `docs/WOC_USE.md`: https://github.com/afomi/bitblocks/issues/95

## Next

- Payments: five lines, one Stripe account ([docs/STRIPE.md](docs/STRIPE.md)) and one Stripe groundwork.
  The groundwork is built once, before the first line that needs it: a Stripe client over Req, a customer per user, Checkout, the customer portal, and signature-checked webhooks idempotent on the event id.
  Built: Checkout (one payment, or a subscription), the customer portal, a customer per user (Stripe's, held on the user's plan subscription), and signature-checked webhooks idempotent on the event id through one dispatcher (`Bitblocks.Payments.Stripe`, `Bitblocks.Payments.StripeEvents`, `stripe_events`), over x402_ex's HTTP client.
  jurisdictional's `Jurisdictional.Billing` is the reference; agree with jurisdictional whether it becomes a shared library, as x402_ex did.
  1. AI crawlers pay per request, through x402 (below).
  2. Bulk downloads: one quoted, paid, resumable download of a block range: https://github.com/afomi/bitblocks/issues/111
     The free quote is built (`Bitblocks.Downloads`, `/pricing#downloads`, `GET /api/v1/downloads/quote`, `GET /api/v1/downloads/sizes`), raw block files only.
     The price is $1.00 per GiB (Ryan, 2026-11-19; `price_usd_per_gib` in config/prod.exs), published on `/pricing` with its arithmetic, a live estimate, named ranges and the size of each 50,000-block band.
     Checkout, the signed webhook, `/downloads/<id>`, signed links and the resume script are built (`Bitblocks.Downloads.Purchases`, `Bitblocks.Payments.Stripe`), dormant until Ryan adds Checkout to the sandbox key and sets the sandbox webhook secret: [docs/STRIPE.md](docs/STRIPE.md#bulk-downloads-checkout).
     Until then "Contact us" mails the quote; next is Ryan's test-mode payment, then live mode.
  3. Monthly plans: three tiers and a custom high-volume plan, moving a user's keys to the tier: https://github.com/afomi/bitblocks/issues/112
     Ryan sets the tier prices before launch; drafts stay out of this public repo.
     Built dormant (`Bitblocks.Billing`, `/pricing#plans` and `#plan`): plans are config (`BILLING_PLANS`, a JSON array in the secret, each with its Stripe Price id), and with none set `/pricing` reads as before.
     "Choose" opens Checkout in subscription mode; signed webhooks move every key the user owns to the plan's limit without changing it, keep it through past due, and return it to the trial's when Stripe ends the subscription, in any order.
     "Your plan" shows status, renewal, this period's use against the allowance (shown, not enforced) and "Manage billing".
     Next, Ryan's steps: [docs/STRIPE.md](docs/STRIPE.md#monthly-plans), then a test-mode subscription and cancel.
     Not built: the email on downgrade, alerts at 80% and 100% beyond the page, a hard ceiling at the allowance, and the custom plan's admin-set limits.
  4. Cloud services: managed projections, filtered databases and dedicated instances, quoted and billed monthly: https://github.com/afomi/bitblocks/issues/113
     The quote request is built (2026-11-19, `/pricing#cloud`, `Bitblocks.CloudQuote`): the filter as the projection API takes it, a capped estimate over blocks to `complete_through`, and "Request a quote" by mail to enterprise@bitblocks.app.
     No price is set; quotes from `/admin/quotes`, subscriptions and `/account/services` come with the groundwork.
  5. Consulting: rare, and outside the app's billing code: https://github.com/afomi/bitblocks/issues/114
     Built (2026-11-19): a "Consulting" line on `/pricing` whose "Contact us" mails enterprise@bitblocks.app, subject "Consulting enquiry".
     Left for Ryan: the invoicing channel, and whether that address stays the one.
  Lines 3 and 4 price from per-key use counting, which is measured now ([docs/USAGE_METERING.md](docs/USAGE_METERING.md), https://github.com/afomi/bitblocks/issues/61).
- Paid crawler access (x402), agreed with jurisdictional on 2026-11-18:
  - One shared library, `x402_ex` (`afomi/x402_ex`), protocol and verification only.
    bitblocks builds v0.1, including `X402.Stripe`, and jurisdictional gives it a security review before it is tagged.
    jurisdictional then builds MPP, as phase 2.
  - bitblocks adopts it behind the crawler 402 from https://github.com/afomi/bitblocks/pull/109.
    It adds `{:req, "~> 0.5"}`, and a ReplayGuard table with a unique index on the tx hash.
  - Stripe recording goes in a shared `X402.Stripe.record/2` helper.
    Each app keeps its own Stripe keys and webhooks.
  - bitblocks has its own Stripe account, separate from jurisdictional's.
    Its deposit address, one per app as x402_ex requires, gets recorded here once Stripe issues it.
  - x402_ex v0.1.0 is released: https://github.com/afomi/x402_ex/releases/tag/v0.1.0 (Apache-2.0, CI on Elixir 1.15 and 1.19).
    jurisdictional reviewed it and approved it for v0.1 at `74e6d07`; the release adds only open-source hygiene and a doc fix.
  - Keys and the sandbox run: [docs/STRIPE.md](docs/STRIPE.md).
  - Live mode waits on Ryan: Stripe's crypto approval, CDP keys, a price (proposed 0.01 USDC a request) and his go.
    Then infra lifts the ALB Meta rule.
- Interop, a BRC-237 statement and one live payment: https://github.com/afomi/bitblocks/issues/64
- REVIVE unwriter's stack: https://github.com/afomi/bitblocks/issues/25
- Managed projections: https://github.com/afomi/bitblocks/issues/29
- Tx store: https://github.com/afomi/bitblocks/issues/33
- Also open: https://github.com/afomi/bitblocks/issues/68 · https://github.com/afomi/bitblocks/issues/75 · https://github.com/afomi/bitblocks/issues/83

## Deferred

https://github.com/afomi/bitblocks/issues/81 · https://github.com/afomi/bitblocks/issues/84

## Closed since 2026-11-07

https://github.com/afomi/bitblocks/issues/18 · https://github.com/afomi/bitblocks/issues/49 · https://github.com/afomi/bitblocks/issues/57 · https://github.com/afomi/bitblocks/issues/62 · https://github.com/afomi/bitblocks/issues/86 · https://github.com/afomi/bitblocks/issues/114 · https://github.com/afomi/bitblocks/issues/56 · https://github.com/afomi/bitblocks/issues/59 · https://github.com/afomi/bitblocks/issues/70 · https://github.com/afomi/bitblocks/issues/73 · https://github.com/afomi/bitblocks/issues/74 · https://github.com/afomi/bitblocks/issues/79 · https://github.com/afomi/bitblocks/issues/87 · https://github.com/afomi/bitblocks/issues/88 · https://github.com/afomi/bitblocks/issues/89 · https://github.com/afomi/bitblocks/issues/90 · https://github.com/afomi/bitblocks/issues/91 · https://github.com/afomi/bitblocks/issues/92 · https://github.com/afomi/bitblocks/issues/93 · https://github.com/afomi/bitblocks/issues/94 · https://github.com/afomi/bitblocks/issues/96
https://github.com/afomi/bitblocks/issues/24 · https://github.com/afomi/bitblocks/issues/32 · https://github.com/afomi/bitblocks/issues/48 · https://github.com/afomi/bitblocks/issues/51 · https://github.com/afomi/bitblocks/issues/60 · https://github.com/afomi/bitblocks/issues/63 · https://github.com/afomi/bitblocks/issues/65 · https://github.com/afomi/bitblocks/issues/66 · https://github.com/afomi/bitblocks/issues/67 · https://github.com/afomi/bitblocks/issues/69 · https://github.com/afomi/bitblocks/issues/76 · https://github.com/afomi/bitblocks/issues/77 · https://github.com/afomi/bitblocks/issues/78 · https://github.com/afomi/bitblocks/issues/80 · https://github.com/afomi/bitblocks/issues/82 · https://github.com/afomi/bitblocks/issues/85
Earlier closes are in the issue tracker's closed list.
