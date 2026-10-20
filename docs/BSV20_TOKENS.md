# BSV-20 / BSV-21 Token Indexer

Bitblocks indexes fungible-token inscriptions (1Sat Ordinals) and exposes them as queryable tokens with supply and holder data.
This is the read side of the DEX: it makes the `token_id` the Open Order Book already carries resolve to a real token.

Composing, signing, and broadcasting mint or transfer transactions is **not** done here.
That is the wallet layer's job (qart), per the bitblocks-reads / qart-writes boundary.
This document describes only what bitblocks detects, indexes, and serves.

## Two standards

BSV-20/21 tokens are JSON inscriptions carried inside an ordinal envelope in an output's **locking script** (not an `OP_RETURN`):

```
OP_FALSE OP_IF "ord" OP_1 "application/bsv-20" OP_0 <json-body> OP_ENDIF <...P2PKH...>
```

The content type is always `application/bsv-20` and every JSON field value is a string.

### BSV-21 — fully indexed

BSV-21 (originally "BSV-20 v2", tickerless) identifies a token by `id = "<txid>_<vout>"` of its genesis output.
**This is exactly the `token_id` format the Open Order Book uses**, so a listing resolves end-to-end into an indexed token.

`deploy+mint` — the whole supply is minted in one output:

```json
{ "p": "bsv-20", "op": "deploy+mint", "amt": "21000000", "sym": "MEME", "dec": "8", "icon": "<origin>" }
```

| Field | Required | Meaning |
|-------|----------|---------|
| `amt` | Yes | Total supply (≤ 2^64−1) |
| `sym` | No | Token symbol (uniqueness not enforced) |
| `dec` | No | Decimal precision (default 0) |
| `icon` | No | Origin of another inscription, or a `B` protocol outpoint |

The token id is stamped by the indexer as `"<txid>_<vout>"` of the mint output.

`transfer` — moves an `id`-referenced balance:

```json
{ "p": "bsv-20", "op": "transfer", "id": "<txid>_<vout>", "amt": "500" }
```

### BSV-20 classic — detect-only in v1

Classic BSV-20 (ticker-based, first-is-first) `deploy` / `mint` / `transfer` ops are parsed and stored for visibility, flagged `standard: "bsv-20"`, and surfaced by ticker.
The cross-transaction supply aggregation (mint progress vs `max`, ticker de-duplication, the "first mint to exceed max gets the valid fraction" rule) is **deferred** — it is not reconciled in v1.

```json
{ "p": "bsv-20", "op": "deploy", "tick": "ordi", "max": "21000000", "lim": "1000" }
{ "p": "bsv-20", "op": "mint",   "tick": "ordi", "amt": "1000" }
```

## Pipeline

1. **Detect** — `TransactionParser.analyze/1` scans every output's locking script (via `Bsv20Parser.token_inscription?/1`) and tags the transaction `"BSV20"` when it carries an `application/bsv-20` inscription. This runs alongside the existing `OP_RETURN` protocol detection.
2. **Parse** — `Bitblocks.Bsv20Parser.parse/1` extracts the inscription body from the envelope, `Jason.decode`s it, and normalizes it to a token map (`standard`, `op`, `token_id | tick`, `amt`, `sym`, `dec`, …). Bodies over 4 KB are rejected without decoding.
3. **Index** — on ingest, `FetchTransactionsWorker.store_batch/1` calls `Chain.index_tokens/1` (a no-op unless the tx was tagged `"BSV20"`). For each token output it resolves the recipient address from the stored output JSON and routes it to `Bitblocks.Tokens.index/1`.
4. **Store** — tokens are `protocol_instances` under the seeded `BSV20` protocol. `parsed_data` holds the token fields; `state` holds `%{supply, minted, holders}` for a mint. Idempotent via the `[:txid, :vout]` unique constraint.

## Storage

Rows in `protocol_instances` (`protocol_id` → the `BSV20` protocol):

- `deploy+mint` — `parsed_data.token_id = "<txid>_<vout>"`, `state.supply` = minted amount.
- `transfer` — `parsed_data.token_id` = the referenced token, `parsed_data.recipient` = the crediting address.
- classic ops — stored raw with `standard: "bsv-20"`.

Partial JSON indexes on `parsed_data->>'token_id'` (per op) and `parsed_data->>'tick'` back the queries.

## Holder balances

Balances are **net**: `Tokens.token_holders/1` sums the `amt` of each address's *unspent* token outputs, most-held first.
An output is the mint output (credited to its recipient) or a transfer output; it is unspent when no `spend_index` row spends it.
Because the check is a join against `spend_index`, not a flag, it holds regardless of the order blocks are ingested in — but it is only as current as the sync.
`Tokens.unspent_outputs/2` is the primitive (the BRC-163 basket `bsv21` view); balances are its sum.
Classic BSV-20 supply aggregation (mint-progress vs `max`) is still deferred.

## API

```
GET /api/v1/tokens                  — indexed tokens (?standard=bsv-21|bsv-20 &sym= &cursor= &per_page=)
GET /api/v1/tokens/:id              — token by token_id ("<txid>_<vout>") or ticker
GET /api/v1/tokens/:id/holders      — net holder balances (unspent outputs only)
GET /api/v1/addresses/:address/tokens — unspent token outputs held by an address (?standard= &token_id=)
GET /api/v1/tokens/:id/transfers    — transfer history
GET /api/v1/tokens/stats            — aggregate counts
GET /api/v1/stream/tokens           — SSE stream of new tokens / transfers (?token_id= to filter)
```

`:id` is validated by `BsvParams.token_ref/1` (a `<txid>_<vout>` id or a bounded ticker) before it reaches a query or a PubSub topic.

## Web UI

Browse tokens at `/tokens`; a token detail page at `/tokens/:id` shows supply, decimals, and holders.
On `/order-book`, a listing's `token_id` links to its `/tokens/:id` page.

## The minter (out of scope here)

A token minter composes a `deploy+mint` inscription, signs it, and broadcasts it — a write operation.
That lives in qart.
qart consumes this indexer's `/api/v1/tokens/*` endpoints for live supply and mint state.
The inscription JSON shapes above are the contract between the two sides.
