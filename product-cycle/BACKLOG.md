# Backlog — history

Open work moved to GitHub Issues on 2026-10-19: https://github.com/afomi/bitblocks/issues
This file keeps the record of work completed before that move.
Personas → `PERSONAS.md` · Stories → `USER_STORIES.md` · Concepts → `CONCEPT_INVENTORY.md` · Data model → `DATA_MODEL.md`

Dropped on migration (not code tasks for this repo): LIVEBOOK (deployment config), COMMERCE and COMMONS (owned by qart).

---

## Completed

### Blockchain Visualization

- **Seeing Bitcoin** — 3D block graph (THREE.js), LOD, playback controls, genesis/coinbase highlight, UTXO spent/unspent. Tests: `block_graph_live_test.exs`.
- **3D BSV Ecosystem** — Force-directed graph at `/ecosystem`. Tests: `ecosystem_live_test.exs`.
- **Shape Layer NFT** — GeoJSON NFT with bounds/center, SVG viewer at `/shape-layers`. Tests: `shape_layer_test.exs`, `shape_layer_live_test.exs`.

### On-Chain Content & Protocols

- **Transaction Composition** — vCard parser for OP_RETURN payloads, tx call graph at `/tx-graph`. Tests: `vcard_parser_test.exs`, `tx_graph_live_test.exs`.
- **Editable On-Chain Profile** — DID + vCard service endpoints, Verifiable Credential issuance. Tests: `vcard_did_test.exs`, `credential_types_test.exs`.
- **BSV SaaS Platform** — B:// and Ordinal content detection with MIME categorization. Tests: `content_detector_test.exs`.
- **Bitcoin schema.org Templates** — Event/Product/Person payloads, event sourcing aggregator. Tests: `schema_template_test.exs`.
- **Twetch Protocol Feed** — Piped protocol detection (B:// | MAP | AIP), MAP `app` field, feed API. Tests: `transaction_parser_test.exs`, `protocol_feed_test.exs`, `protocol_parser_test.exs`.
- **Metanet Explorer** — DAG traversal, MURL, breadcrumb UI at `/metanet`, API endpoints. Tests: `metanet_parser_test.exs`, `metanet_test.exs`, `metanet_live_test.exs`, `metanet_controller_test.exs`.
- **BCat Protocol Detection** — Head + chunk detection, UI panel with chunk txid links, protocol seed migration. Tests: `transaction_parser_test.exs`, `bcat_info_test.exs`.

### Order Book

- **Open Order Book Protocol** — Permissionless BSV-20 marketplace: parse, detect, query, filter, cancel, fill, SSE stream, LiveView. Tests: `order_book_parser_test.exs`, `order_book_test.exs`, `order_book_controller_test.exs`, `order_book_live_test.exs`.
- **Protocol v1** — Versioning + on-chain pre-signed offer (`SIGHASH_SINGLE | ANYONECANPAY | FORKID`). Tests: `order_book_parser_test.exs`, `protocol_parser_test.exs`.
- **Settlement Detection** — Implicit fill via `spend_index`; `settle_spent_token_utxos/1` wired into `record_spends`. Tests: `order_book_test.exs`.
- **Market Data** — `token_market/1` (last price, 24h volume, high/low), `token_trades/2` (recent-first history). Tests: `order_book_test.exs`, `order_book_controller_test.exs`.

### Tokens

- **BSV-20 / BSV-21 Token Indexer** — Read side of the DEX. `Bsv20Parser` extracts `application/bsv-20` inscriptions from output locking scripts; `Tokens` context indexes BSV-21 `deploy+mint`/`transfer` (id-based, fully) and detects classic BSV-20 ticker ops (detect-only). Ingest hook `Chain.index_tokens/1`; `/api/v1/tokens/*` + SSE; `/tokens` LiveView with per-token supply + holders; order-book `token_id` cross-links to `/tokens/:id`. BSV-21 id `<txid>_<vout>` matches the order book's `token_id`, closing the DEX read loop. Minter (compose/sign/broadcast) handed off to qart. Tests: `bsv20_parser_test.exs`, `tokens_test.exs`, `index_tokens_test.exs`, `token_controller_test.exs`, `token_live_test.exs` — 41 tests, 0 failures. See `docs/BSV20_TOKENS.md`.

### Adoption

- **Guide** — Educational page at `/guide` covering all features and external resources. Tests: `guide_live_test.exs`.

### Script-First Explorer

- **SCRIPT-FIRST (US-21-script-first)** — Mostly completed (phases 1-6). Phase 1: Script core (descriptor, decode). Phase 2: `Protocol.Handler` behaviour + compile-time `Handlers` registry (one module per protocol, ordered detection parity with the legacy tables) + `Protocol.RegistryCache` (ETS cache of DB-registered prefix-only protocols — add a protocol without a deploy). Phases 3-4: scripthash indexing + API (`GET /api/v1/script/:scripthash/history|unspent`, `POST /api/v1/script/decode`). Phase 5: `script_templates` registry (`Bitblocks.Script.Templates`, `GET|POST /api/v1/script/templates`, `GET .../:template_hash`, `GET .../:template_hash/history`). Phase 6: script-card rendering — **in review** (LiveView work in a parallel session). Tests: `handlers_test.exs`, `registry_cache_test.exs`, `script_controller_test.exs`, templates tests. Serves the qart round-trip and terms script-template needs.

### Infrastructure & Sync

- **SYNC-INTEGRITY (US-20-sync-integrity)** — Completeness audit + diff-and-fill repair. `Release.audit_completeness/1` lists deficit blocks (stored tx rows vs `num_tx`) across all sync states; `Release.repair_incomplete_blocks/1` idempotently re-queues only the missing transactions through the sequential backfill worker. `TxidSource` + `TxIngest` modules extracted; blocks never marked completed unless stored >= `num_tx`; hourly `BackfillTransactionsWorker` cron resumes interrupted backfills; RPC mock infra (`rpc_stub`/`bitcoinsv_cli_mock`) for worker tests. Tests: `txid_source_test.exs`, `backfill_transactions_worker_test.exs`, `fetch_transactions_worker_test.exs`, `release_audit_test.exs`, `sync_live_test.exs`. See `docs/SYNCING.md`.
- **Two-Job Sync Model** — `SyncHeadersWorker` (range + tip modes) + `FetchTransactionsWorker`. Replaced 5 legacy modules (~2,600 lines). Tests: `sync_headers_worker_test.exs`.
- **Progressive TX Metadata Phase 1** — `spend_index` table, `record_spends`, backfill. Tests: `spend_index_test.exs`.
- **Progressive TX Metadata Phase 2** — Coinbase detection via `transactions.coinbase`. (Prior work.)
- **Progressive TX Metadata Phase 4** — Script type classification via `transactions.output_types`. (Prior work.)
- **AWS SES mailer** — `Swoosh.Adapters.AmazonSES` wired in `runtime.exs` using EC2 instance role (no static keys). `Bitblocks.Notifications.reorg_alert/3` sends operator email on reorg detect/resolve; called from `SyncHeadersWorker.handle_reorg/2`.
- **Progressive TX Metadata Phase 3 (spend depth)** — `Chain.spend_depth/1` does BFS from a txid back to any coinbase ancestor via `input_txids`, returning `{:ok, depth}` or `{:error, :not_found | :max_depth_exceeded}`. Wired into `GET /api/v1/txs/:txid` as `spend_depth` field. Tests: `spend_index_test.exs`, `transaction_controller_test.exs` — 20 tests, 0 failures.
- **Progressive TX Metadata Phase 6 (local address balance)** — `Chain.utxos_for_address/1` and `Chain.balance_for_address/1` serve local data from `spend_index` + `output_addresses` (GIN index). `AddressController` drops the WhatsOnChain proxy; both endpoints return `source: "local"`. Tests: `address_controller_test.exs` — 11 tests, 0 failures.
- **Progressive TX Metadata Phase 5 (partial→complete)** — `determine_script_type/1` and `extract_script_fields/1` now correctly pattern-match BSV library chunk atoms (`:OP_DUP`, `:OP_HASH160`, etc.) for P2PKH, P2SH, P2PK, multisig, OP_RETURN, and unknown. Fixed co-located `is_op_return?/1`, `parse_op_return_data/1`, and `extract_hex_data/1` which shared the same broken `%{op: N}` map patterns. Tests: `transaction_parser_test.exs` — 33 tests, 0 failures.
- **StatsCache Stabilization** — ETS cache + `pg_class` fast count, no full-table COUNTs on page load. Tests: `stats_cache_test.exs`.

### Security (Threat Model)

- **T2 — SSE slot cap** — `SseLimiter` with per-IP + global cap, cluster-wide gossip. Tests: `sse_limiter_test.exs`, `stream_controller_test.exs`, `cluster_state_test.exs`.
- **T2 — SSE lifetime cap** — 30-min hard deadline, `event: reconnect`. Tests: `stream_controller_test.exs`.
- **T3/T5 — Total tx decoder** — `SafeTx.from_hex/1` size-bounded + total; 30k-iteration fuzz battery. Tests: `safe_tx_test.exs`.
- **T4 — Header verification** — SHA256d re-derivation + PoW target check in `HeaderVerifier`. Tests: `header_verifier_test.exs`.
- **T4 — Merkle root verification** — `MerkleVerifier` gates `FetchTransactionsWorker` before any fetch. Tests: `merkle_verifier_test.exs`, `fetch_transactions_worker_test.exs`.
- **T4 — Chain continuity** — `prevblockhash` checked against stored predecessor. Tests: `sync_headers_worker_test.exs`.
- **T4 — Tx body hash** — Each fetched tx verified to hash to its claimed txid. Tests: `fetch_transactions_worker_test.exs`.
- **T7/T8 — Input validation** — `BsvParams` validates txid/address/token_id before proxy or PubSub. Tests: `bsv_params_test.exs`, `address_controller_test.exs`, `utxo_controller_test.exs`, `stream_controller_test.exs`.
- **T9 — Log redaction** — `redact/1` truncates node response bodies in error logs.
- **T10 — Admin auth fail-closed** — Refuses to serve admin surface with default credentials in prod. Tests: `admin_auth_test.exs`.
- **T11 — Mining submit bounds** — `parse_u32/1` bounds nonce/timestamp; non-numeric → 400. Tests: `mining_controller_test.exs`.
- **T1/T12 — Cluster-wide rate limiting** — `RateLimiter.Replicator` broadcasts hits over PubSub. Tests: `replicator_test.exs`.
- **STREAM-AUTH — SSE authentication (decision)** — Decided 2026-07-11: streams stay public; bounded by SseLimiter slot caps (global 500 / per-IP 5) + 30-min lifetime; revisit if a paid tier appears. No code change.

---
