# Composable Data Streams

Users define domain objects.
Qart writes them to the chain.
Bitblocks indexes and serves them as subscribable streams.

## The Pattern

```
Define schema  →  Write instances  →  Index by schema  →  Subscribe
   (dev)            (qart/wallet)       (bitblocks)        (consumer)
```

Today, OP_RETURN data is ad-hoc — each app invents its own structure.
MAP provides key-value pairs but no schema enforcement.
The result: you can write anything, but finding and filtering is hard.

Composable streams add a thin layer: **named schemas that describe the shape of domain objects**.

## What a Stream Looks Like

A developer building a marketplace defines:

```json
{
  "stream": "qart.listing",
  "version": 1,
  "fields": {
    "title": "string",
    "price_sats": "integer",
    "image_txid": "txid",
    "seller": "address",
    "status": {"enum": ["active", "sold", "cancelled"]}
  }
}
```

This schema lives on-chain (a MAP SET transaction that defines the stream).
It's the "CREATE TABLE" for on-chain data.

## Writing to a Stream (qart concern)

Qart builds a transaction with MAP data that conforms to the schema:

```
OP_RETURN
  | MAP_ADDR | SET
  | app      | qart
  | stream   | qart.listing
  | title    | "Vintage Guitar"
  | price    | 50000
  | image    | <txid of B:// image>
  | seller   | 1ABC...
  | status   | active
```

The transaction IS the domain object.
The txid IS the object ID.
Updating = new transaction referencing the original (append-only, like git commits).

### Scoping and Visibility (qart wallet concerns)

- **Create**: compose the MAP fields, sign, broadcast
- **Scope**: the `stream` field determines which index picks it up
- **Hide**: broadcast a MAP SET with `status=hidden` referencing the original txid
- **Show**: broadcast a MAP SET with `status=active`

These are all transactions — the chain records the full lifecycle.
The current state is the latest transaction for each object ID.

## Reading a Stream (bitblocks concern)

Bitblocks indexes MAP transactions and groups them by `stream` field:

```
GET /api/v1/streams/qart.listing
→ all active listings

GET /api/v1/streams/qart.listing?seller=1ABC...
→ listings from a specific seller

GET /api/v1/streams/qart.listing?since_height=925000
→ new listings since height 925000

SSE /api/v1/streams/qart.listing/live
→ real-time stream of new listings as they're confirmed
```

### Tune In / Subscribe

A user or app "tunes in" to a stream — they declare interest in a schema:

```
POST /api/v1/subscriptions
{
  "stream": "qart.listing",
  "filters": {"status": "active", "price_sats": {"lt": 100000}},
  "webhook": "https://myapp.com/hooks/new-listings"
}
```

Bitblocks watches for matching transactions and pushes them to the subscriber.
This is the webhook system from the GTD inbox, but typed by stream schema.

## Stream Discovery

How does a consumer find streams?

```
GET /api/v1/streams
→ list of all known stream schemas

GET /api/v1/streams?app=qart
→ streams defined by qart

GET /api/v1/streams/qart.listing/schema
→ the field definitions for this stream
```

Schemas are on-chain — anyone can read them.
Bitblocks indexes schema-definition transactions and serves them as a registry.
This extends the existing protocol registry at `/api/v1/protocols`.

## From Ad-Hoc to Typed

The progression:

```
Today:     OP_RETURN with raw bytes         (unstructured)
           ↓
MAP:       key-value pairs with app field   (semi-structured)
           ↓
Streams:   named schemas with typed fields  (structured)
           ↓
Future:    sCrypt contracts enforcing schema (enforced on-chain)
```

Today, anyone can write `app=qart type=listing` with missing fields.
With streams, Bitblocks can validate incoming txs against the schema and flag non-conforming ones.
With sCrypt covenants, the chain itself rejects non-conforming transactions.

Each step tightens the type system — from convention to validation to enforcement.

## Composability

Streams compose because they're just filtered views of the same chain:

```
Stream: qart.listing
  ├── filtered by: seller=1ABC...     → "My listings"
  ├── filtered by: status=active      → "Active marketplace"
  ├── joined with: qart.review        → "Listings with reviews"
  └── aggregated: count by seller     → "Top sellers"
```

A Bitblock (docs/BITBLOCK.md) can be configured to sync one or more streams.
A "Qart Bitblock" syncs `qart.listing` + `qart.review` + `qart.purchase`.
It has the full domain model for the marketplace, nothing else.

## Example Streams

| Stream | App | Fields | Use |
|--------|-----|--------|-----|
| `qart.listing` | qart | title, price, image, seller, status | Marketplace listings |
| `qart.purchase` | qart | listing_txid, buyer, amount | Purchase records |
| `qart.review` | qart | listing_txid, rating, text, reviewer | Reviews |
| `vdao.proposal` | visibledao | title, body, author, status, votes_for, votes_against | Governance proposals |
| `vdao.vote` | visibledao | proposal_txid, voter, position | Votes on proposals |
| `attest.license` | gov | type, id, holder, expires, issuer | Business licenses |
| `attest.permit` | gov | type, parcel, holder, status, issuer | Land use permits |

Each stream is a domain model.
Each transaction is a record.
The chain is the database.
Bitblocks is the query layer.

## Relationship to Bitblock

A Bitblock is a materialized stream subscription.
The filter spec from BITBLOCK.md maps directly to stream subscriptions:

```json
{
  "name": "Qart Explorer",
  "streams": ["qart.listing", "qart.purchase", "qart.review"]
}
```

This Bitblock syncs only those three streams.
Its UI shows listings, purchases, and reviews — a complete marketplace explorer.
Same Bitblocks software, different filter, different data, different brand.

## Implementation in Bitblocks

Requires:
1. **Stream registry** — index schema-definition txs (extends protocol registry)
2. **Stream indexing** — during sync, parse MAP transactions and tag by stream
3. **Stream API** — `/api/v1/streams/:name` with filter params
4. **Stream SSE** — `/api/v1/streams/:name/live` for real-time
5. **Webhook subscriptions** — push matching txs to subscribers

Does NOT require:
- Changes to Bitcoin protocol
- New opcodes or script changes
- Consensus changes of any kind

It's a convention layer — MAP already supports this.
Streams just add naming and schema discovery on top.
