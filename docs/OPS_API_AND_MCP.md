# Ops API and MCP — proposal

Status: proposal (2026-11-03).
Nothing here is built unless it names an existing module, route or function.

Short answer: yes, Bitblocks would benefit from both, built in a set order.
First, one operations context in Elixir that returns data instead of printing it.
Then a public status endpoint, an operator API and an MCP server, all on top of that one context.
Each audience (operators, developers, support, sales) gets a different slice of the same facts.

---

## Why now

Our own BSV node was down from about 2026-07-10 until 2026-11-03.
Nobody was told.
The tip sat at 957,301 while the public chain moved to about 973,960, and we found out from a side note in an unrelated infra handoff.
Everything we needed to see it was already in the database: `max(height)`, the newest block's `inserted_at`, and failed fetches.

How we operate today:
- Each change goes through `bin/bitblocks rpc 'Bitblocks.Release.…'`, which is run inside AWS by the infra session, with Ryan's approval.
- Results come back as printed text inside a handoff file.
- Oban prunes completed jobs after 60 seconds, so cron history is gone before anyone looks.
- The only alert we send is the reorg email (`Bitblocks.Notifications.reorg_alert/3`).

That works for rare, deliberate changes.
It doesn't work for questions we should be able to answer at any moment: is it healthy, how current is it, what's missing, who is using it.

---

## Principle: one context, many faces

This follows the CLI-first rule: the context API comes first, and every surface sits on top of it.

```
Bitblocks.Ops (structured data, tested)
├── bin/bitblocks rpc            operators, today's path, unchanged
├── /api/v1/status               public: anyone, no key
├── /api/v1/ops/*                operator API: admin-scoped key
├── MCP server (operator)        Claude sessions, infra agent, Ryan
├── MCP server (chain data)     developers building on Bitblocks
└── alerts (SES email)           push, so nobody has to ask
```

`Bitblocks.Release` already holds the operations: `status`, `sync_status`, `gaps`, `audit_completeness`, `tx_store_check`, `chain_tiles_status`, `collection_sync_status`, `retry_failed_blocks`, `create_api_key` and more.
Most of them print text.
The first step is to move what they compute into `Bitblocks.Ops` and return maps; `Release` keeps printing, by formatting those maps.
Then every surface tells the same story, and tests cover the facts once.

Every write operation is recorded as a command (who, what, arguments, result), in line with the command-first rule.
That record is also the audit log.

---

## Audience 1: operators

Today that's Ryan and the infra session.
Tomorrow, any Claude session that touches Bitblocks.

**Read tools** (safe; ship first):

