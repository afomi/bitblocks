# User Stories

Stories are in standard format: persona, action, outcome, acceptance criteria.
Completed stories are in `PLAN.md` (scenario format with test references).
This file covers **active, in-progress, and planned** work.

Personas defined in `PERSONAS.md`.
Concepts defined in `CONCEPT_INVENTORY.md`.

---

## Progressive Transaction Metadata

### US-13-3: Spend Depth

**Status: Done.** — `Chain.spend_depth/1`, `spend_depth` on `GET /api/v1/txs/:txid`.

As a **Developer**,
I want to query the spend depth of a UTXO,
so that I can determine how many times value has moved since it was minted in a coinbase transaction.

**Acceptance Criteria:**

Given a UTXO identified by `(txid, vout)`,
When I query its spend depth,
Then I receive an integer count of hops from the coinbase that originally minted the value to the current outpoint.

Given the UTXO is unspent (not yet in `spend_index` as a consumed input),
When I query its depth,
Then I receive the depth to that outpoint (not an error).

Given a coinbase output,
When I query its spend depth,
Then I receive `0`.

*Depends on: Phase 1 (Spend Tracking — complete), Phase 2 (Coinbase Detection — complete).*

---

### US-13-5: Full Script Parsing

**Status: Done.** — P2PKH, P2SH, P2PK, multisig, OP_RETURN, unknown.

As a **Developer**,
I want to extract semantic fields from any standard script type,
so that I can work with public key hashes, multisig parameters, and other script data without parsing raw opcodes myself.

**Acceptance Criteria:**

Given a P2PKH locking script,
When I parse it,
Then I receive the public key hash as a hex string.

Given a P2SH locking script,
When I parse it,
Then I receive the script hash.

Given a multisig locking script (M-of-N),
When I parse it,
Then I receive M, N, and the list of public keys.

Given an OP_RETURN script,
When I parse it,
Then I receive the data pushes as a list of byte arrays.

Given an unrecognized script type,
When I parse it,
Then I receive `{:unknown, raw_asm}` — no crash, no silent data loss.

---

### US-13-6: Local Address Balance

**Status: Done.** — local `spend_index` + `output_addresses`; no WhatsOnChain proxy.

As an **Explorer**,
I want to query the balance of a Bitcoin address,
so that I can see how much BSV is held at that address without relying on an external service.

**Acceptance Criteria:**

Given a valid BSV address,
When I query `/api/v1/addresses/:address/balance`,
Then I receive the confirmed balance in satoshis computed from local UTXO data.

Given the same address queried twice with no new transactions,
When both requests complete,
Then both return the same balance (deterministic from local data).

Given an address with no transactions,
When I query its balance,
Then I receive `0` satoshis — not an error.

Given an address that currently proxies to WhatsOnChain,
When local UTXO data is sufficient,
Then the proxy is no longer called (local data takes precedence).

*Depends on: Phase 1 (Spend Tracking — complete), Phase 5 (Address Extraction — partial).*

---

## Threat Model

### US-16-stream-auth: SSE Authentication

**Status: Closed — decided, no implementation.**
Decided 2026-07-11: streams stay public; bounded by SseLimiter slot caps (global 500 / per-IP 5) + 30-min lifetime; revisit if a paid tier appears.
No code change.

As an **Operator**,
I want SSE stream endpoints to be authenticated,
so that real-time blockchain data is not freely available to unauthenticated clients if the product requires it.

**Acceptance Criteria:**

Given the `STREAM_AUTH_REQUIRED` config is enabled,
When a client connects to `/api/v1/stream/blocks` without a valid token,
Then the connection is rejected with `401` before any SSE slot is consumed.

Given a client with a valid token,
When they connect to an SSE stream,
Then they receive the stream normally.

Given the config is disabled (default),
When any client connects,
Then streams remain world-readable (no regression from current behavior).

*Note: Implementation approach (API key, session, JWT) is the open product decision.*

---

### US-16-edge-rate-limit: Edge-Level Rate Limiting

**Status: Needs decision** — afomi/bitblocks#13 *(deployment config, not application code).*

As an **Operator**,
I want a hard rate and connection limit enforced at the load balancer or WAF,
so that the cluster-wide application-level limiters have a backstop if the Erlang cluster isn't fully connected.

**Acceptance Criteria:**

Given a single IP exceeds the configured request rate,
When the LB/WAF rule fires,
Then requests are dropped at the edge before reaching the application.

Given the Erlang cluster is partitioned (nodes not connected),
When the LB/WAF limit is active,
Then per-node application limits are still bounded by the edge cap.

*Note: Configuration lives in infrastructure (nginx/ALB/Cloudflare), not in this codebase.*

---

## Application support (draft)

Draft use cases, identity UX, and hydration design live in `docs/USE_CASES.md`.
Stories US-23 through US-30 are specified there (application registry, unmatched templates, initial hydrate, follow, identity chips, cross-app identity, filter backfill, unfiltered-export policy).
Not started — design only.

---

## Sync Integrity

### US-20-sync-integrity: Completeness Audit + Diff-and-Fill Repair

