# THREAT-MODEL.md — `bitblocks`

Microsoft-SDL threat model for the bitblocks BSV explorer/indexer.
**Assumption: this is a public-facing service on the open internet**, and a funded adversary is
actively trying to exhaust it, poison its data, scrape it for free, make it leak secrets, or pivot
through it to the BSV node behind it.

What bitblocks is — and is not — determines the whole model:

- bitblocks is a **read-side indexer**: it pulls blocks/txs from a BSV node over RPC, stores them in
  PostgreSQL, and serves a public Phoenix LiveView UI plus a JSON/SSE API.
- bitblocks **does not sign, custody, settle, or move value.** It has no private keys for user funds,
  no game state, no randomness beacon, no consensus role. Whole classes of threat from a value-bearing
  SDK (move forgery, beacon bias, settlement conservation, auto-signing) **do not apply here** — there
  is nothing to forge a signature *for*. This is the single most important scoping fact.
- Its real adversaries are **the network, the upstream node, and unauthenticated API callers** — not
  "other players."

This document is intended to live in the repo and be updated in the same change as the code it
describes. Where a control is **not yet built**, it says so honestly in §5.

## 1. Assets
- **A1 — Service availability** (the explorer + API stay up and responsive). This is the *primary*
  asset; bitblocks holds no funds, so denial-of-service is the highest-value attack against it.
- **A2 — Data integrity of the index** (blocks/txs in PostgreSQL faithfully mirror the chain). A
  consumer of the API trusts that what we return matches the real chain.
- **A3 — Secrets** (RPC credentials for the BSV node, admin basic-auth credentials). Leaking these
  hands an attacker the upstream node and the admin surface.
- **A4 — The upstream BSV node** (reachable only through bitblocks from the public side). bitblocks
  must not become an amplifier or proxy that lets the internet drive the node.

## 2. Trust boundaries
- **TB1 — the public internet → web/API.** Every HTTP request, path param, query param, and SSE
  subscription is HOSTILE until validated. No authentication on `/api/v1/*` (§5), so this boundary
  carries the most risk.
- **TB2 — the upstream BSV node → indexer.** Semi-trusted but **not unconditionally trusted**: the
  node can be slow, return oversized payloads (a single mainnet block is GBs), return malformed JSON,
  or be a compromised/rogue node feeding poisoned data. Every response is bytes to be bounded and
  validated before it touches the DB.
- **TB3 — third-party proxies (WhatsOnChain).** Address/UTXO/balance endpoints proxy to an external
  service. Its responses are untrusted input, and our *requests* to it must not be injectable by a
  caller-controlled path param.
- **TB4 — admin surface** (`/config`, `/debug`, `/sync`, edit pages). Privileged; gated by HTTP basic
  auth. The boundary between "public read" and "operator write" must not be crossable.

## 3. Threats → mitigations (STRIDE)

Legend: ✅ enforced in code · ⚠️ partial / weak default · ❌ not yet built (see §5).

