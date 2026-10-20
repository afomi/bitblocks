# External BSV APIs — WhatsOnChain & GorillaPool

Reference for the two most-used public BSV data/broadcast APIs, captured to guide Bitblocks' own API toward shapes developers already know.

Goal: a developer should be able to build on Bitblocks **directly via API calls**, reusing patterns they learned from WhatsOnChain (WoC) or GorillaPool wherever that is sensible.

Full alignment is not achievable unilaterally (these are independent services with their own conventions), so this doc separates *de-facto standards worth matching* from *their idiosyncrasies we should not inherit*.

All endpoints below were probed live on 2026-06-23; HTTP status and response keys are from real responses, not docs.

---

## 1. WhatsOnChain (WoC)

Base URL: `https://api.whatsonchain.com/v1/bsv/{network}` where `{network}` is `main`, `test`, or `stn`.

Public, rate-limited, no auth for read endpoints.
This is the most widely integrated BSV explorer API; its path scheme is the closest thing to a community standard.

### Chain / health

| Method | Path | Returns |
|---|---|---|
| GET | `/woc` | Liveness string. |
| GET | `/chain/info` | `chain, blocks, headers, bestblockhash, difficulty, mediantime, chainwork, pruned`. |
| GET | `/chain/tips` | Chain tips (height, hash, branchlen, status). |
| GET | `/exchangerate` | BSV spot price (USD). |

### Block

| Method | Path | Returns |
|---|---|---|
| GET | `/block/hash/{hash}` | Full block header + metadata + `tx` (txid array). |
| GET | `/block/height/{height}` | Same, addressed by height. |
| GET | `/block/headers` | Last ~10 block headers. |
| GET | `/block/{hash}/page/{page}` | Paginated txid list for very large blocks. |

### Transaction

| Method | Path | Returns |
|---|---|---|
| GET | `/tx/hash/{txid}` | Decoded tx: `txid, hash, version, size, locktime, vin, vout, blockhash, confirmations, time, blocktime, blockheight`. |
| GET | `/tx/{txid}/hex` | Raw tx hex (string). |
| GET | `/tx/{txid}/proof/tsc` | TSC-format merkle proof. |
| POST | `/tx/raw` | Broadcast a raw tx (`{"txhex": "..."}`); returns txid. |
| POST | `/txs` | Bulk fetch decoded txs by txid array. |

Note the inconsistency in WoC's own scheme: the single-tx lookup is `/tx/hash/{txid}` but the sub-resources are `/tx/{txid}/hex` and `/tx/{txid}/proof/tsc` (no `hash/` segment).
We should pick **one** form and not replicate this split.

### Address

| Method | Path | Returns |
|---|---|---|
| GET | `/address/{address}/info` | Address validity/metadata. |
| GET | `/address/{address}/balance` | `{confirmed, unconfirmed}` satoshis. |
| GET | `/address/{address}/history` | Confirmed tx history (paginated). |
| GET | `/address/{address}/unspent` | UTXO array: `[{height, tx_pos, tx_hash, value}]`. |

### Script (script-hash addressed — sha256 of scriptPubKey, big-endian)

| Method | Path | Returns |
|---|---|---|
| GET | `/script/{scripthash}/unspent` | UTXOs locked by that script. |
| GET | `/script/{scripthash}/history` | Tx history for that script (may 404 if unindexed). |

### Mempool

| Method | Path | Returns |
|---|---|---|
| GET | `/mempool/info` | Mempool size/bytes. |
| GET | `/mempool/raw` | Mempool txid list. |

### Key WoC response conventions

- **No envelope** — endpoints return the bare object or array (`/chain/info` returns the object directly; `/unspent` returns a bare array).
- **Bitcoin-RPC field names** in tx responses: `vin`/`vout`, `scriptPubKey`, `blockhash`.
- UTXO shape: `tx_hash` / `tx_pos` / `value` / `height`.

---

## 2. GorillaPool

GorillaPool runs several independent services, each on its own host. There is no single unified API.

### 2a. JungleBus — bulk indexer / firehose

Base: `https://junglebus.gorillapool.io`

