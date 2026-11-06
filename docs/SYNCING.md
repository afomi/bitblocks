# Syncing

How Bitblocks syncs the chain.
This is the authoritative description; where it and the code disagree, the code wins and this file gets fixed.

Related: `docs/LARGE_BLOCKS.md` (mega-block handling), `docs/NODE_OPERATIONS.md` (the node, including `rest=1`).

## The promise

Bitblocks is accurate as of the last-known block, and it says which block that is.
`Bitblocks.Sync.complete_through/0` is the highest height H such that every block from genesis through H is `completed`.
`completed` means the block's txid list rebuilt the header's merkleroot and every one of its transactions is stored.
A missing header counts as incomplete.
/syncing, /sync, /status and `Release.sync_status()` all say "Complete through block X of N known", where N is our highest stored header.

`complete_through` is computed, never stored.
The lowest incomplete block comes from one lateral probe per state on `blocks_sync_state_height_index`.
A header gap below it is found by an index-only count of heights, and only searched for when the count is short.

## The loop

1. **Headers stay current.**
   The coordinator runs header sync every minute: new headers up to the node's tip, a reorg resolved when one is found (fork point, orphans deleted, `ReconcileOrphanWorker` queued), the node's best hash compared with ours when it isn't ahead, and the lowest header gap below our tip filled, 10,000 headers a run.
   The node's new blocks arrive as `header_only` rows, which are incomplete.
2. **Work goes upward from `complete_through + 1`.**
   The coordinator gives each free worker slot the lowest incomplete block that has no live job.
   Nothing is skipped and nothing is worked out of order: a block that keeps failing keeps its slot and stays first in line.
   With more than one slot, higher blocks can finish first; `complete_through` only moves when the lowest incomplete block completes.
3. **One owner per block, sequential within it.**
   Each block belongs to one `FetchTransactionsWorker` job on the `:sync_blocks` queue, unique on the block hash across queued, running and backing-off states, so two processes never hold the same block.
   The job walks the block's transactions in chunks of 100, in order, one request in flight.
   **Small blocks go in runs.**
   When the next blocks for a slot each have at most `:sync_run_small_txs` (1,000) txs, one job takes up to `:sync_run_max_blocks` (50) of them, at most `:sync_run_max_txs` (20,000) txs in all, and walks them in height order within one bounded run.
   Dispatch holds every block of a run, so none goes to another slot; `/syncing` and `/blocks` show the run at the block it is on now.
   A larger block, or one with no known tx count, is a job of its own.
   Why: a small block's own work takes about 8 ms, but the hand-off between jobs (completion broadcast, the coordinator's next tick, dispatch, Oban pick-up) took about a second locally and about 9 s per slot on prod.
   Over the same 200 one-tx blocks from local `.bin` files, one slot went from 201 s to 5.3 s.
   On prod, the first limit (100 txs) roughly tripled the rate, 13.3 to 38.4 blocks/min near height 157,000, where 1 block in 10 has more than 100 txs and ended a run; the limit is now 1,000.
4. **One request per block.**
   A block up to 32 MB is fetched once as raw bytes (`Chain.RawBlock`): the node's REST interface first (`/rest/block/<hash>.bin`, needs `rest=1`), `getblock(hash, 0)` when REST answers anything but 200.
   The txs are split out locally; each txid is the double SHA-256 of its own bytes, and the ordered txids must rebuild the header's merkleroot.
   No `getrawtransaction` is sent for these blocks.
   SV's `getblockheader` reports no size, so until a raw fetch records `size` the gate is `num_tx` at most 20,000; REST refuses a body over the cap either way.
   Larger blocks, and blocks the node can't serve whole (pruned, unreachable), use the txid list (`TxidSource`, merkleroot-checked) and fetch bodies per chunk (`TxSources`).
   Streaming a GB block through a bounded parser is the follow-up.