| # | Threat | STRIDE | Status | Mitigation · code | Test |
|---|---|---|---|---|---|
| T1 | Exhaust the service with unauthenticated request floods | DoS | ✅ | Per-IP rate limit 20 req/60s sliding window over ETS, applied globally at the endpoint. Admitted requests are broadcast to peer nodes via `RateLimiter.Replicator` over the existing distributed PubSub, so the cap is **cluster-wide**, not per-instance (eventually consistent; small bounded leak before propagation). Lazy table creation is race-safe (REQ-DOS-001 · `plugs/rate_limiter.ex`, `plugs/rate_limiter/replicator.ex`). **Caveat:** requires the Erlang cluster to actually be connected (DNSCluster); for a hard guarantee, also enforce at the edge. | `replicator_test.exs` |
| T2 | Unbounded concurrent SSE connections wedge the server | DoS | ✅ | `SseLimiter` caps concurrent streams globally (default 500) and per IP (default 5), enforced **cluster-wide**: `acquire/1` counts local + summed peer tallies gossiped by `SseLimiter.ClusterState` (per-node tallies, not deltas, so a crashed node self-heals out via `:nodedown`/TTL). `StreamController` releases the slot in an `after` block and caps each connection's **lifetime** (default 30 min → `event: reconnect` + close) so slots churn (REQ-DOS-002 · `sse_limiter.ex`, `sse_limiter/cluster_state.ex`, `controllers/api/stream_controller.ex`). **STREAM-AUTH decision 2026-07-11:** SSE streams stay public *by design* — bounded, not authenticated (global 500 / per-IP 5 slot caps, 30-min lifetime); this is a product decision, not a gap. | `sse_limiter_test.exs`, `cluster_state_test.exs`, `stream_controller_test.exs` |
| T3 | Oversized/malformed node payload OOMs or crashes a worker | DoS / Tampering | ✅ | RPC client caps response body at 500 MB; tx fetch batched at 100, header sync at 500, both resumable. Raw tx hex now decodes through `SafeTx.from_hex/1` (size-bounded, total — see T5). The `Transaction.changeset` `validate_required([:txid, :raw, :version, :block_hash, :inputs, :outputs])` + `cast` reject malformed/incomplete node tx data before insert (REQ-DOS-003, REQ-VAL-002 · `chain/safe_tx.ex`, `chain/transaction.ex`, workers). | `safe_tx_test.exs`, worker tests |
| T4 | Poisoned data from a rogue/compromised upstream node corrupts the index | Tampering | ✅ | **Headers:** `HeaderVerifier` re-derives the block hash + checks PoW (`bits` target); `SyncHeadersWorker` also requires each header to chain onto the predecessor we hold (`previousblockhash == block[height-1].hash`) — rejecting relabelled, trivially-mined, *and* off-chain headers. **Txs:** `MerkleVerifier` rebuilds the merkle root from the ordered txid list (gate before fetch), and each fetched body is verified to hash to its txid (`body_matches_txid?`) — so neither a doctored txid list nor a doctored body under a valid txid survives (REQ-VAL-001 · `chain/header_verifier.ex`, `chain/merkle_verifier.ex`, workers). **Update 2026-07-12:** the former >10k-tx merkle-skip is closed — `TxidSource` (`chain/txid_source.ex`) re-fetches the txid list for blocks whose array isn't stored, so **all** blocks are merkle-verified, including >10k-tx ones. | `header_verifier_test.exs`, `merkle_verifier_test.exs`, `fetch_transactions_worker_test.exs`, `sync_headers_worker_test.exs` |
| T5 | Crash a parser with malformed tx/block hex | DoS | ✅ | **Root cause found & fixed:** `BSV.Tx.from_binary/2` is *not* total — it raises `CaseClauseError` on empty/truncated/garbage/oversized-varint input, defeating the plain `case` wrappers that 9 call sites relied on. `SafeTx.from_hex/1` is now the single chokepoint: size-bounded (rejects before decode) and total (`try/rescue/catch` → typed error, never raises). All 9 decode sites route through it. A **30k-iteration seeded fuzz battery** asserts it never raises across random/mutated/truncated/varint-edge/non-binary inputs (REQ-DOS-003/CWE-20/248/770 · `chain/safe_tx.ex`). | `safe_tx_test.exs` (~30k iterations) |
| T6 | SQL injection / dynamic-query abuse via path or filter params | Tampering / EoP | ✅ | All DB access goes through Ecto with `^`-bound parameters; `ilike` prefix searches use a fixed `"#{x}%"` template, not raw interpolation (REQ-VAL-003 · `chain.ex` `apply_transaction_filters/2`, order-book filters). No raw SQL string-building found. | — |
| T7 | Request-smuggling into an external proxy URL via path param | Tampering / SSRF-ish | ✅ | `BsvParams.{txid,address}/1` validate to a strict charset/length before the value is `URI.encode_www_form`'d into the WhatsOnChain path; invalid → 400, never an outbound call. The proxy suffix is derived from the action, not the param, so the route shape isn't caller-influenceable (REQ-VAL-004 · `utils/bsv_params.ex`, `address_controller.ex`, `utxo_controller.ex`). | `bsv_params_test.exs`, `address_controller_test.exs`, `utxo_controller_test.exs` |
| T8 | PubSub channel-name injection via `token_id` | Tampering | ✅ | `/stream/order-book` validates `token_id` via `BsvParams.token_id/1` (hex + optional `_vout`, no `:` or `/`) **before** it becomes a topic; invalid → 400 with no slot consumed (REQ-VAL-005 · `stream_controller.ex`, `utils/bsv_params.ex`). | `stream_controller_test.exs`, `bsv_params_test.exs` |
| T9 | Secrets leak into logs or responses | Info disclosure | ✅ | RPC creds ride an `Authorization: Basic` header that is **not** logged. Error paths now use `Logger` with a `redact/1` helper that truncates node-supplied bodies/reasons to 500 bytes — no raw `IO.puts` of node responses, no flooding (REQ-SEC-002 · `bitcoinsv_cli.ex`). | — (log-path; covered by review) |
| T10 | Admin surface reached with default / guessable creds | EoP | ✅ | `AdminAuth.decide/3` fails closed: in any non-dev/test env, a default username *or* password is refused with a 503 instead of serving the panel. **Update 2026-07-12:** the operator surface (`/sync`, `/config`, `/debug`, `/admin`, `/rpc_admin`, `/metrics`, mutation LiveViews) now pipes through `:admin` in **every** env — the compile-time dev/test bypass is gone. Enforcement is runtime config (`config :bitblocks, :admin_auth, enabled:`): prod fails closed on defaults (unchanged), dev enforces with logged dev-default creds (overridable via `ADMIN_USERNAME`/`ADMIN_PASSWORD`), test disables the gate in config only (REQ-SEC-003 · `admin_auth.ex`, `router.ex`). | `admin_auth_test.exs`, `admin_gate_test.exs` |
| T11 | Unauthenticated write via `/api/v1/mining/submit` | Tampering / EoP | ✅ | **Two crash vectors found & fixed:** `String.to_integer` raised on a non-numeric nonce/timestamp, and a value ≥ 2³² crashed the `::little-32` header packing. Both are now parsed totally and bounded to an unsigned 32-bit int via `parse_u32/1` → 400 on bad input. The proxy is disabled by default and any submission is PoW-gated (`:hash_above_target`), so a bad solution is rejected, not applied; auth remains a deployment choice for this opt-in feature (REQ-SEC-004 · `mining_controller.ex`). | `mining_controller_test.exs` |
| T12 | Free bulk scraping / cost-shifting onto the upstream node | DoS / abuse | ⚠️ | Pagination is capped (per_page ≤ 100 across controllers) ✅, which prevents unbounded single queries; but proxy endpoints (address/UTXO/balance) turn one cheap public call into one upstream WhatsOnChain call with only the 20 req/min IP limit in front (REQ-DOS-004). **Accepted-residual 2026-07-12:** the remaining amplification risk is accepted pending the EDGE-RATE infrastructure decision (edge rate limiting at nginx/ALB/Cloudflare); no further in-app mitigation planned. | — |

