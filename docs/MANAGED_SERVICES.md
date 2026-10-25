# Managed Services — prototype scenario

Status: prototype scenario (2026-10-23).
Nothing here is built unless it names an existing module, route, or index.

Bitblocks keeps the full chain so that other applications don't have to.
A **shared managed service** turns that into something other projects can rely on: we run their filter against the full index, keep it current, and serve it to them.
This is Planarium's job (unwriter's hosted Planaria farm), rebuilt on Bitblocks and under Bitblocks' own names (rebrand rule, `UNWRITER_APPS.md`).

Source catalog: [Planaria use cases](https://afomi.github.io/planaria#use).
Do not duplicate:
- `USE_CASES.md` is the full product framing of those 14 use cases, the vocabulary (filter, map, hydrate, follow, cursor), and user stories US-23 to US-30 (issue #14).
- `BITBLOCK.md` covers the self-hosted subset instance.

This doc adds the **hosted, multi-tenant** angle, plus one concrete scenario to prototype against.

---

## The service in one paragraph

A tenant registers a **projection**: a filter, plus an optional mechanical map.
Bitblocks tags matching transactions at ingest, backfills the tags over history without starving the tip, and serves them three ways:
- **hydrate:** paged history up to a snapshot, with a cursor;
- **follow:** new matches over SSE, by poll, or by webhook;
- **status:** lag, completeness, and whether the index is ready.

The tenant keeps its own database and its own fold, and never runs a node.
What it pays for is timeliness and bandwidth, not storage of the chain.

"Shared" means one node, one index and one ingest pass serve every tenant.
The marginal cost of a projection is its tags and its traffic, not another 20 TB.

---

## What already exists to build on

These ingest-time tags are GIN-indexed on `transactions` today, so filters on them are index lookups, not scans:

| Filter type | Column | Since |
|---|---|---|
| Paid-to address | `output_addresses` | `20260420232000` |
| Protocol (prefix / MAP app) | `protocols` | `20260420215433` |
| Script / template hash | `output_script_hashes`, `output_template_hashes` | `20260712000001` |
| AIP signer | `aip_signers` | `20261019000002` |

Also available:
- **Spend edges:** `Chain.record_spends`.
- **SSE streams:** `/api/v1/stream/*`, which emit `reorg` events.
- **Merkle proofs:** `/api/v1/txs/:txid/proof`.
- **Completeness audit:** `Release.audit_completeness/1`.
- **Separate lanes for backfill and tip.**
- **One working projection, end to end:** the Bitcom registry (`bitcom_commands`), which is a filter, plus a mechanical map, plus served views.

`USE_CASES.md` § C notes that today's tags can prove the cursor protocol before a generic definition hash exists.
The prototype takes that route.

Missing for a managed service:
- tenant identity (API keys) and quotas, which ties to #12 and #13;
- a cursor-paged hydrate API;
- webhooks;
- per-projection lag and completeness.

Built (#29 steps 1–2): the projection record and hydrate, `Bitblocks.Projections` and `/api/v1/projections/:id/txs`.

GIN serves containment (`col @> ARRAY[x]`), not membership (`x = ANY(col)`, which is what Ecto's `^x in t.col` compiles to).
Before 2026-10-25 the address, script and template lookups used membership, so on prod they scanned the whole table, `/api/v1/support` included.
They now use containment, and `test/bitblocks/array_index_queries_test.exs` keeps it that way.

---

## Scenario: four tenants on one index

The tenants are real projects in the portfolio, so the prototype has real users from day one.
Each one exercises a different Planaria use case.

### Tenant 1: Visible DAO open books

*Planaria use cases: Public Utility Database, Analytics Database, Bitcoin as IPC.*

Visible DAO's `/bitblocks` sponsor page (handoff `from-bitblocks-2026-10-20-sponsor-the-node`) needs every payment to the donation address, and needs to know as soon as one lands.

- **Filter:** `output_addresses @> [donation_address]`.
- **Map (mechanical):** amount paid to that address per tx, height, time, and txid with a proof link.
- **Hydrate:** every donation ever received, so the ledger rebuilds from zero.
- **Follow:** a webhook to the site's build hook (or an email) when a donation confirms. This is "Bitcoin as IPC": a payment triggers a rebuild and a thank-you.
- **Today:** `GET /api/v1/support` is a hard-coded, single-tenant version of this projection, using `Chain.received_for_address/2`.
- **Gap:** cursor paging; the webhook; excluding change sent back to the address (see `DONATION_ADDRESS.md`).

### Tenant 2: qart receipts and listings

*Planaria use cases: Web Application Backend, Ephemeral Database.*

qart signs receipts with AIP and lists items with MAP (`app=qart`).
It wants its own Postgres to be a projection of the chain, rebuildable at any time.

- **Filter:** `protocols @> [MAP]`, with MAP `app = qart`, **and** `aip_signers @> [qart_key]`.
  The AND is the part that matters: it is a filter only qart's key can satisfy, so spoofed `app=qart` transactions are ignored.
- **Map:** none on the Bitblocks side. The fold (open listings, receipt status) stays in qart, per `USE_CASES.md` § C.
- **Hydrate, then follow over SSE with a cursor.** On a reorg, qart rewinds to the last canonical height.
- **Today:** the tags exist. Hydrate, follow-with-cursor, and the AND across two tag columns don't.

### Tenant 3: the Bitcom registry, as a tenant of itself

*Planaria use cases: Multi-purpose Backends, Portable Applications.*

The Bitcom registry is already a projection: the filter is Bitcom prefixes and `$` commands, the map is `Bitcom.index/1`, and the views are `/bitcom` and the export.
Re-plumbing it as an ordinary managed projection proves the service is general, not a special case.
It also makes the registry **forkable**: anyone can hydrate the same command log and derive a different registry. That's the "portable application" story of protocol upgrades and governance by fork.

- **Filter:** tx contains a `$` Bitcom command (first-class tag, or `bitcom_commands` as the materialized tag set).
- **Today:** fully built, except that it isn't served through the shared hydrate/follow API.

### Tenant 4: a county attestation ledger (stretch)

*Planaria use cases: Long-tail Applications, Prunable Database, Transparent Private Computing.*

The civic lane (jurisdictional and civil-registry projects) needs attestations published by a small set of government addresses, for one county.
That's a niche, long-tail database: tiny, high-value, and prunable (keep only the current attestation per record).
Sensitive records can be published encrypted. The projection serves ciphertext and metadata, and only stakeholders hold the keys. The log is auditable, and its meaning stays private.

- **Filter:** paid-from or signed-by a set of county addresses (`aip_signers` covers the signed-by case), plus an `attest` protocol tag.
- **Gap:** an index of input-side addresses for "paid-from" (spends exist, but not as an address filter); an agreed attest format (see the `standards-steward` agent before fixing one).

---

## The prototype slice

Build in dependency order, each step with a test, and do it CLI-first: a context API and a mix task, then the HTTP surface.

1. **Projection record.** Built: `Bitblocks.Projections`, `test/bitblocks/projections_test.exs`.
   `projections`: id, tenant, filter spec (JSON over the four tag columns), created_at, status.
   Test: a spec over two tag columns round-trips and compiles to an indexed query; `EXPLAIN` uses the GIN indexes and doesn't sequentially scan `transactions`.
2. **Hydrate with a cursor** for Tenant 1: `GET /api/v1/projections/:id/txs?cursor=` ordered by `(block_height, txid)`, frozen at `snapshot_height`.
   Built: `Projections.hydrate/2`, `GET /api/v1/projections/:id/txs`, `Release.create_projection/1`.
   Test: paging the whole set equals the unpaged query, and a new block doesn't shift earlier pages.
3. **Status.**
   `indexed_through_height`, `lag_blocks`, `index_state: ready | backfilling`.
   Test: a projection over a height range with missing blocks reports `backfilling`, never a silent partial set.
4. **Follow by webhook** for Tenant 1: an Oban job posts `{projection, txid, height, cursor}` on each new match, retries with backoff, and is signed with a per-tenant secret.
   Test: a matching tx at the tip enqueues exactly one delivery; a reorg sends a `reorg` event carrying the rewind height.
5. **Tenant keys and quotas:** per-tenant API key, a request budget, and tip-lag targets.
   This is the first real step on #12 (anonymous load) and #13 (edge rate limiting).
6. **Tenant 2 (qart)** on the same API, which exercises the AND filter and SSE follow.
   Then **Tenant 3**: serve `bitcom_commands` through it.

Done for the prototype means:
- Visible DAO's sponsor page rebuilds from `hydrate` alone, and gets a webhook within one block of a donation;
- qart can drop its database and rebuild it from hydrate plus follow.

---

## Economics (prototype stance)

The node costs about $1,000 a month and is shared by every tenant (`DONATION_ADDRESS.md`).
Sponsorship (#26) keeps the public utility free.
A managed projection is a **service**, so it is a separate line on the books.
Free tier: one projection with modest lag targets.
Paid tiers would charge for lower lag, webhooks, higher request budgets, and Bitblocks-side maps.
Payment in BSV fits naturally later (`PAYMENT_CHANNELS.md`). Prototype tenants are our own projects and pay nothing.
Keep the sponsorship ledger and service revenue separate, the same rule as the separation from personal funding (#27).

---

## Open questions

1. **Name.**
   "Projection" works as the noun. The hosted product needs a Bitblocks name; per the rebrand rule it can't be Planarium.
2. **Filter language.**
   Is JSON over the four tag columns enough for the prototype, or do we adopt the definition hash from `USE_CASES.md` § A now?
   Lean: JSON first, then hash the JSON as the definition id. Same bytes, no new language.
3. **Where maps run.**
   Mechanical decoding stays on Bitblocks (amount to address, MAP decode); product folds stay with tenants (open question 2 in `USE_CASES.md`).
4. **Tenancy on a shared RDS.**
   Hydrating a hot projection reads `transactions`.
   Do we need a read replica before the first external tenant?
5. **Input-side address index.**
   Tenant 4 and any "paid-from" filter need one. It's a large-table index, so it must be built concurrently (#28).
6. **Trust.**
   Tenants who answer to their own users should store merkle proofs (`/proof`) with their rows, and later BEEF (#17).