5. **Bounded runs.**
   A run stops after `:tx_fetch_run_ms` (30 s, inside Oban's 60 s shutdown grace), saves the chunk it reached in the job's meta, and snoozes; the same job resumes there.
   A raw block is downloaded again on each resumed run, which only happens to blocks that take longer than a run to store.
6. **Checked before it counts.**
   After the last chunk, a count by txid confirms every transaction is stored; only then is the block `completed`.
   That change is broadcast; a run goes on to its next block, and when the job ends the coordinator hands the slot on.
   A raw-path block's exact bytes then go to the tx store as one object, `blocks/<height>-<hash>.bin`, read back and verified, with each tx's offset on its row (`TxStore.BlockObject`; docs/TX_STORAGE.md).
   That write never decides or delays completion: a failure is logged, the block's `raw_object_stored_at` stays nil, and `Release.store_block_objects/3` writes it later.
7. **Retries replace give-ups.**
   Any failure (node unreachable, rate limit, a tx no source returns, a merkle mismatch) marks the block `failed` and snoozes the job: 1, 2, 4, 8, 16, 32 minutes, then hourly.
   `tx_sync_attempts` counts failures in a row and resets on progress.
   The seventh in a row comes more than an hour into the stall and sends one email (`Notifications.sync_stall_alert/3`); later failures don't repeat it.
   `failed` is a display state: nothing excludes a block from the loop because of it.

## Who leads

`Bitblocks.Sync.Coordinator` runs on every node and acts only while its node is Oban's leader (`Oban.Peer.leader?/0`, checked every second).
It owns the cursor, dispatch, the concurrency setting, and the state broadcast.
When leadership moves, the old leader stands down at its next tick and the new one takes over at its own; dispatch only inserts jobs that are unique per block, so a moment of overlap can't assign a block twice.
`Bitblocks.Workers.SyncWorker`, on the per-minute cron, only makes sure the coordinator is running.

Workers are Oban jobs rather than tasks under the coordinator: a deploy or crash leaves them in the database, and they resume from their saved offset on whichever node picks them up.

## Concurrency

Worker slots are set by an admin on /syncing, persisted in the one-row `sync_settings` table, and applied by the coordinator within seconds.
Growing adds slots; shrinking lets blocks in progress finish and doesn't refill their slots.
The setting is clamped to `Sync.concurrency_limit/0`, the smallest of:

- CPU cores (`System.schedulers_online/0`);
- the Repo `pool_size` minus `:sync_pool_reserve` (5, kept for web requests, header sync and the other queues);
- the node's RPC threads, `:sync_rpc_limit` (env `SYNC_RPC_LIMIT`, default 4, bitcoind's default `rpcthreads`).

/syncing names the binding limit, e.g. "Max 2 — CPU cores".
Without a saved choice the default is `:sync_workers`: 1 in dev and test, 2 in prod (a t3.medium has 2 vCPUs; POOL_SIZE 10 leaves 5; the RPC limit is 4).
The coordinator scales the `:sync_blocks` queue on every node to the setting; dispatch is what bounds the cluster to it.

## Pausing

An admin can pause the loop on /syncing ("Pause the sync"), and resume it there.
The flag is the `paused` column of the same `sync_settings` row (`Sync.set_paused/1`, `Sync.paused?/0`), so it holds across restarts, deploys and a change of leader.
While paused the coordinator dispatches no new block jobs; header sync keeps running, and blocks already dispatched finish, including the rest of a small-block run.
/syncing says "Paused" and how many block jobs are still finishing; `/api/v1/status` reports `sync_paused` instead of `index_stalled`.
The per-minute cron only keeps the coordinator alive, so it never undoes a pause.

Lowering the concurrency drains the same way: dispatch fills only free slots, so live blocks finish and nothing new starts until the count is below the new setting.

## Watching it

/syncing is the one sync page, for signed-in readers; /sync redirects to it, and admins also get the operator panel there.
It shows "Complete through block X of N known", the slots in use and the limit, and a table of blocks in height order: the `complete_through` block, the blocks with live jobs, and the next five waiting.
Each row shows its stages as text and icon: header stored and checked, tx count known, txs fetched x of y, verified; plus its worker slot and retry state.
/syncing also shows, for admins, the load on our node: raw blocks fetched over the last ten minutes, blocks a minute and MB a second, and the latest fetch's size, time and source.

It costs the same for one viewer or a thousand.
The coordinator broadcasts `Sync.overview/0` at most once a second; block jobs report progress per chunk (`SyncProgress.Tracker`) and each raw fetch's bytes and time.
`Bitblocks.SyncProgress`, one per node, merges these into one snapshot in ETS that every viewer reads; the LiveViews never query.
It also reloads the overview itself every 30 s, so a node that doesn't hear the coordinator still shows current numbers.

## Operating it

There is nothing to start, retry or repair by hand after an outage: the loop reaches every incomplete block in order.

```bash
bin/bitblocks rpc 'Bitblocks.Release.sync_status()'              # complete through, last known block, target, jobs
bin/bitblocks rpc 'Bitblocks.Release.audit_completeness()'       # stored rows vs num_tx, any state
bin/bitblocks rpc 'Bitblocks.Release.repair_incomplete_blocks()' # reopen completed blocks the audit flags
bin/bitblocks rpc 'Bitblocks.Release.sync_headers(0, 100_000)'   # headers for a range, by hand
```

The audit counts by `block_hash`, so it is a lower bound: a txid stored under another block (reorg, BIP30 duplicate coinbase) can flag a block the worker completes without fetching anything.
Repair is idempotent.

## Sources: where headers, txid lists and bodies come from

Our own node (`BITCOIN_NODE_URL`) is the primary source.
It was down from 2026-07 to 2026-11, so public sources can stand in for it, and each one is checked rather than trusted.

| Data | First source | Fallback | Check |
|---|---|---|---|
| Headers and chain tip | the RPC endpoint: `BITCOIN_NODE_RPC_URL`, else `BITCOIN_NODE_URL` | none | `HeaderVerifier` (hash, PoW) and prevhash continuity |
| Whole block (up to 32 MB) | REST `/rest/block/<hash>.bin`, else `getblock(hash, 0)` | the txid-list path below | header bytes hash to the block hash; txids derived from the bytes rebuild the merkleroot; tx count equals `num_tx` |
| Txid list (larger blocks) | `getblock(hash, 1)` on the RPC endpoint | WhatsOnChain `/block/hash/:hash` plus its 50,000-txid pages | rebuilt merkleroot must equal the stored header's; a fallback list with no merkleroot to check is refused |
| Tx bodies | `getrawtransaction` batches on the RPC endpoint | WhatsOnChain bulk `/txs` and `/txs/hex`, 20 per call | each body must hash to its txid (`TxIngest`) |