**Status: Done.**

As an **Operator**,
I want a completeness audit (stored tx rows vs `num_tx` per block) and a repair that idempotently fills only the missing transactions,
so that no block is silently missing transactions.

**Acceptance Criteria:**

Given blocks in any sync state,
When I run the audit,
Then it lists every block whose stored transaction count is below its `num_tx` (deficit blocks).

Given a set of deficit blocks,
When I run the repair,
Then they are re-queued through the sequential backfill worker and only the missing transactions are fetched (idempotent).

Given a block with stored transactions fewer than `num_tx`,
When sync state transitions are evaluated,
Then the block is never marked `completed`.

Given a backfill interrupted by restart or failure,
When the hourly cron runs,
Then the backfill resumes where it left off.

**Tests:** `txid_source_test.exs`, `backfill_transactions_worker_test.exs`, `fetch_transactions_worker_test.exs`, `release_audit_test.exs`.

---

## Script-First Explorer

### US-21-script-first: Script-First Explorer

**Status: Done (phase 6 uncommitted)** — script cards with template and protocol badges; afomi/bitblocks#6.

As a **Developer / Explorer**,
I want the explorer to treat scripts as first-class objects — a script descriptor, a `Protocol.Handler` registry, a scripthash-addressed API (`GET /api/v1/script/:scripthash/history`, `GET /api/v1/script/:scripthash/unspent`, `POST /script/decode`), a `script_templates` registry, and script-card rendering,
so that I can look up any locking script by hash, decode arbitrary scripts, and reuse script templates (serving the qart round-trip and terms script-template needs).

**Acceptance Criteria:**

Given a scripthash for an indexed locking script,
When I query `/api/v1/script/:scripthash/history` or `/unspent`,
Then I receive the matching transaction history or unspent outputs.

Given a raw script,
When I `POST /script/decode`,
Then I receive its structured descriptor (type, fields, matched template/handler if any).

Given a registered script template or protocol handler,
When a matching output is rendered in the UI,
Then it renders as a script card driven by the descriptor.

*Phased delivery: phases 1-6 (descriptor → handler registry → scripthash API → decode endpoint → templates registry → script-card rendering).*

---

## Security Hardening

### US-22-sec-harden: Operator Surface Hardening

**Status: Implemented, uncommitted** — afomi/bitblocks#5.

As an **Operator**,
I want the operator surface admin-gated in all environments, query strings redacted in RequestLogger output, and repo hygiene enforced (`.env*`, `erl_crash.dump` ignored),
so that operational tooling and logs never leak secrets or expose admin controls.

**Acceptance Criteria:**

Given any environment (dev, test, prod),
When an unauthenticated client requests an operator/admin page,
Then access is denied.

Given a request whose query string contains sensitive values,
When RequestLogger records it,
Then the query string is redacted in the log output.

Given the repository,
When secrets or crash dumps are produced locally (`.env*`, `erl_crash.dump`),
Then they are ignored by git and never committed.

---

## Tokens

### US-19-token-index: BSV-20 / BSV-21 Token Indexing

**Status: Done.** — see `docs/BSV20_TOKENS.md`.

As an **Explorer**,
I want a token's `token_id` from an order-book listing to resolve to a real token with its supply and holders,
so that I can understand what is being traded without leaving the explorer.

**Acceptance Criteria:**

Given a confirmed BSV-21 `deploy+mint` inscription,
When the transaction is ingested,
Then a token is indexed with `token_id = "<txid>_<vout>"` and its declared supply, queryable at `/tokens/:id` and `GET /api/v1/tokens/:id`.

Given a BSV-21 `transfer` inscription crediting an address,
When it is ingested,
Then that address's balance for the token is reflected in `GET /api/v1/tokens/:id/holders`.

Given an order-book listing whose `token_id` matches an indexed token,
When I view `/order-book`,
Then the `token_id` links to that token's `/tokens/:id` page.

Given a classic (ticker-based) BSV-20 op,
When it is ingested,
Then it is detected and stored for visibility (detect-only) — full first-is-first supply aggregation is deferred to a later version.

*Minting (composing, signing, broadcasting the inscription) is out of scope for bitblocks; it is handed off to qart.*

## BCat

### US-18-reassemble: BCat File Reassembly

**Status: Deferred** — afomi/bitblocks#15; requires fetching N chunk txs from node or WhatsOnChain.

As an **Explorer**,
I want to reassemble and view the full content of a BCat file from its head transaction,
so that I can read large on-chain files without manually fetching and joining each chunk.

**Acceptance Criteria:**

Given a BCat head transaction at `/transactions/:id`,
When I click "Reassemble",
Then the application fetches all chunk transactions in order and returns the assembled binary.

Given the assembled content has a known MIME type (e.g. `image/png`, `text/plain`),
When rendered,
Then the content is displayed inline (image shown, text shown) or offered for download.

Given one or more chunk transactions are not yet indexed,
When reassembly is attempted,
Then I receive a clear error indicating which chunks are missing — not a silent partial result.

*Coordinate end-to-end test with qart once they broadcast a testnet BCat file.*
