# Full coverage, strong typing, and first seen

Status: plan (2026-11-04).
Step 1 is built; the rest is tracked in #49 (types), #50 (operator MCP) and #51 (first seen and candidates).

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

**Next (operator tools, read-only, behind an `ops_read` key, as API and MCP over `Bitblocks.Ops`):**

| Tool | Answers |
|---|---|
| `sync_live` | Leader node, worker slots, each block's stage and retries, last errors with reasons |
| `block(h)` | One block's story: header, `num_tx`, stored count, last fetch (source, bytes, ms), errors, reorgs |
| `node` | Node height and headers, RPC and REST latency, our request rate |
| `errors` | Recent error log lines, with secrets and addresses removed |

Write tools come after, behind `ops_write`, dry-run by default and recorded as commands: `set_concurrency`, `requeue_block`, `reconcile_orphan`, `import_blocks`, `build_tiles`.

---

## The typing pipeline

1. **Stable template hashes first.** `Script.template_hash/1` names some opcodes (bytes 81, 177, 178) by map order, so one shape can get two hashes (#49).
   Canonical names, then re-stamp the affected rows; otherwise "first seen" splits in two.
2. **Classify at completion.** When a block becomes `completed`, every output gets a type and every transaction a composite type (for example inscription + OrdLock = listing).
   Anything unmatched is `custom`, keyed by its normalized template hash.
3. **First seen and adoption.** Per type and per unmatched shape: first height, txid and block time, and counts per 10,000-block bucket.
   Cheap to keep, because blocks complete in order.
4. **Candidate types.** The signal is an unmatched shape that starts recurring.
   A `type_candidates` tool lists them by count and growth, each with decoded sample scripts, first seen, the protocols it appears with, and example txids.
5. **Review in batches.** A session reviews the top candidates and drafts definitions with test vectors (`propose_type`); Ryan approves; the type gets a slug and a page, past rows are re-stamped, and new blocks are typed from then on.
   The definition history records when each type was named, beside when it first appeared on chain.

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

---

## Order

1. Release sha and coverage in the status API. **Done.**
2. Operator MCP, read tools.
3. #49 phase 2: stable template hashes, classify at completion.
4. First seen, adoption, and the candidate queue with review tools.
5. The research export.
