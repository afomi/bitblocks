# Open Order Book Protocol

A permissionless marketplace protocol for BSV-20 Ordinal tokens on the Bitcoin SV blockchain.

## Overview

The Open Order Book protocol enables token holders to list BSV-20 Ordinal tokens for sale, buyers to discover listings, and trades to settle atomically — without a centralized intermediary.

Bitblocks indexes order book transactions and provides query APIs.
Client applications (e.g. Ourquity) compose and broadcast the BSV transactions.

## Protocol Identifier

**Flag:** `orderbook`

Follows the same pattern as Metanet (`meta`): the first OP_RETURN push data chunk is the protocol flag string.

## Versioning

The second push data chunk is the **protocol version** — a string integer, currently `"1"`.

```
OP_RETURN "orderbook" <version> <op> <fields...>
```

The version sits before the operation so it governs the entire protocol, not a single op.
Parsers branch on the version first, then on the operation.
Older listings always parse under the rules of the version they were written with, so a future `"2"` can add, remove, or reorder fields without breaking any `"1"` listing already on-chain.

A message missing the version chunk, or carrying an unknown version, is rejected (not silently parsed as v1) — this keeps the version a hard gate rather than a soft default.

## Operations (v1)

### `list` — Publish a Token Listing

Announces that a seller has tokens available for purchase, and carries the seller's **pre-signed offer** so any buyer can settle the trade from on-chain data alone — the seller need not be online.

```
OP_RETURN
  "orderbook"
  "1"                 # protocol version
  "list"
  <token_id>          # BSV-20 token ID (txid_vout format)
  <quantity>          # amount for sale (string integer)
  <price_satoshis>    # price per token in satoshis (string integer)
  <seller_address>    # payment destination address
  <token_utxo>        # outpoint holding the tokens (txid:vout)
  <seller_pubkey>     # compressed pubkey (hex) that controls token_utxo
  <seller_sig>        # seller's signature over the token input (hex DER + sighash byte)
  <sighash_flag>      # sighash type used (e.g. "0xc1" = SINGLE|ANYONECANPAY|FORKID)
  [<expires_at>]      # optional: ISO 8601 expiry timestamp
  [<min_quantity>]    # optional: minimum purchase quantity (advisory in v1; see Partial Fills)
```

