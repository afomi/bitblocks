# Docs Index

Entry point for `docs/`.
Docs fall into three categories.
**Current system** docs describe implemented, verifiable behavior — when they disagree with the code, the code wins and the doc should be fixed.
**Design & vision** docs are aspirational: proposals, product framing, and future architecture that is not (or only partially) built — do not treat them as descriptions of the running system.
**Protocol references** are background material on Bitcoin/BSV formats and external ecosystems, independent of what bitblocks implements.
Docs marked *(mixed)* are mostly aspirational but contain sections that accurately describe current code; the note says which.

## Current system

- `SYSTEM_ARCHITECTURE.md` — background services, job queues, and async work that keep the index in sync.
- `SYNCING.md` — single source of truth for how Bitblocks syncs the chain (code-authoritative).
- `SYNC_PIPELINE.md` — process map of the running sync pipeline.
- `PERFORMANCE.md` — RPC- and HTTP-layer optimizations under the sync jobs.
- `MEMORY_OPTIMIZATION.md` — diagnosing and fixing BEAM memory pressure in the running app.
- `LARGE_BLOCKS.md` — handling multi-million-tx blocks and hundreds-of-MB RPC responses.
- `LARGE_SCALE_DB.md` — running Bitblocks against a 20TB+ PostgreSQL database.
- `IP_BLOCKING.md` — blocking abusive IPs, including the auto-ban feature.
- `MERKLE_PROOFS.md` — the `/api/v1/txs/:txid/proof` endpoint and `MerkleVerifier` internals.
- `THREAT-MODEL.md` — Microsoft-SDL threat model for the public-facing explorer/indexer; most controls are implemented (see BACKLOG Completed → Security).
- `SITEMAP.md` — all routes, grouped by access level and function.
- `BSV20_TOKENS.md` — the implemented BSV-20/BSV-21 token indexer (read side of the DEX).
- `BITCOM.md` — the live Bitcom registry: command log, tiers, `/bitcom` pages, JSON export.
- `DONATION_ADDRESS.md` — bitblocks' BSV donation address: derivation (wallet, new hardened account), xpub verification, spending rules.
- `ORDER_BOOK_PROTOCOL.md` — the Open Order Book protocol spec and its implemented indexing/query surface.
- `MINING_PROXY.md` — the Elixir block-template server; written as a design doc but the steps are implemented (`Bitblocks.MiningProxy`, `getblocktemplate`, `/api/v1/mining/*`).
- `OBSERVATIONS.md` — dated snapshot (2026-03-28) of observations, challenges, and opportunities across bitblocks/qart.
- `REFACTORING_SUMMARY.md` — record of a past DRY refactoring pass.
- `SUMMARY.md` — record of a past enhancement session (telemetry, monitoring, etc.).
- `IMAGE_PROMPTS.md` — prompts used to generate the illustrations in `priv/static/images/`.

## Design & vision (aspirational)