## 4. Engineering controls (what already holds by construction)
- **Parameterized queries everywhere** — no raw SQL assembly; Ecto `^`-binds are the only path to the
  DB (defeats T6).
- **Bounded pagination** — every list endpoint caps `per_page`/`limit` at ≤ 100 and validates
  `offset ≥ 0` (block, transaction, protocol, order-book controllers).
- **Resumable, batched workers** — tx fetch (100) and header sync (500) batch and checkpoint, so a
  crash mid-large-block resumes instead of restarting; Oban `max_attempts` bounds retries.
- **Global rate-limit plug** — one IP-keyed sliding window in front of all routes (caveat: per
  instance).
- **Auto-ban on probe patterns** — `request_logger.ex` bans an IP after 10 suspicious/4xx requests in
  300s and flags traversal/injection/scanner signatures.
- **Credentials in headers, not URLs/logs** — RPC auth is a basic-auth header that is never emitted to
  logs.
- **Total, bounded tx decode** — all raw-hex decoding goes through `SafeTx.from_hex/1`, which is
  size-bounded and never raises on hostile input (the underlying `BSV.Tx.from_binary/2` does). Proven
  by a 30k-iteration fuzz battery. Validated identifiers (`BsvParams`) gate proxy URLs and PubSub
  topics by strict charset before interpolation.

## 5. Residual risks / not-yet-built (honest)
These are the gaps a reviewer should weigh before treating bitblocks as hardened. **None of the SDL
source doc's value-integrity controls (signed envelopes, beacon verification, settlement conservation,
constant-time compare) exist here — and most of them are simply N/A** because bitblocks signs and
settles nothing. The ones that *do* matter and are missing:

1. **SSE connection bounds (T2)** — **DONE.** `SseLimiter` enforces a global + per-IP cap on
   concurrent streams; the controller returns 503 over the cap and releases slots on exit. Remaining:
   an idle/lifetime timeout, and moving the counter off per-instance ETS before horizontal scaling.