**The pre-signed offer.**
At listing time the seller signs *their token input* with `SIGHASH_SINGLE | SIGHASH_ANYONECANPAY | FORKID` (`0xc1`), committing to **exactly one output**: a P2PKH payment of `quantity × price_satoshis` to `seller_address`.
`SINGLE` binds that one payment output; `ANYONECANPAY` lets a buyer add their own payment inputs.
Everything else in the eventual settlement tx (the buyer's token-transfer output, change, optional `fill` OP_RETURN) is left open for the buyer to append.
This is the same offer construction used by Bitcoin Ordinals marketplaces (Magic Eden's `msigner`, 1Sat `OrdinalLock`).

Because the signature, pubkey, and sighash flag are all on-chain, the offer is fully self-contained: a buyer reconstructs the seller's signed token input directly from the `list` transaction, with no off-chain coordination and no trust in the seller's continued availability.

### `cancel` — Cancel a Listing

Removes a listing from the active order book.

```
OP_RETURN
  "orderbook"
  "1"                 # protocol version
  "cancel"
  <listing_txid>      # txid of the original listing transaction
```

A `cancel` is only honoured from `seller_address` (the same address that owns the listing's `token_utxo`); see Settlement.
In practice a seller can also cancel implicitly by spending the `token_utxo` themselves — the spend index detects it.

### `fill` — Record a Purchase

Optional indexing aid broadcast by the buyer when completing a trade.

```
OP_RETURN
  "orderbook"
  "1"                 # protocol version
  "fill"
  <listing_txid>      # txid of the listing being filled
  <fill_quantity>     # quantity purchased (string integer)
  <buyer_address>     # buyer's address
```

The `fill` operation is optional because settlement is detected implicitly when the token UTXO referenced in the listing appears in the spend index.

## Field Definitions

| Field | Type | Description |
|-------|------|-------------|
| `token_id` | string | BSV-20 token identifier in `txid_vout` format |
| `quantity` | string integer | Number of tokens listed for sale |
| `price_satoshis` | string integer | Price per token in satoshis |
| `seller_address` | string | Bitcoin address where payment should be sent |
| `token_utxo` | string | Outpoint holding the tokens, format `txid:vout` |
| `seller_pubkey` | string (hex) | Compressed public key controlling `token_utxo` |
| `seller_sig` | string (hex) | Seller's pre-signed offer over the token input (DER signature + sighash byte) |
| `sighash_flag` | string | Sighash type of `seller_sig` (e.g. `0xc1` = SINGLE\|ANYONECANPAY\|FORKID) |
| `expires_at` | string (ISO 8601) | Optional expiration timestamp |
| `min_quantity` | string integer | Optional minimum purchase quantity (advisory in v1) |
| `listing_txid` | string | Transaction ID of the listing being cancelled or filled |
| `fill_quantity` | string integer | Number of tokens purchased in a fill |
| `buyer_address` | string | Address of the buyer |

## Partial Fills

**v1 settles full-quantity only.**
A listing is bought in its entirety or not at all.

This is a deliberate consequence of the pre-signed-offer design: the seller's `SIGHASH_SINGLE` signature commits to exactly **one** payment output (`quantity × price_satoshis` to `seller_address`).
A partial fill would require a second seller-bound output (the token remainder returned to the seller), which a single `SINGLE` signature cannot commit to without a covenant.
Rather than ship a contradiction, v1 keeps the offer and the fill one-to-one.

A seller who wants divisibility lists several smaller listings instead of one large one.
`min_quantity` is therefore **advisory** in v1 (carried for forward-compatibility, not enforced at settlement).
Partial-fill settlement is reserved for a future version (`"2"`), which the explicit version field leaves room for without disturbing v1 listings.

## Listing State Machine

```
active --> filled       (purchased — full quantity)
active --> cancelled    (via cancel operation, or seller re-spends token_utxo)
active --> expired      (expires_at passed)
```

`partially_filled` is reserved for v2 (see Partial Fills) and is not reachable in v1.

State is tracked in the `protocol_instances.state` JSON field:

```json
{
  "status": "active",
  "quantity_remaining": "100",
  "fills": []
}
```

After the (full) fill:

```json
{
  "status": "filled",
  "quantity_remaining": "0",
  "fills": [
    {"txid": "abc123...", "quantity": "100"}
  ]
}
```

## Settlement Flow

Settlement is an atomic BSV transaction constructed by the buyer from the seller's on-chain pre-signed offer — no seller round-trip:

1. **Input [0]:** Seller's token UTXO (the `token_utxo`), unlocked with the seller's `seller_sig` / `seller_pubkey` from the `list` op (signed `SINGLE|ANYONECANPAY|FORKID`).
2. **Input [1..]:** Buyer's payment UTXOs (fund the price + fee).
3. **Output [0]:** Payment to `seller_address` for `quantity × price_satoshis` — this is the single output the seller's signature commits to, so it must come first.
4. **Output [1]:** New token UTXO for the buyer (BSV-20 transfer inscription for the full `quantity`).
5. **Output (optional):** Change back to the buyer.
6. **Output (optional):** OP_RETURN with `orderbook 1 fill` data for explicit indexing.

Because the seller signed `SIGHASH_SINGLE`, output [0] (the payment) is bound to input [0] (the token UTXO) by index — keep the payment as output [0].
There is no token-remainder output in v1 (full fill only).

The settlement transaction spends the token UTXO, which Bitblocks detects via the spend index.
This marks the listing as filled without requiring a separate `fill` OP_RETURN.

Detection is automatic: `Chain.record_spends/1` records every spent outpoint on ingest, and `OrderBook.settle_spent_token_utxos/1` checks each spend against active listings' `token_utxo` field.
A match fully fills the listing (`status = "filled"`, `spent = true`, `spent_txid` = the settlement txid, `quantity_remaining = "0"`) and broadcasts a `listing_filled` event.
The check is idempotent — an already-spent listing is skipped, so a worker retry re-processing the same block does not double-fill.

## Storage

Listings are stored as rows in the `protocol_instances` table:

- `protocol_id` — FK to the OrderBook protocol record
- `txid` / `vout` — the listing transaction outpoint
- `parsed_data` — extracted OP_RETURN fields (op, token_id, quantity, price, etc.)
- `state` — status tracking (status, quantity_remaining, fills array)
- `spent` / `spent_txid` — set when listing is cancelled or fully filled

JSON indexes on `parsed_data->>'token_id'` and `parsed_data->>'seller_address'` enable efficient filtered queries.

## API

### REST Endpoints

```
GET /api/v1/order-book/listings
  ?token_id=<id>
  &seller=<address>
  &min_price=<sats>
  &max_price=<sats>
  &cursor=<id>
  &per_page=<n>

GET /api/v1/order-book/listings/:txid
GET /api/v1/order-book/tokens/:token_id
GET /api/v1/order-book/tokens/:token_id/market
GET /api/v1/order-book/tokens/:token_id/trades
  ?per_page=<n>
GET /api/v1/order-book/sellers/:address
GET /api/v1/order-book/stats
```

#### Market data

`GET /api/v1/order-book/tokens/:token_id/market` returns a market-data summary aggregated over confirmed fills.

A trade is a fill recorded against a listing (`state.fills`), priced at the listing's `price_satoshis`.
Volume is denominated in satoshis as `sum(fill_quantity * price_satoshis)`.

```json
{
  "token_id": "abc123def456_0",
  "data": {
    "last_price": "5000",
    "volume_24h": 620000,
    "num_trades_24h": 2,
    "high_24h": 5000,
    "low_24h": 3000,
    "total_volume": 620000,
    "num_trades": 2,
    "num_active_listings": 1,
    "floor_price": 8000
  }
}
```

The 24h window is measured against each fill record's timestamp — the listing instance's `updated_at`, which a fill mutates.
This is an approximation: a listing filled in multiple steps shares one `updated_at`, so its fills fall in or out of the window together.
Per-fill block times are not reconstructed because the `fills` records do not carry them.
`floor_price` is the lowest `price_satoshis` among active listings for the token (`null` if none).

`GET /api/v1/order-book/tokens/:token_id/trades` returns recent confirmed trades, most recent first, limited by `per_page` (default 50).

```json
{
  "token_id": "abc123def456_0",
  "count": 2,
  "data": [
    {
      "txid": "<fill_txid>",
      "listing_txid": "<listing_txid>",
      "token_id": "abc123def456_0",
      "quantity": 40,
      "price_satoshis": 3000,
      "total_satoshis": 120000,
      "seller_address": "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
      "block_height": 100,
      "filled_at": "2026-06-06T23:53:24"
    }
  ]
}
```

### SSE Stream

```
GET /api/v1/stream/order-book
  ?token_id=<id>      # optional: filter events to a specific token
```

Events:
- `new_listing` — a new listing was indexed
- `listing_cancelled` — a listing was cancelled
- `listing_filled` — a listing was filled (full quantity in v1)

### Web UI

Browse the order book at `/order-book`.
Real-time updates via Phoenix PubSub.

## Example Transactions

### Listing

A seller lists 100 tokens of `abc123def456_0` at 5,000 satoshis each, with a pre-signed offer committing to a 500,000-satoshi payment:

```
OP_RETURN
  "orderbook"
  "1"
  "list"
  "abc123def456_0"
  "100"
  "5000"
  "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
  "abc123def456:0"
  "02a1633cafcc01ebfb6d78e39f687a1f0995c62fc95f51ead10a02ee0be551b5dc"
  "3045022100...c1"
  "0xc1"
  "2026-12-31T23:59:59Z"
  "100"
```

### Cancellation

The seller cancels the listing:

```
OP_RETURN
  "orderbook"
  "1"
  "cancel"
  "abc123def456abc123def456abc123def456abc123def456abc123def456abcd1234"
```

### Fill

A buyer purchases the listing (full quantity, 100 tokens):

```
OP_RETURN
  "orderbook"
  "1"
  "fill"
  "abc123def456abc123def456abc123def456abc123def456abc123def456abcd1234"
  "100"
  "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
```

## Compatibility

- Works with any BSV-20 Ordinal token (`{"p":"bsv-20","op":"transfer","amt":"N","id":"txid_vout"}`)
- Compatible with OrdinalP2MS (1-of-2 multisig) and OrdinalP2PKH (single-sig) script templates
- Any overlay node can index `orderbook` OP_RETURN transactions
- Clients compose transactions independently; Bitblocks is read-only

## Overlay Integration

For overlay network broadcast and lookup, use dedicated topics:

- **Broadcast topic:** `tm_orderbook` — publish listing, cancel, and fill transactions
- **Lookup topic:** `ls_orderbook` — query indexed listings

This follows the same pattern as Fractionalized's `tm_fractionalize` / `ls_fractionalize` topics.
