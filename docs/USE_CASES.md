# Use Cases — Bitblocks as Full-Chain Support for Other Applications

Status: draft / design & vision (aspirational).
Nothing in this document is implemented unless it names an existing module, route, or table.

Bitblocks is a full-chain Bitcoin SV explorer and index.
Other applications (qart, votesmash, a family archive, a neighborhood ledger, a protocol-specific explorer) are **filters** and **transforms** over that chain.
This draft treats Bitblocks as the source those applications **hydrate from**, the **registry** they discover each other through, and the **identity index** that makes a person recognizable across them — without becoming their login silo.

Related (do not duplicate; this doc is the product framing):
`BITBLOCK.md`, `CHAIN_LENS.md`, `CUSTOM_INDEXING.md`, `COMPOSABLE_STREAMS.md`, `DATA_DICTIONARY_SPEC.md`, `ACCOUNT_MODEL.md`, `DATA_MANAGEMENT_CONSIDERATIONS.md`, `UNWRITER_SYNTHESIS.md`, `UNWRITER_APPS.md`, `ADOPTION_SPECTRUM.md`.

---

## Position

A block explorer that only answers "what is this txid?" is a commodity.
Bitblocks already indexes headers, transactions, spends, scripts, protocols, tokens, and order-book listings.
The next job is to **support other applications** that keep their own databases and UIs, and that need a timely, complete, filtered view of the chain.

Three problems sit in front of that job:

1. **Application registry** — how a filter/transform becomes a named, discoverable, versioned thing other people can hydrate from.
2. **User identity UX across applications** — how a person using many apps is the same person on the chain, without Bitblocks owning their session.
3. **Hydration** — the first time a db-backed app pulls a (filtered or unfiltered) set of transactions, and every time after that.

Timeliness is the quality bar.
A filter that is only evaluated when someone queries 51 GB of `transactions` is not timely.
A filter that tags matching transactions as they are ingested, and that can be backfilled when newly registered, is.

---

## Vocabulary

Prior art (Planaria, Bitquery, Bitsocket, TXO/BOB) is useful conceptually.
Those names are **not** standards in this repo.
Use Bitblocks language:

| Idea | Bitblocks term | Meaning |
|---|---|---|
| Match rule | **Filter** | Declarative predicate over a transaction (prefix, MAP `app=`, script template hash, address set, height range, or a combination). |
| Transform | **Map** | Function from a matching transaction to the record an application stores (parse, fold, compress, redact, hash). |
| Named product | **Application** | A product that uses one or more filters (and optional maps). Distinct from a **Protocol** (wire format). |
| Historical pull | **Hydrate** | Fill an empty or lagging consumer database from Bitblocks, up to a snapshot cursor. |
| Live follow | **Follow** | Consume new matches after the snapshot (SSE, poll, or webhook). |
| Resume token | **Cursor** | `(height, txid)` (or equivalent) from which the next page or follow starts. |
| Who signed | **Identity** | A key, address, paymail, AIP signature, or DID — not a Bitblocks account. |