- `ACCOUNT_MODEL.md` — account-based model over the UTXO ledger: indexer-level account views (Layer 1) plus sCrypt/OP_PUSH_TX stateful covenants (Layer 2), aimed at Ethereum-developer DX.
- `ADOPTION_SPECTRUM.md` — framework for ledger use cases from Pay to Prove and what each means for an explorer.
- `BITBLOCK.md` — vision: a "Bitblock" as a filtered chain instance (same codebase, subset database, git-like sparse checkout).
- `CAPABILITIES_AND_SERVICES.md` — design notes on on-chain data services, anchored in git mechanics and Unix philosophy.
- `CHAIN_LENS.md` — the lens pattern: full chain + filter = subset chain, with time↔height translation.
- `COMPOSABLE_PRIMITIVES.md` — maps Bitcoin's primitives (keypair, outpoint, scripts, covenants) toward a composition-first interface paradigm.
- `COMPOSABLE_STREAMS.md` — schema-named domain-object streams: define, write (qart), index (bitblocks), subscribe.
- `CUSTOM_INDEXING.md` — *(mixed)* accurate on the current parsing pipeline (`TransactionParser`, `ProtocolRegistry`, `ProtocolParser`); aspirational on schema-driven views as a paid product.
- `DATA_DICTIONARY_SPEC.md` — proposed versioned catalog of transaction/script/envelope formats backed by on-chain examples; derivative of transaction-pack definitions (content-hash keyed).
- `USE_CASES.md` — draft use cases for Bitblocks as full-chain support for other applications: application registry, cross-app identity UX, and hydration (initial + ongoing).
- `DATA_MANAGEMENT_CONSIDERATIONS.md` — proposal for tiered, importable chain dataset packs instead of full local sync.
- `EVENT_DRIVEN_OBJECT_ORIENTED_BITCOIN.md` — sketch for representing CRUD actions as immutable Bitcoin events (Bitcom + AIP + schemas).
- `NEXT_GEN_BLOCK_EXPLORER.md` — works backward from a 2032-scale explorer: intent-centric, entity-centric, operational intelligence.
- `PAYMENT_CHANNELS.md` — charging satoshis per API request via off-chain payment channels.
- `PROVENANCE.md` — on-chain attribution for AI training data: hash vs body vs identity trade-offs, pseudonymous authorship, training-run manifests, and where credit/compensation calculation actually happens.
- `REUSABLE_SCRIPTS.md` — content-addressed script functions: store once, reference by hash, verify at spend time.
- `TX_CDN.md` — the chain as an immutable, content-addressed CDN origin with zero cache invalidation.
- `TX_METADATA.md` — *(mixed)* the layered tx-metadata model behind the Progressive TX Metadata work; its phase status table is stale (all six phases have since shipped — see BACKLOG Completed).
- `UNWRITER_SYNTHESIS.md` — lessons from _unwriter's Unix-philosophy stack (TXO/BOB, Bitquery, tape) applied as feedback to Bitblocks.
- `UNWRITER_APPS.md` — table of every app on [unwriter.net](https://unwriter.net/) mapped to Bitblocks terminology (filter / map / hydrate / follow), plus core stack pieces the unofficial timeline omits.
- `VALIDATION_ORACLES.md` — off-chain validation with signed attestations enforced by on-chain covenants.

## Protocol references

- `BITCOIN_URL.md` — Bitcoin URI schemes for payments and QR-code point-of-sale flows across chains.
- `OUTPOINT.md` — the `<txid>_<vout>` outpoint format and how inputs reference outputs.
- `EXTERNAL_APIS.md` — live-probed reference of WhatsOnChain and GorillaPool API shapes to guide Bitblocks' own API.
- `MINING.md` — how BSV mining works and the template/hashing split architecture (background for the mining proxy).
- `OP_PUSH_TX.md` — the sighash-preimage technique that lets a locking script inspect and constrain its spending transaction; intermediate-level, for developers and designers.
- `SCRIPT_RUNTIME.md` — the script execution model from first principles (stack machine, predicate-not-program) and BSV's introspection/meta-programming capabilities across three scopes: within a tx, across existing txs, in the mempool; written for readers from OOP/FP/logic-programming backgrounds, with intuition pumps.
- `SPV_TUTORIAL.md` — Simplified Payment Verification from whitepaper §8 up: what it is, the four ingredients, a worked payment example, obvious and non-obvious uses (proof-carrying payments/BEEF, in-script SPV, portable receipts), and the failure/misuse/abuse catalog.
- `LINEAGE_PROOF_WALKTHROUGH.md` — opcode-level walkthrough of an inductive token lineage proof (backtrace covenant): stack traces for each stage, forgery analysis, the recursion tax, and the symmetry with bitblocks' indexer-enforced BSV-20 validation.
- `PSBT_FOR_DESIGNERS.md` — PSBTs explained in product terms for designers.
- `PSBT_VISUAL_PATTERNS.md` — visual metaphors and trust affordances for PSBT workflows.
- `VAPOR_TIMESTAMP_NOTES.md` — visual reference for the Vapor node cooperative timestamping flow.

## Other

- `bitblocks.tldr` — tldraw canvas (diagram source), not a prose doc.
