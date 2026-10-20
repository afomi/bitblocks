# Learning from _unwriter: A Synthesis

*Technical feedback on Bitblocks through the lens of _unwriter's Unix-philosophy Bitcoin stack.*

You have a remarkable artifact in `~/workspace/unwriter/` — a near-complete mirror of the interplanaria ecosystem (Planaria, Bitbus, Bitsocket, Bitquery, TXO/BPU/BOB, TXT, Bitcache, Datapay, Overpool, Localchain, bit://, Sticker, Bottle).
It is one of the cleanest expressions of the Unix philosophy applied to a blockchain that exists.
This document synthesizes what made it work, names what Bitblocks already does well, and identifies the gaps — written as constructive feedback, not reverence.

---

## Part 1 — What _unwriter actually did

The genius of _unwriter was not any single tool.
It was a **refusal to invent a fourth convention.**
The entire stack rests on three fixed interfaces, and every tool is small enough to fit in your head because it only ever speaks those three:

1. **A JSON shape for a transaction** (TXO flat / BOB nested).
   Every tool that touches a tx — parser, crawler, indexer, query engine, wallet — speaks `{ tx, blk, in[], out[], e }`.
   Pushdata is positionally addressable (`out.s2`, `out.b1`), opcodes are `{op: 106}`, and the graph edge `e` (which output an input spends, which address an output pays) is baked into the shape.
   The transaction is not a record; it is a **node in a graph, serialized.**

2. **A query that *is* the API** (Bitquery).
   `{ v, q: <mongo find>, r: { f: <jq program> } }`.
   You do not configure an endpoint and hope it returns what you need.
   You write the query, the query travels (base64'd into a URL for SSE, sha256'd into a cache key for batch), and the same document drives history (Bitbus), realtime (Bitsocket), UTXO selection (Datapay), and routing tables (bit://).
   Convention over configuration, taken literally: there is no config, only queries.

3. **A tape** — an append-only, timestamped log (`BLOCK <height> <ts>`, `MEMPOOL <txid> <ts>`) plus content-addressed payload files, surfaced over HTTP/SSE and exported as a portable SQLite file.
   State is a **deterministic, replayable projection of the tape.**
   Reorgs are a `REWIND` line. Crash recovery is "tail the file from where you left off." P2P replication is "email someone the .db."

Three properties fall out of this discipline, and they are the properties Bitblocks should covet:

- **Polyglot by construction.** Bitcache's FAQ says it plainly: everything is HTTP, so use any language. No shared runtime, no SDK lock-in. The integration surface is a wire format, not a library.
- **The chain is the source of truth; every database is disposable.** Delete the index, replay the tape, get the same state. This is why "anyone can run one" is credible — there is nothing precious to back up.
- **Composition by piping, not by importing.** `Bitcoin → TXO → Bitquery → Bitbus/Bitsocket → Planaria → TXT`. Each arrow is a stream of the canonical JSON shape. Each box is replaceable. Grid Planaria's framing — "each edge is a monetization opportunity" — only works *because* the edges are clean pipes.

The deepest idea, and the one most worth stealing: **the gene is the identity.**
A Planaria node is defined by its filter + its fold function. What you filter for *is what you are*.
This is exactly your `BITBLOCK.md` thesis — and you already know it, because you wrote the Planaria→Bitblock mapping table yourself.

App-by-app mapping of the [unwriter.net](https://unwriter.net/) timeline onto Bitblocks language: `docs/UNWRITER_APPS.md`.

---

## Part 2 — What Bitblocks does well

This is not faint praise. Bitblocks has real engineering that _unwriter's stack lacked, and several of these are genuine advances.

**1. OTP / supervision is a categorical upgrade over the Node.js tape-tailing model.**
_unwriter's crash-safety was "re-read `tape.txt` from the last line." Yours is Oban: durable job queues, `max_attempts`, unique constraints on `block_hash`, resumable `FetchTransactionsWorker` that counts existing rows and picks up mid-block.
The `FetchTransactionsWorker` resumability (querying which txids already exist, `filter_already_fetched`) is a more honest version of tape-replay — it survives partial failure at the *transaction* granularity, not just the block boundary.
This is the right kind of "boring infrastructure."

**2. RPC batching is a real performance asset _unwriter never built.**
`batch_rpc/1`, `batch_getblockhash`, `fetch_block_transactions/2` chunking by 100 — sending arrays of JSON-RPC commands in one POST is exactly the kind of throughput work the Node tools skipped. Keep this.

**3. The three-phase header/txid/full-tx sync is genuinely smart and well-documented.**
Header-only sync at ~400 bytes vs downloading a 2.3GB block is the single most important decision for syncing modern BSV, and `SYSTEM_ARCHITECTURE.md` explains it clearly. _unwriter never had to confront 4M-tx blocks; you do, and your phasing is the correct response.

**4. The spend index (`spend_index`: `txid, vout → spending_txid, spending_vin`) is a real graph primitive.**
This is the closest thing in your codebase to _unwriter's `e` edge — and in some ways better, because it's a queryable relation rather than an embedded field. Absence-of-row = live UTXO is a clean model.

**5. Time↔height translation (CHAIN_LENS) is implemented and useful.**
`/blocks/at_time`, `/blocks/time_map?from&to&step` — `height_at_time`, `height_time_samples`. This is a genuinely nice primitive that _unwriter didn't expose, and it's *actually built*, not aspirational.

**6. SSE streams are real and PubSub-backed.**
`/api/v1/stream/blocks` emits `new_block, block_synced, reorg, sync_progress` over `text/event-stream` with heartbeats, fed by `Phoenix.PubSub`. This is the Bitsocket idea, done with better internal plumbing.

**7. The conceptual docs are ahead of almost everyone.**
`BITBLOCK.md`, `CHAIN_LENS.md`, `COMPOSABLE_STREAMS.md`, `OUTPOINT.md` — you have already metabolized Planaria and projected it forward (mesh of filtered views, CDN-inverted economics, browser-side OPFS Bitblocks). The *thinking* is excellent. The gap, as Part 3 shows, is that the thinking has outrun the code.

---

## Part 3 — What Bitblocks can learn from _unwriter (the gaps)

I'll be direct, because that's more useful than flattery. The grounding survey of your actual code found a consistent pattern: **the unglamorous infrastructure is built and good; the composable/convention layer that makes _unwriter _unwriter is largely missing or hardcoded.** Five gaps, in priority order.

### Gap 1 — There is no canonical transaction shape. This is the foundational one.

Today, `Transaction.inputs` and `Transaction.outputs` are `{:array, :string}` where each element is **RPC vin/vout JSON re-encoded with `Jason.encode!`** — opaque blobs you must `Jason.decode` per element to read a single field.
There is no BOB/TXO equivalent. The rich chunk parsing in `TransactionParser`/`ProtocolParser` happens at request time and is **never persisted**.

Why this matters: _unwriter's entire composability flows from the fact that *every tool agrees on `out.s2`*. You cannot build a query language, a pluggable parser, or a filter spec on top of opaque JSON strings. The transaction shape is the bedrock; right now yours is sand.

**Recommendation:** Adopt (or adapt) BOB as a persisted, normalized representation. A JSONB `bob` column, or a proper `outputs`/`inputs` table with positional script-chunk rows (`tape_index, cell_index, b, s, h, op, ops`). This single change unlocks Gaps 2–4. It is the highest-leverage refactor available to you. Note you already vendor `txo`/`bpu`/`bob` in `tmp/` and `op_agent/lib/operate/bpu/` — you have reference implementations on disk.

### Gap 2 — Protocol parsing is hardcoded, and the registry that should drive it is dead.

`detect_protocol/1` matches a module attribute `@protocol_prefixes` (6 addresses) plus a `case` in `ProtocolParser.build_protocol_data` (`"Twetch" | "Metanet" | "OrderBook"`). Adding a protocol requires editing three functions — i.e. **forking.**
Worse: `ProtocolRegistry.Protocol` has a `schema :map` field that is *defined and migrated but never read by any parser* (grep confirms zero references). The on-sync `analyze/1` path doesn't consult the registry at all.

This is the opposite of the gene model. In Planaria, the filter+fold *is* user-supplied data. In Bitblocks, it's compiled-in code with a decorative DB catalog beside it.

**Recommendation:** Make the registry load-bearing. Drive detection and parsing from the `schema` field — a declarative spec (which OP_RETURN position holds the prefix, how to split, which cells map to which fields). Even a modest version ("prefix at `out.s1`, fields are pipe-delimited cells N..M") would let someone register a protocol without a deploy. This is your "anyone can run one" promise, applied to parsers instead of nodes.

### Gap 3 — There is no query language. The API is a fixed menu, not a kitchen.

The entire query surface is `apply_transaction_filters`: `block_hash`, `txid` prefix, `protocol`, `has_inputs/outputs`, `min_inputs/outputs`. That's it. Consumers cannot compose predicates.
_unwriter's insight was that **the query is the API** — you ship a query engine, not a thousand endpoints.

You don't need MongoDB. You have Postgres and Ecto, which are *stronger*. But you need a **safe, declarative, transportable query format** that maps to parameterized Ecto — the Bitquery role, played by your stack.

**Recommendation:** Define a JSON query DSL (`{ where: {...}, select: [...], limit }`) that compiles to whitelisted Ecto fragments over the normalized tx shape from Gap 1. Crucially, make it **transportable** the way Bitquery is: a query you can base64 into an SSE URL (`/stream?q=...`) so a filtered subscription is *just a query*, not a new controller action. That closes the loop on `COMPOSABLE_STREAMS.md`, which is currently aspirational.

### Gap 4 — BITBLOCK (your best idea) has zero code.

`BITBLOCK.md` is excellent and it is **entirely unimplemented** — no filter-spec parser, no subset sync, no scoped UI, no deployment mode. The grounding survey was unambiguous here.
This is the Planaria gene model, which is the thing you most admire and have most clearly articulated. It is stranded in a doc.

Notice the dependency: a Bitblock *is* "a transportable filter (Gap 3) over a normalized shape (Gap 1), applied during sync." You cannot build Bitblock cheaply until Gaps 1 and 3 exist. Sequence accordingly — but this is the destination, and Gaps 1–3 are the road to it.

**Recommendation:** Once a query DSL exists, a Bitblock is a thin config: `filter: <query>, sync_source: <url>`. The `FetchTransactionsWorker` already has the resumable-cursor machinery; a Bitblock is that worker pulling from `/api/v1/txs?q=<filter>&since_height=<cursor>` instead of from a node. The mesh/P2P future in the doc is real but distant; the single-source Bitblock is achievable and is the proof of the whole thesis.

### Gap 5 — Lean harder on "the chain is truth; the DB is disposable."

_unwriter's tape model gives a property you've partly lost: **deterministic rebuild.** Replay the tape → identical state. Your sync is durable (Oban) but not obviously *replayable from a canonical log* — state lives in Postgres and is mutated in place. The `Machinery` state machine is declared but the workers bypass it, transitioning via raw `Ecto.Changeset.change`, so even the state model is half-wired.

This isn't urgent, but it's a north star: if every derived row is reconstructible from (chain + filter + parser-version), then caching, the TX_CDN, browser Bitblocks, and the P2P mesh all become *trivially* correct, because nothing is precious. _unwriter got this for free by making the tape primary. You can get it by treating the chain + a versioned parser as the only sources of truth and everything else as a cache. Your `script_analysis_version` field shows you're already thinking this way — extend that instinct to the whole pipeline.

---

## Part 4 — Constructive technical feedback (systems-level)

Stepping back from the per-gap view, three architectural observations:

**1. Your docs are writing checks your schema can't cash — and that's a fixable sequencing problem, not a vision problem.**
You have ~8 ambitious design docs (Bitblock, composable streams, custom indexing, data dictionary, composable primitives) and the implemented core is header-sync + batched tx fetch + spend index + time↔height + SSE + S3 CDN. The vision is coherent; the issue is that almost every ambitious doc depends on a **normalized tx shape + a query language** that don't exist yet. **Build those two things and four docs become implementable in a quarter.** Don't add a ninth design doc until Gap 1 ships.

**2. Half-wired abstractions are worse than no abstraction.**
The `Machinery` state machine is declared but bypassed. The registry `schema` field exists but is dead. These cost reader-confidence: a newcomer sees `transition_changeset/3` and assumes transitions go through it — they don't. Either wire them up or delete them. _unwriter's tools were trustworthy partly because they were *small* — there was no dead scaffolding to mislead you. Match that honesty.

**3. You've inverted _unwriter's "small tools, thin glue" into "one app, many features."**
Bitblocks is a monolith with ~40 LiveViews, an API, a sync engine, a protocol registry, an order book, a mining proxy, a Metanet explorer. _unwriter would have shipped this as eight composable services speaking one tx format.
The monolith is a *legitimate* choice — OTP makes in-process composition cheap and safe, and you avoid the operational tax of eight services. But the risk is that internal boundaries blur because nothing forces them to be clean. **The discipline _unwriter got from process boundaries, you must impose with module boundaries and a canonical internal data shape.** The normalized tx struct (Gap 1) is also your internal contract: if every context module — Chain, ProtocolParser, OrderBook, Metanet — consumes the *same* normalized tx, you get _unwriter's composability inside one BEAM. That's the synthesis: _unwriter's conventions, OTP's supervision, one process. That's a genuinely better architecture than either alone — but only if the shared shape is real.

---

## The one-sentence version

_unwriter proved that a blockchain becomes programmable when you fix exactly three conventions — a transaction shape, a transportable query, and a replayable tape — and refuse to add a fourth; Bitblocks has built the harder infrastructure _unwriter lacked (OTP durability, RPC batching, phased sync) but has not yet committed to those three conventions, and **the entire gap between your excellent docs and your working code is the gap between having infrastructure and having conventions.**

Fix the transaction shape first. Everything else is downstream of that.