A **Protocol** is a wire format (MAP, B://, BSV-21, Order Book).
An **Application** is a product (qart, votesmash) that may speak several protocols.
A **Stream** (see `COMPOSABLE_STREAMS.md`) is a named schema inside an application.
A **Bitblock** (see `BITBLOCK.md`) is a materialized filter: same software, subset database.

The gene metaphor still holds: **what you filter for is what you are.**
The filter + map *is* the application's chain-facing identity.

---

## What exists today

Grounding, so the draft does not invent a second stack.

- Full-chain sync: headers, then txids, then raw transactions (`docs/SYNCING.md`).
- Ingest-time analysis: `TransactionParser.analyze/1` tags protocols, script types, coinbase; `script_analysis_version` drives reanalysis.
- Protocol handlers: compile-time `Bitblocks.Protocol.Handler` list, plus `RegistryCache` for prefix-only protocols added in the DB without a deploy (`docs/CUSTOM_INDEXING.md`).
- Protocol catalog: `protocols` / `protocol_instances` tables, `/protocols` UI, `/api/v1/protocols/:addr/feed`.
- Script-addressed API and `script_templates` registry (`/api/v1/script/*`).
- Spend index, local address balance, token index, order book, Metanet DAG, SSE streams (`/api/v1/stream/*`).
- Time↔height (`CHAIN_LENS.md` endpoints).
- DID playground at `/did` (did:web generation and VC issue/verify — not an identity index of chain activity).
- `/apps` is a public route (`PageController.applications/2`) described as an applications directory; it is a static page, not a registry of live applications.
- Completeness audit + repair for **full blocks** (`Release.audit_completeness/1`).
- Tip vs backfill Oban lanes so historical work does not starve the tip.

What does **not** exist yet: a first-class Application record, a transportable filter spec, a hydration API with cursors, ingest-time tagging of arbitrary registered filters, cross-app identity UX, or consumer-side follow-from-snapshot.

---

## Use cases

These are the jobs Bitblocks should make possible.
They are adapted from the Planaria "use" catalog, rewritten for a full-chain explorer that **feeds** other apps rather than replacing them.

### 1. Blockchain explorers

Bitblocks itself is the full-chain explorer.
The same software, pointed at a filter, is a domain explorer: "qart listings", "this county's attestations", "this family's transactions".

The explorer is no longer a narrow "txid → hex" viewer.
It is the default UI over whatever subset the filter selects.

**Bitblocks role:** full-chain source of truth; optional branded subset UIs.

### 2. Public utility database

The full index is expensive infrastructure.
Applications should not each run a 20 TB node.
They should pay (or share) for **filtered access** to a public utility that already has the chain.

Monetization lives at the edge of the utility (hydration bandwidth, materialized views, SLA on tip lag) — not inside the consumer apps.
See `PAYMENT_CHANNELS.md` and the pricing page; this doc does not pick a tariff.

**Bitblocks role:** the utility.
**Consumer role:** a paying (or free-tier) subscriber of a filter.

### 3. Forensic database

A filter can be "transactions that look like X": low-value stress floods, reused scripts, peeling chains, unexpected protocol mixes.
The forensic DB is a **separate projection**.
It does not change what the full-chain explorer stores.

**Bitblocks role:** run the filter at ingest; serve the tagged set.
**Consumer role:** the investigation UI and its own annotations (which may stay off-chain).

### 4. Analytics database

Application usage, protocol usage, and transaction-pattern stats can live in a database that is **not** the application's production DB.
Independence matters: the analytics fold can change without redeploying qart.

**Bitblocks role:** tagged events + height/time.
**Consumer role:** the warehouse / dashboard.

### 5. Prunable database

A consumer may drop old rows when they no longer serve the product (Chronos-style: keep 24 hours, keep unspent only, keep last-N per object).
The chain still has everything.
Re-hydration is always possible because the filter is deterministic.

**Bitblocks role:** remain the archival log.
**Consumer role:** decide retention; keep a cursor so catch-up is cheap.

### 6. Ephemeral / updating database

Most application state is a fold: the latest MAP SET for an object, the current token holder set, the open listings.
The DB "updates itself" as new matching transactions arrive.
The log is immutable; the projection is not.

**Bitblocks role:** ordered delivery of matches (hydrate then follow).
**Consumer role:** the fold function (the map).

### 7. Web application backend

A modern app is a projection of events plus a UI.
If the events are Bitcoin transactions, Bitblocks is the event log API.
The application still owns its tables, authz, and product logic.

This is the primary intended relationship with qart, votesmash, and similar apps:
they do **not** become Bitblocks.
They **hydrate from** Bitblocks.

### 8. Long-tail applications

Filters can be as narrow as "these twelve addresses" or "MAP `app=our-block-club`".
A family, a neighborhood, a working group can run a database that is only their slice.

This is only affordable if hydration is filtered **before** bytes leave Bitblocks, not after the consumer downloads the chain.

### 9. Portable applications

The portable artifact is the **filter + map + schema version**, not the Postgres volume.
To fork: copy the definition, change it, hydrate a new empty DB, invite users to point their clients at the new projection.

That is how protocol upgrades, community votes (which fork to follow), and niche specializations happen without rewriting history.

### 10. Multi-purpose backends (supersets)

The full-chain index is a superset of every filtered application.
A "all OP_RETURN" view is a superset of "all MAP `app=qart`".
A consumer whose filter is a subset of another consumer's filter can, later, hydrate from that peer instead of from Bitblocks (`BITBLOCK.md` mesh).
Day one: everyone hydrates from Bitblocks.

### 11. Filter and map

**Filter** decides membership.
**Map** decides representation.

Maps that belong on **derived** views, not on the canonical full-chain index:

- redaction / mosaic of payloads the operator will not serve
- preview (public low-res) vs encrypted original
- compression
- content-addressed checksums instead of bodies

The full-chain explorer stores what the chain stored (within legal/operator policy).
Transforms are versioned with the application definition so two hydrations of the same filter+map produce the same rows.

### 12. Bitcoin as an event bus

A match is an event.
Anything the consumer can run (email, SMS, a queue, another indexer) can be triggered from follow.
Bitblocks does not run that code.
It delivers the event (SSE / webhook) with the cursor attached.

### 13. Transparent private computing

The log can be public while the meaning is not.
Pattern:

1. Application definition (filter + map) is public, including that some fields are encrypted.
2. Ciphertext lands on chain and is indexed like any other payload.
3. Decryption keys stay with stakeholders.

Audit: anyone can see *that* state changed, when, and under which definition hash.
Privacy: only key holders can interpret the fields.

Bitblocks indexes ciphertext and metadata.
It does not hold application keys.

### 14. Anything (CRUD as projection)

Create / update / delete on an application object are new transactions that the map folds.
This is `EVENT_DRIVEN_OBJECT_ORIENTED_BITCOIN.md` applied to hydration:
the consumer's tables are a projection of a filter, not a second source of truth.

---

## A. Application registry

### What an Application is

An Application registry entry is a **named, content-addressed definition** of:

- who it is (human name, homepage, optional MAP `app=` / Bitcom prefix)
- **N independent filters** (a transaction may match several; that is normal)
- optional **map** (parse/fold schema, versioned)
- optional **identity scheme** (AIP, paymail, none)
- optional **hydration hints** (`from_height`, expected volume class)
- **supersedes** (previous definition hash), for upgrades

The registry is **not** the protocol table, though it builds on it.
Today `protocols` catalogs wire formats.
Applications *use* protocols.
qart is not MAP; qart *writes* MAP (and other) transactions.

### Canonical source of definitions

Direction (also recorded in `DATA_DICTIONARY_SPEC.md`):
the **transaction-pack / published kind definition** is canonical.
Bitblocks **derives** its dictionary and registry from those bytes.
When they disagree, the pack wins and Bitblocks re-derives.

Definitions are keyed by **content hash of the whole definition** (filters + map + identity scheme + version), not only a script pattern.
A definition is then a self-verifying object.
If it is published on chain, every indexer that sees the same bytes derives the same registry entry.

Until a pack exists as a package, interim sources are:

- compile-time protocol handlers
- `ProtocolRegistry` rows (prefix-only)
- `script_templates`
- MAP `app=` values already observed
- sibling-app tables (e.g. votesmash `tx_types`, qart protocol schemas)

### Registration surface

Both, with a clear rank:

1. **On-chain definition transaction** — permissionless, hash-keyed, auditable.
   Optional human namespace (name, MAP `app=`) *points at* a hash; the hash is the identity.
2. **API / admin insert** — convenience for operators and local dev.
   Must be re-derivable from (1) or explicitly marked `local-only`.

Self-service UI is the Protocol Author / Application Operator job.
It does not exist today (protocol registration is still a migration).

### Every definition is a filter, run on every transaction

Ryan's framing: Bitblocks should apply **N filters to every transaction**.
Bitcom address-prefix match is one pattern among them.
Matches are **independent tags**.
A transaction can be `MAP` + `qart` + `qart.listing` + a script template hash at once.

Views, feeds, and streams are **per tag**.
A newly registered filter is applied to **history by re-index** (same shape as `Release.analyze_transactions/1` / `script_analysis_version`), then to the tip by ingest.

Unmatched templates are a product signal, not an error:
"unregistered template `<hash>`, seen N times" is how new kinds get discovered and then registered.

### Discovery UX

`/apps` should become a live directory, not a static page:

- registered applications, their filters, last match height, match counts
- unmatched template leaderboard
- "open this application's feed" / "hydrate from this definition"
- link from a transaction page to every application tag it matched

`/api/v1/protocols` stays the wire-format catalog.
`/api/v1/apps` (proposed) is the product catalog.

### What Bitblocks will not be

Bitblocks does not host other applications' UIs or write their domain tables.
It registers how to **find and shape** their chain data.
The application still runs itself.

---

## B. User identity UX across applications

### Constraint

Users will use many applications.
They should not get a new account at each one, and they should not get a **Bitblocks account** that those apps must federate with.

Identity on this stack is **possession of keys**, optionally named (paymail, DID, AIP).
The wallet (BRC-100 / similar) is the session.
Bitblocks is an **index of identity events**, plus an explorer UX that can *optionally* attach a wallet.

### Layers

1. **Key / address** — the native unit.
   Every P2PKH output, every AIP signature, every signed MAP payload points at a key.
2. **Paymail / DID** — human handle resolving to a key (see `/did`, `docs/BITCOIN_URL.md`).
   Bitblocks can resolve and display; it does not issue paymails for other apps.
3. **On-chain authorship** — AIP (and similar) prove *this key authored this payload*.
   That is the cross-app "same person" fact the explorer can show with certainty.
4. **Wallet session** — optional "this is me" on Bitblocks UI.
   Used to highlight *my* activity, not to gate reading the chain.
5. **Account view** — indexer-level fold of a script or key (`ACCOUNT_MODEL.md` Layer 1).
   Balance, history, application tags.
   Not Ethereum account abstraction unless we say so.

### What the UX should do

On a transaction:

- show **who signed** (AIP / unlocking key) as an identity chip, not only an address string
- list **application tags** the tx matched
- offer "activity of this identity" — a lens (`CHAIN_LENS.md`) whose filter is the key plus optional app tags

On an identity:

- registered applications this key has appeared in (from tagged matches)
- first/last seen height
- scripts and paymail aliases when known
- **do not** silently cluster other keys as "same person"

On Bitblocks chrome (optional):

- connect wallet → "viewing as `<paymail or truncated key>`"
- no password account
- disconnect returns to anonymous explorer

Across applications (qart, votesmash, …):

- each app keeps its own session with the **same wallet**
- Bitblocks does not broker SSO
- Bitblocks *does* answer "has this key used application X?" so an app can greet a returning key without a proprietary user table — if it wants to

### Privacy and forensics

Forensic clustering (use case 3) is a **separate projection** with a clearly labeled confidence model.
The default explorer UX is **key-scoped**: we show what this key signed, not who we guess they are.
Whitepaper §10 (new key per tx) is a design input, not a bug (`ACCOUNT_MODEL.md`).
Persistent identity (paymail, AIP, DID) is opt-in authorship.

### Transparent private computing, in UX terms

If an application's map marks fields encrypted, the explorer shows "encrypted payload (definition `<hash>`)" rather than garbled bytes-as-text.
Stakeholders who hold keys decrypt **in their application**, not in Bitblocks.
Bitblocks may later accept a client-side decrypt hook; it must not take custody of keys.

---

## C. Hydration — first time, and ongoing

This is the operational heart.
A db-backed application starts empty (or stale) and must become a correct projection of a filter.

### The two clocks

- **Historical** — everything matching the filter up to a frozen snapshot height.
- **Live** — everything after that snapshot, including the race between "last page of hydrate" and "next block".

Never mix them in one unordered stream.
Hydrate to a snapshot, catch up from snapshot to current tip, then follow.

```
empty consumer DB
        │
        ▼
   declare filter (definition hash or inline spec)
        │
        ▼
   plan  →  estimated matches, from_height, snapshot_height, index_ready?
        │
        ▼
   hydrate pages  →  (height, txid) cursor, until snapshot_height
        │
        ▼
   catch-up  →  snapshot_height → tip  (same page API)
        │
        ▼
   follow  →  SSE / poll / webhook, cursor on every event
        │
        ▼
   reorg / new definition / downtime  →  rewind cursor, re-enter catch-up
```

### Filter vs unfiltered

| Consumer wants | Hydration source | Notes |
|---|---|---|
| A registered application / protocol / template | Tagged index for that filter | Index lookup, not a 51 GB scan. |
| An ad-hoc filter not yet registered | Register (or `local-only`), **backfill tags**, then hydrate | Same path as a new protocol. Until tags exist, refuse or quote a scan job. |
| The full chain | Running Bitblocks (or a dataset pack / replica) | Not a public anonymous export. See infra constraint below. |

Unfiltered hydration **is** Bitblocks' own sync (`SYNCING.md`).
Applications that truly need every transaction should run Bitblocks (or import a pack from `DATA_MANAGEMENT_CONSIDERATIONS.md`), not paginate `GET /api/v1/txs`.

### Producer side (Bitblocks)

**Tag at ingest.**
`FetchTransactionsWorker` already runs analysis per transaction.
Registered filters must be evaluated there (and on reanalysis), writing tags (application id / definition hash / protocol / template) that hydration can range-scan.

**Materialize before serving.**
A hydration request for definition `H` is served from tags where `definition_hash = H` and `height` in range, ordered by `(height, txid)`.
If tags for `H` are incomplete (backfill still running), the plan response says so: `index_state: backfilling`, `indexed_through_height: N`.
Consumers should not see a silent partial set.

**Cursor.**
Opaque or explicit `(height, txid)` plus `snapshot_height` and `definition_hash`.
Pages are stable for a given snapshot.
New blocks do not shift historical pages.

**Completeness.**
Full-block completeness is already audited (`stored txs vs num_tx`).
Filtered completeness is: for each height in range, tagged-match-count equals the count from re-running the filter on that block's stored txs.
Expose this on the plan/status resource so a consumer can refuse to go live on a lie.

**Timeliness.**
- Tip: a matching tx is tagged in the same ingest pass that stores it, then published on the follow channel.
- New filter: enqueue a backfill (do not starve the tip lane — reuse `transactions_tip` vs `transactions_backfill`).
- Lag is a first-class field: `tip_height - last_tagged_height` per definition.

**Rate and load.**
Hydration of a hot filter is sequential by design (cursor pages).
It must not become a table scan of `transactions`.
Anonymous unfiltered history remains gated (shared-RDS constraint; see inbox `API-SURFACE`).

**Reorgs.**
Follow events include reorg notifications (SSE already emits `reorg`).
Consumers rewind to the last height still on the canonical chain and delete or rebuild derived rows above it.
Bitblocks tags for orphaned txs must not remain in the hydration index.

**Definition change.**
A new hash is a new filter.
Supersede links them for humans.
Hydration is per hash: consumers either start a new projection or run a migration map.
Bitblocks does not silently rewrite old tags.

### Consumer side (the application)

Store:

- `definition_hash` they are projecting
- `cursor` `(height, txid)`
- `snapshot_height` of the last completed hydrate
- `map_version` (so they know if their fold matches the definition)

On boot:

1. If no cursor → plan + hydrate from `from_height`.
2. If cursor behind tip → catch-up pages.
3. Then follow.

The map (parse into `listings`, `votes`, `notes`, …) runs **in the consumer** unless they opted into a Bitblocks-side transform.
Bitblocks-side maps are for shared, mechanical shapes (decode MAP, attach spend edges).
Product folds (current listing status, vote tallies) stay in the application so two apps can disagree without forking the index.

Prune locally at will.
The recovery path is always "hydrate again from cursor 0 or from last trusted snapshot".

### Proofs (optional, progressive)

SPV / merkle proofs (`/api/v1/txs/:txid/proof`) let a consumer store evidence with a row instead of a pointer.
Not required for a first hydration.
Required if the consumer will answer to users who do not trust this Bitblocks instance.
BEEF-shaped bundles are a later additive (see votesmash relay notes); they are not blocking for the cursor protocol.

### Dataset packs

For common filters, Bitblocks can export a versioned pack (headers + matching txs + tag snapshot + definition hash).
That is the fast path for local dev and for first-time hydrate of a popular application.
Packs are a distribution of the same hydration API, not a different data model (`DATA_MANAGEMENT_CONSIDERATIONS.md`).

---

## User stories

Personas: existing Explorer, Developer, Operator, Protocol Author; plus two emerging ones used below.

**Application Operator** — runs a db-backed product (qart, votesmash, a niche ledger) that hydrates from Bitblocks.
**App User** — a person who uses more than one such product, holding keys in a wallet.

Stories are planned, not built.
Acceptance criteria are the contract a later implementation must meet.

### US-23-app-registry: Register an application by definition hash

**Status: Not started.**
**Persona:** Application Operator / Protocol Author

As an **Application Operator**,
I want to register my filter and optional map as a content-addressed application definition,
so that Bitblocks will tag matching transactions and other developers can discover and hydrate the same set.

**Acceptance criteria:**

Given a definition document (filters + optional map + version),
When I publish it (on-chain or via the admin/API marked with origin),
Then it is stored under `hash(definition)` and appears in `GET /api/v1/apps` and `/apps`.

Given the same bytes published twice,
When both are ingested,
Then there is still one registry row (idempotent on hash).

Given a definition that supersedes hash `H0`,
When I fetch the new hash,
Then the response lists `supersedes: H0` and `H0` lists `superseded_by`.

Given a transaction matching two registered filters,
When ingest (or re-index) completes,
Then both tags are present — matches are independent.

### US-24-unmatched: Surface unregistered templates

**Status: Not started.**
**Persona:** Protocol Author / Developer

As a **Protocol Author**,
I want to see script templates and prefixes that occur on chain but are not in the registry,
so that I know what to register next.

**Acceptance criteria:**

Given outputs whose template hash is not registered,
When I query the unmatched report,
Then I see `template_hash`, `count`, `first_height`, `last_height`.

Given I then register a definition that matches that hash,
When re-index for that definition completes,
Then those transactions appear in that application's feed and drop off (or recategorize in) the unmatched report.

### US-25-hydrate-initial: First-time filtered hydrate

**Status: Not started.**
**Persona:** Application Operator

As an **Application Operator**,
I want to fill an empty application database with every historical transaction matching my registered definition, up to a frozen snapshot,
so that my product can start from a complete projection.

**Acceptance criteria:**

Given an empty consumer and a registered definition whose tags are `index_state: ready`,
When I `plan` then page `hydrate` until the snapshot cursor,
Then I receive every matching tx with `height <= snapshot_height`, in `(height, txid)` order, with no duplicates.

Given tags are still `backfilling`,
When I `plan`,
Then I receive `index_state: backfilling` and `indexed_through_height`, and hydrate of the unfinished range is refused or explicitly partial.

Given I crash after page 17,
When I resume with the last cursor,
Then I receive page 18 onward without gaps or overlaps.

Given a filter that matches nothing in range,
When hydrate completes,
Then I receive an empty set and a cursor at `snapshot_height` — not an error.

### US-26-hydrate-follow: Catch-up and follow

**Status: Not started.**
**Persona:** Application Operator

As an **Application Operator**,
I want to catch up from my snapshot to the tip and then follow new matches,
so that my projection stays current without re-downloading history.

**Acceptance criteria:**

Given a consumer whose cursor is at snapshot height `H` and the chain tip is `H+k`,
When I request catch-up pages,
Then I receive matches in `(H, H+k]` in order.

Given follow is connected,
When a new block contains a matching tx,
Then I receive that event with an advancing cursor within the ingest SLA (same block's tagging pass).

Given a reorg that invalidates heights above `H`,
When the follow channel emits `reorg`,
Then the payload names the rewind height, and subsequent pages/events start from there.

Given the consumer was down for N hours,
When it comes back,
Then catch-up from stored cursor recovers without a full re-hydrate.

### US-27-identity-chip: Identity on a transaction

**Status: Not started.**
**Persona:** Explorer / App User

As an **Explorer**,
I want to see who authored a transaction (key / AIP / paymail when known) and which registered applications it belongs to,
so that I can jump from a raw tx to the person and the product without decoding hex.

**Acceptance criteria:**

Given a transaction with an AIP signature or a standard unlocking key,
When I view it,
Then I see an identity chip that links to that identity's activity lens.

Given the transaction matched one or more registered applications,
When I view it,
Then I see those application tags, each linking to the application page and to a filtered feed.

Given no AIP and a new key,
When I view it,
Then I see the key/address — I do not see a guessed "person" cluster.

### US-28-identity-across-apps: Activity of a key across applications

**Status: Not started.**
**Persona:** App User / Explorer

As an **App User**,
I want to see which registered applications a key has appeared in,
so that I can understand my (or someone else's public) on-chain footprint without logging into each app.

**Acceptance criteria:**

Given a key that has signed or received matches tagged with apps A and B,
When I open that identity,
Then I see A and B with first/last heights and counts.

Given I connect a wallet to Bitblocks,
When the connected key matches the identity page,
Then the UI indicates "this is you" and still does not create a Bitblocks password account.

Given application C uses encrypted payloads,
When I view that identity's C activity on Bitblocks,
Then I see tagged events and "encrypted" — not decrypted fields.

### US-29-filter-backfill: New filter over history

**Status: Not started.**
**Persona:** Operator / Application Operator

As an **Operator**,
I want a newly registered filter to be applied to historical transactions without starving tip sync,
so that hydration of that application is complete, not tip-only.

**Acceptance criteria:**

Given a new definition registered at tip height `T`,
When backfill runs,
Then historical matching txs below `T` become tagged, and tip ingest continues on the tip lane.

Given backfill is in progress,
When a consumer plans hydration,
Then they see progress (`indexed_through_height`) rather than a silently short set.

Given backfill completes,
When filtered completeness is audited for that definition,
Then tagged counts match re-running the filter on stored txs for the claimed range.

### US-30-unfiltered-is-bitblocks: Full-chain hydrate is running the explorer

**Status: Not started (policy + docs; little new code).**
**Persona:** Developer

As a **Developer**,
I want it to be explicit that "give me every transaction" means running Bitblocks or importing a dataset pack,
so that I do not treat the public tx list API as a chain export.

**Acceptance criteria:**

Given the public API,
When I request unfiltered historical transactions at scale,
Then I am rate-limited or admin-gated (no anonymous full export).

Given I need a local full or wide slice,
When I follow `DATA_MANAGEMENT_CONSIDERATIONS.md` packs or run Bitblocks sync,
Then I can hydrate without that public export.

---

## Design constraints (cross-cutting)

- **Chain is truth; tags and consumer DBs are disposable.**
  Replay (filter + map + version) must reproduce the projection (`UNWRITER_SYNTHESIS.md` Gap 5).
- **Same codebase, subset data.**
  A Bitblock is Bitblocks with a filter, not a second product (`BITBLOCK.md`).
- **Ingest-time over query-time** for anything that claims to be timely.
- **Independent tags**, not a single exclusive "type" per transaction.
- **No Bitblocks SSO.**
  Wallet is session; keys are identity; Bitblocks is the index.
- **Canonical definitions are hashed bytes.**
  The explorer dictionary derives; it does not freelance templates (`DATA_DICTIONARY_SPEC.md`).
- **Tip never starves.**
  Filter backfill uses the backfill lane.
- **Silent partial sets are bugs.**
  Plan/status must say when an index is not ready.
- **Legal/operator filters** (what this instance will not store or serve) are a **local map** on this Bitblocks, documented as such, not smuggled into application definitions.

---

## Open questions

1. **Inline vs registered-only hydrate.**
   Do we allow a one-off filter in the hydration request, or must every hydrate refer to a definition hash (even `local-only`)?
   Lean: hash-only, so tagging and completeness always have a key.
2. **Where the map runs.**
   Shared decode on Bitblocks vs product fold in the consumer.
   Lean: Bitblocks ships mechanical decode; product state stays in the app.
3. **Webhook vs SSE vs poll** as the follow transport for servers.
   SSE exists; webhooks are in `COMPOSABLE_STREAMS.md` and still aspirational.
   Lean: SSE + cursor poll first (survives consumer downtime better than a lone SSE).
4. **On-chain registration envelope.**
   Which protocol carries a definition document (MAP SET, a Bitcom prefix of our own, a script template tx)?
   Decide with the pack, not before.
5. **Identity clustering.**
   Keep it out of default UX (this draft's position) vs offer it as a labeled forensic lens.
6. **`/apps` vs `/protocols` vs `/api/v1/streams`.**
   Three catalogs will confuse people if they are not ranked.
   Lean: Protocols = formats; Apps = products (filters + maps); Streams = named schemas inside an app.

---

## Implementation sketch (not a schedule)

Dependency order, so this does not stall on the mesh/P2P future:

1. **Definition schema + hash** (registry row, origin: chain | api | local).
2. **Tag table** written from ingest + reanalysis (definition hash × txid × vout/height).
3. **Plan + paged hydrate + follow-with-cursor** for one registered filter.
4. **Backfill job** for a newly registered hash (tip lane untouched).
5. **`/apps` + unmatched report** as the human surface.
6. **Identity chip + identity lens** using keys/AIP already on the tx, plus app tags.
7. Optional: Bitblocks-side maps, dataset packs, webhooks, peer hydrate.

Gaps 1 and 3 in `UNWRITER_SYNTHESIS.md` (canonical tx shape, transportable query) make 2–4 cheaper.
They are not strict blockers for a first tagged-protocol hydrate: today's `protocols` / handler tags can prove the cursor protocol before the generic definition hash exists.

---

## Inbox answers (this session)

Votesmash asked whether the data dictionary is derivative of pack definitions, how unmatched templates surface, whether every definition is a filter, and whether Bitblocks hosts registration.

- **Derivative:** yes.
  See `DATA_DICTIONARY_SPEC.md` and § A above.
- **Keying:** content hash of the whole definition.
- **Unmatched:** yes, as a report (US-24).
- **N filters on every tx:** yes; independent tags; re-index on register (US-23, US-29).
- **Registration:** both on-chain (canonical) and API/admin (convenience / local-only).
  Bitblocks hosts the **index** of registrations, not the applications themselves.