- **PublicNode** (`https://bsv-rpc.publicnode.com`) is free, needs no auth, and is pruned to about the last 300 blocks.
  Point `BITCOIN_NODE_RPC_URL` at it and leave `BITCOIN_NODE_RPC_USERNAME`/`PASSWORD` unset or empty; blank credentials send no `Authorization` header.
  Every request carries a JSON-RPC `id`, which PublicNode requires.
- **Pruned blocks** answer `getblock` with code -1 "Block file … not available." and `getrawtransaction` with -5.
  `BitcoinsvCli.not_available?/1` names these, and `Chain.TxSources` skips the node entirely for blocks below its reported `pruneheight`.
  They are routed to the fallback, never counted as block failures.
- **Rate limits** (HTTP 429, PublicNode's JSON-RPC -32005, WoC 429) are backoff signals.
  `BitcoinsvCli` retries a 429 with exponential backoff (5 tries from 2 s).
  If a source is still limited, the block job fails the run and backs off like any other failure.
- **WhatsOnChain** free tier is about 3 requests a second with no key.
  Set `WOC_API_KEY` (sent as the `Authorization` header) and `WOC_RPS` (default 10 with a key) for a paid plan of 10, 20 or 40 requests a second.
  `config :bitblocks, :woc_fallback, false` turns the fallback off.
- **Header pacing**: `HEADER_BATCH_SIZE` (default 500) and `HEADER_BATCH_PAUSE_MS` (default 0).
  Each batch is one `batch_getblockhash` and one `batch_getblockheader`.
  For PublicNode, start at a batch of 100 and a 500 ms pause, close to the pace the dev header load settled at.
- **Catching up after an outage**: header sync walks the gap in header batches, and the loop reaches each new block in height order.

---

## After a reorg: the orphan's transaction rows (#34)

Tip sync deletes an orphaned block's row, but its transactions keep the orphan's `block_hash`.
Two things move them:

- The tx-fetch diff (`Chain.TxIngest.existing_txids/2`) moves a stored transaction to the block being fetched when its row sits under a hash that is no longer a stored block. So a transaction mined in both blocks reports the new block's hash and height once that block's transactions are fetched.
- `ReconcileOrphanWorker`, enqueued for each deleted orphan ten minutes after the reorg, settles every remaining row: moved to the block a source names (if we store it), or removed with its spend edges when no block holds it. It marks the reorg row reconciled once no row points at the orphan, and the reorg's summary sentence follows.

Removal is a delete: no row is marked unconfirmed.
A removed transaction that is mined later is fetched again with its block.

Until a row is settled, nothing describes it as confirmed:

- `GET /api/v1/txs` and `GET /api/v1/txs/:txid` carry `confirmed` and `confirmation` (`Chain.confirmations/1`): `confirmed` while the tx's `block_hash` is the block stored at its height and that block's txid list has been checked, `unverified` for a `header_only` block, `orphaned` when no stored block has that hash at that height.
- Merkle proofs answer 409 for such a row, address and script balances count it as `unknown` (`Chain.Utxos`), and projection hydrate leaves it out.
- `Chain.record_spends/1` replaces a spend whose spender isn't in a stored block, so the real chain's spender of an outpoint takes the row as soon as its block is fetched.

Tip sync also finds the reorgs no new block reveals.
When the node isn't ahead of us, its best block hash is compared with the block we store at its height; a difference is checked against the node's live answer, then resolved.
A node on our chain but behind us is not a reorg, and a node on a shorter branch rewinds us only when its chainwork is at least ours.

The stream sends `reorg` (`fork_point`, `fork_height`, `orphans`) on `GET /api/v1/stream/blocks`, and webhook projections get their `reorg` event.

A fork deeper than 10 blocks stops tip sync at that height: the reorg row stays `needs_attention`, `Reorgs.halted/0` names it, `/syncing` and `/status` say so, `GET /api/v1/status` lists `reorg_halted`, and one email goes out for the fork, however many tip runs meet it.

Token, listing, collection and Bitcom rows from orphan-only transactions are not rewound.
Most protocol state on the chain is bespoke, so each protocol's rewind is its own piece of work, not one pass over every derived table (Ryan, 2026-10-31).

For a reorg from before this shipped, run the same reconcile by hand, dry run first:

```bash
bin/bitblocks rpc 'Bitblocks.Release.reconcile_orphaned_block("<orphan hash>")'
bin/bitblocks rpc 'Bitblocks.Release.reconcile_orphaned_block("<orphan hash>", apply: true)'
```

Add `orphan_count: n` to correct the reorg row's count of blocks set aside.

---
