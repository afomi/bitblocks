# Personas

Three distinct users of Bitblocks, each with a different relationship to the data.

---

## Explorer

**Role:** Curious person reading the blockchain — no account, no code.

**Responsibilities:**
- None organizational; uses Bitblocks for personal understanding or research.

**Goals:**
- Understand what a specific transaction contains and what it means.
- Follow value from one address or UTXO to another.
- Discover what protocols and on-chain content exist on BSV.

**Context:**
- Arrives via a shared link to a txid or block height, or from general curiosity.
- Uses the web UI exclusively: `/blocks`, `/transactions/:id`, `/metanet`, `/order-book`.
- Non-technical — wants human-readable labels, not raw hex or opcodes.
- May be encountering Bitcoin for the first time.

---

## Developer

**Role:** Builds applications on top of BSV; treats Bitblocks as infrastructure.

**Responsibilities:**
- Parses protocol data (Twetch, Metanet, OrderBook, BCat, etc.) for their own product.
- Queries transaction history, UTXO state, and protocol feeds to power features.
- Monitors the chain in real time for events relevant to their app.

**Goals:**
- Query blockchain data reliably via REST API without running a full node.
- Filter transactions by protocol, address, token, or block range.
- Receive real-time events (new blocks, order book changes) via SSE.
- Understand the on-chain wire format for protocols so they can produce and consume them.

**Context:**
- Integrates with `/api/v1/*` endpoints from server-side code or client-side JS.
- Reads `docs/ORDER_BOOK_PROTOCOL.md`, `docs/SYNCING.md`, and similar specs.
- May run Bitblocks locally against a testnet node during development.
- Cares about schema stability, pagination, and error codes.

---

## Operator

**Role:** Runs the Bitblocks instance — deploys, monitors, and maintains sync.

**Responsibilities:**
- Keeps the node connected and headers/transactions synced.
- Monitors queue depth, sync state, error rates, and DB health.
- Responds to incidents: stalled sync, out-of-disk, failed workers.
- Controls admin access and applies security configuration.

**Goals:**
- Detect and recover from sync gaps or worker failures quickly.
- Keep the DB current with the chain tip without manual intervention.
- Know that security controls (rate limits, SSE caps, admin auth) are active.
- Run backfills or targeted re-syncs without downtime.

**Context:**
- Uses the admin panel (`/sync`, `/rpc_admin`, `/pulse`, `/reporting`) and Prometheus metrics.
- Runs `bin/bitblocks rpc` commands for one-off operations.
- Reads logs and Oban dashboard to diagnose worker state.
- May be the same person as the Developer, but operating in a different mode.

---

## Protocol Author *(emerging)*

**Role:** Registers and maintains a named on-chain protocol in the Bitblocks registry.

**Responsibilities:**
- Defines the OP_RETURN format, field semantics, and version progression for their protocol.
- Keeps documentation, example txids, and source references up to date.

**Goals:**
- Have their protocol auto-detected and indexed as transactions arrive.
- Expose a parsed feed via `/api/v1/protocols/:address/feed` so Developers can consume it.
- Track protocol adoption stats over time.

**Context:**
- Currently no self-service UI — registration is via migration.
- The `protocols` table has `author`, `documentation_url`, `source_url`, `example_txid` fields anticipating this persona.
- Deferred until self-service registration is built; noted here as the schema is already designed for it.

---

## Application Operator *(emerging)*

**Role:** Runs a db-backed product (qart, votesmash, a niche or family ledger) that treats Bitblocks as the chain log to hydrate from.

**Responsibilities:**
- Declares a filter (and optional map) as an application definition.
- Operates the product's own database as a projection of that filter.
- Keeps a hydration cursor current (first-time hydrate, catch-up, follow, reorg rewind).

**Goals:**
- Fill an empty DB with a complete historical match set, then stay at the tip.
- Discover whether Bitblocks has already tagged their filter (or must backfill).
- Not run a full-chain node in order to ship a narrow application.

**Context:**
- Integrates with proposed plan/hydrate/follow APIs (`docs/USE_CASES.md`).
- May be the same person as Developer, acting as operator of a consumer app rather than of Bitblocks itself.

---

## App User *(emerging)*

**Role:** A person who uses more than one on-chain application, holding keys in a wallet.

**Responsibilities:**
- Signs in each application with the wallet (not with a Bitblocks account).

**Goals:**
- Be the same person across apps without a new password per product.
- See, when they choose, which registered applications a key has appeared in.
- Keep private (encrypted) application fields out of the public explorer.

**Context:**
- Session is the wallet (BRC-100 / similar).
- Bitblocks is an identity *index* and optional "viewing as" chrome, not SSO.
- Default explorer UX is key-scoped, not clustered-person-scoped.
