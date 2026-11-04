# Personas

The people who use Bitblocks, each with a different relationship to the data.

## What Bitblocks is to all of them

Bitblocks is transparency and simplicity: a thin, fast web layer over a node, database records and command-line tools.
Every number on a page is a record the API also serves, and every operation is a command with a result you can read (`/about`).
Each persona below meets that promise from a different side.

## Why people come here

| Reason | Persona | Starts at | Stories |
| --- | --- | --- | --- |
| Look up one transaction of their own | Transactor | homepage search | US-why-own-tx |
| Look up somebody else's transaction | Explorer | a shared link, or homepage search | US-why-others-tx |
| Need a stream of chain data, as a developer, researcher or institution | Developer | homepage "Use the data", `/pricing` | US-why-stream |
| Hydrate a wallet that has its keys but not its transactions, proofs and metadata | Wallet Builder | `/about`, `/api/v1/script/*` | US-why-wallet-hydrate |
| Trust what they read | every persona | `/about` | US-why-transparency |

---

## Transactor

**Role:** Someone who sent or received a payment and wants to see it on chain. No account, no code.

**Responsibilities:**
- None organizational; it is their own money or data.

**Goals:**
- Paste a txid and see that it is confirmed, and in which block.
- Know whether Bitblocks has every transaction for that block yet.
- Take away proof of inclusion they can show someone else.

**Context:**
- Arrives with a txid copied from a wallet, an exchange or a receipt.
- Uses homepage search, then the transaction or block page; opening a transaction's inputs and outputs needs GitHub sign-in.
- Wants an answer in one step, without learning the explorer first.

---

## Explorer

**Role:** Curious person reading somebody else's activity on the chain: a payment, a token, an inscription. No account, no code.

**Responsibilities:**
- None organizational; uses Bitblocks for personal understanding, journalism or research.

**Goals:**
- Understand what a specific transaction contains and what it means.
- Follow value from one address or UTXO to another.
- Discover what protocols and on-chain content exist on BSV.

**Context:**
- Arrives via a shared link to a txid or block height, or from general curiosity.
- Uses the web UI: `/blocks`, `/transactions/:id`, `/types`, `/bitcom`, `/collections`, `/metanet`.
- Non-technical — wants human-readable labels, not raw hex or opcodes.
- May be encountering Bitcoin for the first time.

---

## Developer

**Role:** A data customer: a developer, researcher or institution that reads the chain from a program and needs a reliable stream of it.
Builds applications on top of BSV, or studies the chain; treats Bitblocks as infrastructure.

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
- An institution or researcher wants a key with its own budget, a stated coverage ("complete through block X") and records it can re-verify.

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

---

## Wallet Builder

**Role:** Builds or runs a wallet that holds the user's keys and has to fill itself with what those keys own.

**Responsibilities:**
- Restores a wallet from keys: every transaction for its scripts, the outputs still unspent, a merkle proof for each, and what each output is (plain coin, token, inscription).
- Keeps that state current as new blocks arrive.

**Goals:**
- Hydrate a wallet from keys alone, without running a node.
- Verify each transaction against a block header itself, not trust Bitblocks.
- Avoid spending an output that carries a token or an ordinal by mistake.

**Context:**
- Until wallets keep their own transactions, proofs and metadata, they need a service to hydrate them: a file explorer for a wallet.
- Uses `GET /api/v1/script/:scripthash/history` and `/unspent`, `GET /api/v1/txs/:txid/proof`, and `GET /api/v1/outpoints/:txid/:vout`.
- Related to the App User, who holds the keys; the Wallet Builder is the software and its maintainer acting for them.
- Today it is one call per script and one per proof; a batch, BEEF-shaped answer (#17) is the natural next step.