| Method | Path | Returns |
|---|---|---|
| GET | `/v1/transaction/get/{txid}` | Indexed tx: `id, transaction (raw), block_hash, block_height, block_time, block_index, addresses, inputs, outputs, input_types, output_types, contexts, sub_contexts, data, merkle_proof`. |
| GET | `/v1/block_header/get/{height|hash}` | Block header. |
| GET | `/v1/block_header/list/{fromHeight}` | Range of headers. |
| (sub) | crawler / subscription | Streaming firehose of indexed txs from a subscription ID (gRPC/websocket via their client lib). |

JungleBus's value is the **enriched** tx shape (resolved addresses, input/output types, protocol contexts) — closest in spirit to Bitblocks' own protocol/parse layer.

### 2b. mAPI — fee quote & broadcast (Merchant API / BRFC envelope)

Base: `https://mapi.gorillapool.io`

| Method | Path | Returns |
|---|---|---|
| GET | `/mapi/feeQuote` | Signed fee quote. |
| POST | `/mapi/tx` | Submit one tx. |
| GET | `/mapi/tx/{txid}` | Tx status (confirmed/unknown). |
| POST | `/mapi/txs` | Submit multiple txs. |

mAPI uses the **JSONEnvelope** pattern: the real data is a JSON string in `payload`, alongside `signature`, `publicKey`, `encoding`, `mimetype`.
`feeQuote`'s decoded payload: `apiVersion, timestamp, expiryTime, minerId, currentHighestBlockHash, currentHighestBlockHeight, minerReputation, fees`.
This is a miner-signed-receipt pattern — relevant only if Bitblocks wants to act as a broadcast endpoint with verifiable provenance.

### 2c. 1Sat Ordinals API

Base: `https://ordinals.gorillapool.io`

| Method | Path | Returns |
|---|---|---|
| GET | `/api/stats` | Index stats. |
| GET | `/api/txos/address/{address}/unspent` | 1Sat UTXOs (ordinals/tokens) for an address. |
| GET | `/api/inscriptions/{outpoint}` | Inscription detail by outpoint. |