2. **Upstream-node verification (T4)** — **DONE.** Enforced before persisting: header
   self-consistency (`blockhash == sha256d(header)`), proof-of-work (`hash ≤ target(bits)`),
   prevhash-chain continuity, the txid list matching the header merkleroot (`MerkleVerifier`, gated in
   `FetchTransactionsWorker`), and per-tx body-hash↔txid verification.
   The former merkle-check *skip* for >10k-tx blocks is closed as of 2026-07-12: `TxidSource`
   (`lib/bitblocks/chain/txid_source.ex`) re-fetches the txid list when the stored array is absent,
   so ALL blocks are merkle-verified.
3. **Stream authentication (STREAM-AUTH / T2)** — **DECIDED 2026-07-11, accepted as designed.**
   Product decision: SSE streams stay public and bounded rather than authenticated.
   The bounds are the `SseLimiter` slot caps (global 500 / per-IP 5) and the 30-minute connection
   lifetime.
   Revisit only if streams start carrying non-public data.
4. **Cluster dependency (T1/T2)** — cross-instance rate limiting *and* the SSE cap rely on the Erlang
   cluster actually being connected via DNSCluster. If the cluster is partitioned or not formed, both
   degrade gracefully to per-instance enforcement (never fail closed on the request path). Edge
   enforcement (ALB/WAF) remains the belt-and-suspenders for a hard guarantee.
5. **Upstream proxy amplification (T12)** — **ACCEPTED-RESIDUAL 2026-07-12.**
   The WhatsOnChain proxy endpoints remain a 1:1 amplifier behind the 20 req/min IP limit.
   Accepted pending the EDGE-RATE infrastructure decision (edge rate limiting at
   nginx/ALB/Cloudflare); no further in-app mitigation planned.

### Closed since the initial model
- **T1** cluster-wide rate limiting — `RateLimiter.Replicator` broadcasts admitted hits over PubSub so
  the per-IP cap holds across instances (eventually consistent).
- **T2** SSE connection bounds — `SseLimiter` (global + per-IP cap, 503 over cap), now enforced
  cluster-wide via `ClusterState` gossip, + per-connection max-lifetime cap (recycles slots).
- **T3/T5** total + bounded tx decoder — `SafeTx.from_hex/1` replaces 9 fragile `BSV.Tx.from_binary`
  call sites (which raised on malformed input); 30k-iteration fuzz battery proves totality.
- **T4** upstream-node verification — header self-consistency + PoW + prevhash continuity +
  merkleroot↔txid-list + per-tx body-hash↔txid.
  As of 2026-07-12 `TxidSource` re-fetches txid lists for blocks whose array isn't stored, so the
  merkle check covers ALL blocks — the former >10k-tx skip is closed.
- **T7/T8** proxy-URL and PubSub-topic injection — `BsvParams` validation + URL encoding.
- **T9** log redaction — `Logger` + `redact/1`, no raw node bodies to stdout.
- **T10** admin fail-closed — `AdminAuth.decide/3` refuses default creds outside dev/test.
- **T10 follow-up (2026-07-12)** all-env operator-surface gating — the router's compile-time dev/test
  auth bypass is removed; `/sync`, `/config`, `/debug`, `/admin`, `/rpc_admin`, `/metrics`, and the
  block/tx mutation LiveViews pipe through `:admin` in every env, with enforcement toggled at runtime
  via `config :bitblocks, :admin_auth, enabled:` (prod fail-closed unchanged, dev warns on default
  creds, test bypasses in config only).
- **T9 follow-up (2026-07-12)** request-log redaction — `RequestLogger` replaces query-string values
  for sensitive keys (token/key/secret/password/auth/api_key/apikey/signature, case-insensitive) with
  `[REDACTED]` before logging 4xx/suspicious requests.
- **T11** mining-submit hardening — `parse_u32/1` bounds nonce/timestamp (two crash vectors fixed).
- *Bonus:* fixed a latent ETS `ensure_table` race that could crash the rate/SSE limiters under
  concurrent first-hits.

---

*This model is grounded in the current code (see file:line references above). It should be updated in
the same change as the code it describes. Threat IDs above (REQ-DOS-*, REQ-VAL-*, REQ-SEC-*) are local
to this document — bitblocks does not yet carry a formal requirement-traceability scheme like the
source SDK's REQ-BAN-*/REQ-SEC-* IDs.*
