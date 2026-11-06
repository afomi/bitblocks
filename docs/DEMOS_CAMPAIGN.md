# Start campaign: building on Bitcoin

Status: built on a branch, admin only so Ryan can read it on production, and not yet seen in a browser (2026-11-05).
Ryan's direction: think of this as `/start`, onboarding from a user's standpoint, with developer docs as a first-class part and our own guidance alongside.

**To publish:** move the three `/start` routes from the router's `:admin` scope and live_session to `:public`, remove `meta_robots: "noindex, nofollow"` from the three `BitblocksWeb.StartLive` modules, add the paths to `@public_paths` in `SitemapController`, add a link on the home page and in the nav, and update the "not published yet" tests in `test/bitblocks_web/live/start_live_test.exs`.

## Audience

Someone who wants to build on Bitcoin and hasn't picked their tools yet.
They may be a web developer who is new to the chain, or a builder from elsewhere in the ecosystem looking for a dependable read side.

## Message

Bitblocks is the easy way in to building on Bitcoin.
It reads the chain for you, says plainly how far it reaches, and points to the best work around the ecosystem rather than trying to contain it.

## Page set

| Route | Job | Access |
| --- | --- | --- |
| `/start` | The path: what to do first, second and third, then demos, references and Qart | Admin only for now |
| `/start/api` | The developer reference a builder comes back to | Admin only for now |
| `/start/guidance` | Our dated opinions on seven topics | Admin only for now |

The two sub-pages earn their place.
A path is read once, a reference is revisited, and opinions need room for their reasons.

## What each section proves

- **What's here today:** we say how far the index reaches, from the live sync snapshot, before asking anyone to rely on it.
- **Step 1, first request:** something real works with one command and no account.
- **Step 2, read a transaction:** the data is real, using the first spend in block 170, which sits inside the complete range and opens with no account.
- **Step 3, prove it:** you needn't trust us, because a short script checks the proof on your own machine.
- **Step 4, sign in:** the free tier is a GitHub sign-in, and it opens the whole API in that browser.
- **Step 5, get a key:** the trial's last step, marked Coming.
- **See what's been built:** Rexxies lead, with counts and pictures from the index, and an honest note on where the data comes from.
- **Start from these:** we point out to other people's work, with plain links.
- **Write with Qart:** an application needs a write side, and here is one that works today.
- **Guidance:** we hold views, say why, and date them.
- **API reference:** how to call it, how to read an answer that isn't certain, and the core endpoints.

## Real today, and what needs building

| Thing | State |
| --- | --- |
| `/api/v1/status`, `/price/bsv`, `/support` and the Bitcom registry exports with no account | Real |
| Block and transaction pages with no account | Real |
| GitHub sign-in, and the API from that browser | Real |
| Merkle proofs and BEEF | Real |
| Rexxies, Grand Tardinians and their API | Real, imported on their own ahead of the sync |
| Address and script balances | Real, and mostly `partial` or `unknown` until the index reaches the tip |
| Self-serve keys | Needs building |
| Qart buy button, pay links, receipts, 402, wallet API | Live, by Qart's own labels |
| Qart escrow, pre-signed refunds, co-signed transactions | Testnet, by Qart's own labels |
| Qart BSV-21 minting and referral covenants | Preview, by Qart's own labels |

The figures on the pages come from `SyncProgress`, `OrdinalCollections` and the rate limiter config at render time.
A test holds every listed endpoint to the router and to the access it claims, and another climbs the example proof.

## Blockers, designed around

- **No self-serve key.**
  `/api/v1` needs a key or a signed-in session, and `Release.create_api_key` is operator-only.
  The path uses the signed-in browser and marks step 5 Coming.
  Recommendation: a signed-in user gets one key with a small budget, as a separate decision, because it touches `lib/bitblocks/api_keys.ex`.
- **`curl` beyond the open endpoints fails for a newcomer.**
  Only step 1 uses `curl`, step 2 uses a page, and step 4 uses a browser tab.
  The proof example is printed on the page, so step 3's script runs with no account.
- **Pricing was just rewritten.**
  `/start` links to `/pricing` and repeats none of its plans.
- **The sync is partway up the chain.**
  Examples use block 170, and the page shows live coverage.
  Rexxies are above the sync, so the page says they're imported on their own.
  The API page sends whole-chain balance needs to WhatsOnChain.

## Order to ship

1. Ryan reads all three pages on production as an admin, light and dark, then checks the signed-out view of step 4 once the routes flip.
2. Ryan confirms or rewrites the Draft views in guidance.
3. Decide self-serve keys, then build them and turn step 5 on.
4. Publish with the line at the top.
5. Add a demo walkthrough page only if a demo proves worth its own page.

## Sources for guidance

Our position: Standards (Qart `docs/INTEROP.md`), Identity (Qart `docs/IDENTITY_INTEROP.md`, `docs/IDENTITY_AND_TRANSACTIONS.md`, and `docs/BAP.md` here), Wallets (Qart `docs/BRC100.md`, `docs/INTEROP.md`).

Draft, for Ryan to confirm: Experiences (`DESIGN.md`, Qart `docs/positioning/POSITIONING.md`), Applications (`docs/ADOPTION_SPECTRUM.md`, Qart `docs/INTEROP.md` and `docs/IDENTITY_AND_TRANSACTIONS.md`), Resources and Things we find interesting (selected for this page).