| Tool | Answers |
|---|---|
| `health` | Is the node reachable, and its height against the public tip and ours? |
| `coverage` | Header gaps, blocks by `sync_state`, blocks where stored txs < `num_tx`, completeness above 600k (#1) |
| `sources` | Which source is active (our node, PublicNode, WhatsOnChain), recent rate-limit hits, fallback use |
| `queues` | Oban lanes: running, scheduled, retryable, discarded, with a few hours of history |
| `failed_blocks` | Blocks that hit the retry limit, with their last error |
| `projection_status` | Per-tenant lag and readiness (already at `/api/v1/projections/:id/status`) |
| `collections` | Trace state counts per collection (`current`, `unknown`, `ended`) |
| `chain_tiles` | Last build, tip height, stale tiles |

**Write tools** (gated; ship second):

| Tool | Wraps |
|---|---|
| `retry_failed_blocks` | `Release.retry_failed_blocks/0` |
| `sync_headers(from, to)` | `Release.sync_headers/2` |
| `backfill(min_height)` | backfill with a floor |
| `build_chain_tiles(mode)` | `Release.build_chain_tiles/0` |
| `sync_collection(id)` | `Release.sync_ordinal_collection/1` |

Rules for write tools:
- A dry run is the default: the tool says what it would enqueue, and a second call with `confirm: true` does it.
- Writes are rate-limited, and anything that touches more than a set number of blocks needs Ryan's approval.
- Every write is recorded as a command.
- No raw RPC passthrough and no SQL.
  The node's credentials and the database stay behind named operations.

What this changes: today's incident becomes one `health` call, or one alert email.
An infra handoff shrinks from "run these five commands and paste the output" to "call `coverage` and act on it".

---

## Audience 2: developers (devux)

Developers want to build on chain data without running a node, and the API already covers much of that.
An MCP server over the **public** API lets them work with it from their editor or agent:

- `get_tx`, `get_block`, `merkle_proof`: wrap existing `/api/v1` routes.
- `decode_script`, `match_template`: wrap `/api/v1/script/*`.
- `outpoint_kind`: "is this an ordinal or a token?", from `/api/v1/outpoints/:txid/:vout`.
- `collection_item`: membership and ownership, from `/api/v1/collections/*`.
- `token`, `token_holders`, `address_tokens`: wrap `/api/v1/tokens/*` and `/api/v1/addresses/:address/tokens`.
- `projection_hydrate`, `projection_status`: for managed-service tenants (`MANAGED_SERVICES.md`).
- `tx_type` (next): uses the planned `/types` resource, once every tx is typed.

This server is a separate thing from the operator server, with a separate key scope.
It only reads, uses the caller's own API key and budget, and is safe to publish.

Developers also need a public, honest answer to "how current is this data?".
`/api/v1/status` should report the tip height, `indexed_through_height`, lag in blocks, completeness above 600k, and the time of the last block insert.
That one endpoint would have shown the node outage to anyone who looked.

---

## Audience 3: customer support

Support questions we can already expect:
- "Why do I get 429s?"
- "Why is my projection behind?"
- "Why does this item say `unknown`?"
- "Is this tx missing, or just not indexed yet?"

Support tools (operator scope, read-only):

| Tool | Answers |
|---|---|
| `key_usage(prefix)` | Requests, 429s and errors per key over time (needs per-key counters, which don't exist yet) |
| `explain_tx(txid)` | Indexed or not, in which block, that block's sync state, and why if it's missing |
| `explain_item(collection, outpoint)` | Trace state, last checked, last error (WhatsOnChain 500, ended, open doubt) |
| `projection_status(id)` | Lag, backfill progress, the snapshot cursor |

Each answer should be short enough to paste into a reply, with a link to the matching public page.
Answers should say what is known, what isn't, and when it will be.

---

## Audience 4: sales

Bitblocks sells freshness, completeness and proof, not storage.
The same facts back a sales conversation:

- **Coverage as a claim:** "Every block from genesis to tip, every tx above 600k, each txid list checked against its merkleroot."
  `coverage` and the audit make that a number, not a promise.
- **A status page with history:** uptime and lag over 90 days is what a prospect checks before signing.
  That needs the history we currently prune away.
- **Usage per tenant:** `key_usage` rolled up per month is the basis for pricing and for knowing when to upgrade someone.
- **Prospect demos:** with the developer MCP server, a prospect's own agent can query their data in minutes.
- **Managed services:** a projection's status and lag become the SLA terms (`MANAGED_SERVICES.md`).

---

## Alerts (the piece that would have caught this)

Asking is not enough; Bitblocks should say when something is wrong.
These go through the existing mailer (`Bitblocks.Notifications`, SES):

- Tip lag over N blocks for M minutes (for example, 6 blocks for 60 minutes).
- Node unreachable for M minutes.
- New blocks reaching `failed`.
- A source falling back from our node to a public one.
- A projection's lag over its limit.

Each alert names the `Ops` call that explains it.

---

## Order of work

Each step is a user story with a test, in dependency order.

1. **`Bitblocks.Ops` read functions**, returning maps, with `Release` formatting them.
   Test: given seeded blocks with a gap and a lagging tip, `Ops.coverage/0` and `Ops.health/0` report them.
2. **Lag and outage alerts** on a cron.
   Test: a stale tip sends one email, and a repeat inside the quiet period doesn't send another.
3. **`/api/v1/status`** (public).
   Test: it returns the tip, lag and last insert time, and never any credentials or internal hosts.
4. **Keep job and metric history** longer than 60 seconds: raise the Oban Pruner's `max_age`, plus a small daily rollup table for lag and coverage.
   Test: yesterday's lag can be queried.
5. **Key scopes** on `api_keys` (`public`, `ops_read`, `ops_write`) and per-key usage counters.
   Test: a `public` key gets a 403 on `/api/v1/ops/*`.
6. **Operator API and operator MCP server, read tools.**
   Test: each MCP tool returns the same map as its `Ops` function.
7. **Write tools** with dry-run, confirmation and command records.
   Test: a call without `confirm` enqueues nothing; a call with it records exactly one command.
8. **Developer MCP server** over the public API.
   Test: the tools work with a `public` key, within its rate limit.

Steps 1 to 3 are small, and they would have caught the four-month node outage.
Start there.

---

## Open questions for Ryan

- Should the operator MCP server run inside the Phoenix app (Streamable HTTP behind an `ops_*` key), or as a local process that calls `/api/v1/ops/*`?
  Inside the app is simpler; a local process keeps the MCP surface off the internet.
- Who gets alerts besides you, and should they go anywhere but email?
- Is a public status page with history something you want to show prospects now, or after #1's coverage is complete?
