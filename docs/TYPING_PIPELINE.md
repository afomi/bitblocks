# Full coverage, strong typing, and first seen

Status: plan (2026-11-04), part built.
Steps 1 and 2 of the order and the first two typing steps are built; the rest is tracked in #49 (types) and #51 (first seen and candidates).

Two goals, in order:

1. **Full transaction coverage:** every block from genesis to the tip completed, merkle-verified.
2. **Strong typing:** every output and transaction typed, in batches, so new kinds of transaction are found and named as soon as they recur.

Together they support a claim nobody else can make cheaply: when each type of transaction first appeared on chain, and how its use grew.

---

## Why ascending sync matters here

The sync loop fills blocks upward from genesis (`docs/SYNCING.md`).
Once `complete_through` passes a height, no earlier instance of anything can turn up later.
So "first seen" is exact, not a best guess: *first seen at block H, verified complete through H*.
That is the research angle, and it falls out of a choice we already made.

---

## Operating it from an LLM session

Tonight's lesson: every prod question went through another session running `bin/bitblocks rpc` and pasting output back.
An operator session needs to see for itself.

**Built (step 1):**

- `GET /api/v1/status` names the running release (`release.sha`, from the image tag via `RELEASE_SHA`) and node, so a deploy can be confirmed from outside.
- `GET /api/v1/status/coverage` gives completeness per 10,000-block bucket, blocks completed in the last hour, and an ETA to the tip. Computed at most once a minute and shared.

**Built (step 2, #50): operator tools, read-only, behind an `ops_read` key, as API and MCP over `Bitblocks.Ops`. See [OPS_API_AND_MCP.md](OPS_API_AND_MCP.md#the-operator-api).**

| Tool | Answers |
|---|---|
| `sync_live` | Leader node, worker slots, each block's stage and retries, last errors with reasons |
| `block(h)` | One block's story: header, `num_tx`, stored count, last fetch (source, bytes, ms), errors, reorgs |
| `node` | Node height and headers, RPC and REST latency, our request rate |
| `errors` | Recent error log lines, with secrets and addresses removed |

Write tools come after, behind `ops_write`, dry-run by default and recorded as commands: `set_concurrency`, `requeue_block`, `reconcile_orphan`, `import_blocks`, `build_tiles`.

---

## The typing pipeline

1. **Stable template hashes first. Built.** `Script.template_hash/1` names each opcode byte once (`Script.opcode_name/1`: `OP_FALSE`, `OP_1`, `OP_NOP2`, `OP_NOP3`), so a shape gets one hash whichever alias the decoder picked (#49).
   Re-stamping the rows hashed under the other names is script analysis v7 and its backfill, recorded in `derivation_runs` (`docs/DERIVED_DATA.md`).
2. **Classify at ingest. Built.** The chunk step `classify_outputs` gives every output a type from `types.json` and every transaction the set of them (`transactions.tx_types`); anything unmatched is `custom`.
   The block step `type_counts` tallies them per block when the block completes, and `/types` sums the blocks verified complete (`Bitblocks.TxTypes.Counts`).
   The rules are in `docs/TX_PIPELINE.md`, "Transaction types".
   Still to come: named compositions (inscription + OrdLock = listing), and keying `custom` outputs by their template hash for the candidate queue.
3. **First seen and adoption.** Per type and per unmatched shape: first height, txid and block time, and counts per 10,000-block bucket.
   Cheap to keep, because blocks complete in order.
4. **Candidate types.** The signal is an unmatched shape that starts recurring.
   A `type_candidates` tool lists them by count and growth, each with decoded sample scripts, first seen, the protocols it appears with, and example txids.
5. **Review in batches.** A session reviews the top candidates and drafts definitions with test vectors (`propose_type`); Ryan approves; the type gets a slug and a page, past rows are re-stamped, and new blocks are typed from then on.
   The definition history records when each type was named, beside when it first appeared on chain.

Built so far (#51): `Bitblocks.TxTypes.Counts` carries each type's first height, date and txid and its txs per 10,000 blocks, on `/types/:id` and `/api/v1/types`, always over the range verified complete and typed.
`Release.type_candidates(from, to)` (`Bitblocks.TxTypes.Candidates`) ranks the shapes behind `custom` for an operator, from raw bytes, storing nothing.
Still to come: `propose_type` and the approval flow, and the research export.

### A taxonomy, not a list

Three axes, each versioned with stable slugs:

- **Lock pattern:** the script template (P2PKH, OrdLock, multisig, …).
- **Data protocol:** B, MAP, BSV-20, …
- **Composition:** combinations at the transaction level.

That structure lets the taxonomy grow without renaming what came before.

---

## The research output

*Bitcoin transaction types: a verified taxonomy, with first-seen heights and adoption curves from genesis.*

A reproducible dataset (types by height bucket), exported with the data-pack exporter, every count traceable to merkle-verified blocks.
Every count also names the version that computed it, and the backfill runs that brought the rows to it (`docs/DERIVED_DATA.md`).

---

## Order

1. Release sha and coverage in the status API. **Done.**
2. Operator MCP, read tools.
3. #49 phase 2: stable template hashes, classify at ingest, counts on `/types`. **Done.**
4. First seen, adoption, and the candidate queue with review tools.
5. The research export.