(BSV-20 / ordinals territory — overlaps Bitblocks' order-book/protocol work, not core chain data.)

---

## 3. Bitblocks today (for comparison)

Base: `/api/v1` (see `docs/` and the router).

- **Enveloped**: list endpoints return `{data: [...], ...pagination}`, single returns `{data: {...}}`.
- **snake_case** custom fields: `block_hash, block_height, total_input_satoshis, total_output_satoshis, fee, input_count, output_count`.
- Has things the others don't: `/metanet/*`, `/order-book/*`, `/protocols/*`, `/utxo/{txid}/{vout}/owner`, SSE `/stream/blocks`.
- Missing common-denominator endpoints developers expect from WoC (see §4).

### Script (script-hash addressed — same Electrum/WoC scripthash convention as WoC §1)

| Method | Path | Returns |
|---|---|---|
| GET | `/api/v1/script/{scripthash}/history` | Tx history for that script. |
| GET | `/api/v1/script/{scripthash}/unspent` | UTXOs locked by that script. |
| POST | `/api/v1/script/decode` | Decode script hex into a descriptor (`type, fields, asm`, matched template). |
| GET | `/api/v1/script/templates` | Registered script templates. |
| POST | `/api/v1/script/templates` | Register a script template. |
| GET | `/api/v1/script/templates/{template_hash}` | Template detail. |
| GET | `/api/v1/script/templates/{template_hash}/history` | Txs matching a template. |

The `/script/{scripthash}/history|unspent` pair matches WoC's script endpoints in path shape (scripthash = sha256 of scriptPubKey, reversed hex), though responses are Bitblocks-shaped keyed objects (`{scripthash, history|unspent, source}`), not WoC's bare arrays.
The decode + template registry endpoints have no WoC/GorillaPool equivalent — script-first is a Bitblocks differentiator (see `docs/REUSABLE_SCRIPTS.md`).

The divergence to decide on: **WoC has no envelope and uses RPC field names; Bitblocks envelopes everything and uses snake_case.** A client written against WoC cannot drop-in against Bitblocks today.

---

## 4. What is worth implementing in Bitblocks

Ranked by "lets a developer build on Bitblocks the way they already build on WoC," against effort.

### Tier 1 — common-denominator read endpoints (high value, low effort, data already present)

These are the endpoints every BSV app expects and that we can serve from data we already index:

- `GET /api/v1/chain/info` — mirror WoC's `chain/info` keys exactly (`blocks, headers, bestblockhash, difficulty, chainwork, mediantime`). One-to-one mappable from our latest block + stats.
- `GET /api/v1/tx/{txid}/hex` — raw hex. We store `raw`; trivial.
- `GET /api/v1/address/{address}/unspent` — we have `/addresses/{address}/utxos`; **add a WoC-shaped alias** (`tx_hash/tx_pos/value/height`) so WoC clients work unchanged.
- `GET /api/v1/address/{address}/balance` — already have `/addresses/{address}/balance`; align the field names (`{confirmed, unconfirmed}`).

### Tier 2 — broadcast & proof (medium value, medium effort)

- `POST /api/v1/woc/tx/raw` — broadcast. Wraps `BitcoinsvCli.sendrawtransaction`; accepts `{"txhex": ...}`, returns `{"txid": ...}` on success or a 400 with the node's reason. **Implemented.**
- TSC merkle proof in WoC's `/proof/tsc` shape — **deferred.** We only have the node's `gettxoutproof` (a raw binary blob, served at `/api/v1/txs/{txid}/proof`), which is NOT TSC format. Rather than mislabel a non-TSC blob as TSC, the `/woc/tx/{txid}/proof/tsc` alias is left unimplemented until a real TSC encoder exists (build the merkle branch for the txid, encode `{index, txOrId, target, nodes}`).

### Implemented: the `/api/v1/woc/*` compatibility layer

Shipped (bare responses, WoC field names, served from local indexed data):

| Method | Path | Notes |
|---|---|---|
| GET | `/api/v1/woc/chain/info` | Mapped from latest block (`blocks, headers, bestblockhash, difficulty, mediantime, chainwork`). |
| GET | `/api/v1/woc/tx/{txid}/hex` | Raw hex as `text/plain`. |
| POST | `/api/v1/woc/tx/raw` | Broadcast `{"txhex"}` → `{"txid"}`. |
| GET | `/api/v1/woc/address/{address}/unspent` | Bare array `[{height, tx_pos, tx_hash, value}]`. |
| GET | `/api/v1/woc/address/{address}/balance` | `{confirmed, unconfirmed}` — `unconfirmed` always 0 (local data is confirmed-only). |

See `BitblocksWeb.Api.WocController`. Reads reflect sync state (local-only), same caveat as the native address endpoints.

### Tier 3 — JungleBus-style enriched tx (high value, but it's our differentiator, not a copy)

- Our `/txs/{txid}` already returns parsed protocols + spend depth. Lean into this (the JungleBus `contexts`/`output_types` model) rather than copying it — it's where Bitblocks is *ahead*.

### Explicitly NOT worth copying

- **mAPI JSONEnvelope signing** — unless we want to be a signed-receipt miner endpoint. Heavy, niche.
- **WoC's `/tx/hash/{txid}` vs `/tx/{txid}/hex` split** — inconsistent; we should use one stem (`/txs/{txid}` + `/txs/{txid}/hex`).
- **Dropping our `{data: ...}` envelope wholesale** — see §5.

---

## 5. The consistency tension (needs a decision, possibly with others)

The user's goal — consistent APIs so users implement Bitblocks directly — runs into one unavoidable fork:

**Envelope vs bare.**
WoC returns bare objects/arrays; Bitblocks envelopes in `{data: ...}`.
We cannot be byte-compatible with WoC *and* keep our envelope.
Options:
1. Keep the envelope everywhere (consistent *internally*, not drop-in for WoC clients).
2. Add WoC-shaped **alias routes** (bare, RPC field names) under e.g. `/api/v1/woc/*` — compatibility layer without abandoning our native shape. **Recommended**: gives drop-in compatibility where it matters (address/utxo/tx/hex) while keeping our richer enveloped API as the primary.
3. Drop the envelope to match WoC (breaks existing Bitblocks clients).

**Field naming.**
WoC uses RPC names (`vin/vout/scriptPubKey`); we use snake_case derived fields.
Achievable unilaterally only inside a compatibility layer (option 2).

Anything beyond a compatibility shim — a genuinely *shared* cross-explorer schema — requires coordination with the other operators and is out of scope for a single repo.
