# Bitblock — A Filtered Chain Instance

A Bitblock is an instance of the Bitblocks software that indexes a subset of the chain.

## The Idea

Bitblocks indexes the full BSV chain.
A Bitblock indexes only the transactions that match a filter.

```
Bitblocks (full chain)
  ├── Bitblock: "VisibleDAO"     — all txs with MAP app=visibledao
  ├── Bitblock: "Ryan's wallet"  — all txs touching address 1ABC...
  ├── Bitblock: "Qart listings"  — all txs with MAP app=qart type=listing
  ├── Bitblock: "County records" — all txs from address 1GOV... with protocol=attest
  └── ... millions more
```

Each Bitblock is:
- The same codebase (same Phoenix app, same API, same UI)
- A different database (only the matching subset)
- A different filter (addresses, protocols, time ranges, or combinations)
- Independently deployable (localhost, cloud, or embedded)

## Analogy to Git

| Git | Bitblock |
|-----|----------|
| Full clone | Bitblocks (full chain index) |
| Sparse checkout | Bitblock (filtered subset) |
| Remote | BSV node or Bitblocks API |
| `git pull` | Sync new matching txs |
| Working tree | Local database |
| `.gitignore` | The filter (everything NOT matching is ignored) |

## Filter Specification

A Bitblock is defined by its filter — a declarative spec of what to sync:

```json
{
  "name": "VisibleDAO",
  "filters": [
    {"type": "address", "value": "1ABC..."},
    {"type": "address", "value": "1DEF..."},
    {"type": "protocol", "app": "visibledao"},
    {"type": "protocol", "prefix": "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"},
    {"type": "height_range", "from": 620000, "to": null}
  ],
  "combine": "or"
}
```

Filters compose with OR (any match includes the tx) or AND (all must match).
The filter is the identity of the Bitblock.

## Architecture

```
┌─────────────────────────┐
│  Bitblocks (full index)  │
│  926k blocks, 1.7M txs  │
│  /api/v1/...             │
└──────────┬──────────────┘
           │ sync API
           ▼
┌─────────────────────────┐     ┌─────────────────────────┐
│  Bitblock: "VisibleDAO" │     │  Bitblock: "Qart"       │
│  filter: app=visibledao │     │  filter: app=qart       │
│  12 blocks, 847 txs     │     │  200 blocks, 3.2k txs   │
│  /api/v1/...             │     │  /api/v1/...             │
└─────────────────────────┘     └─────────────────────────┘
```

A Bitblock syncs from Bitblocks (or directly from a node).
It pulls only the transactions matching its filter.
It serves the same API endpoints, same UI — but scoped to its subset.

## Sync Protocol

A Bitblock needs a sync source — either Bitblocks API or a BSV node.

### From Bitblocks API

```
GET /api/v1/txs?protocol=map&app=visibledao&since_height=925000
```

Returns matching transactions since the last sync point.
The Bitblock stores them locally and advances its sync cursor.

### From a BSV Node (direct)

The Bitblock runs its own sync pipeline but applies the filter during indexing.
Only matching transactions are stored. Non-matching blocks store headers only.

### Hybrid

Sync block headers from the node (cheap, fast).
Sync filtered transactions from Bitblocks API (pre-indexed, no parsing needed).

## What a Bitblock Looks Like

Same UI as Bitblocks, but scoped:

- Homepage shows stats for the subset ("847 transactions across 12 blocks")
- Block list shows only blocks containing matching txs
- Search finds only matching transactions
- API returns only matching data
- SSE stream emits only matching events

The branding can be customized — "VisibleDAO Explorer" instead of "Bitblocks."

## Deployment Options

| Option | Use case |
|--------|----------|
| **Localhost** | Developer running a personal Bitblock for their app's txs |
| **Cloud** | Organization running their domain-specific explorer |
| **Embedded** | Bitblock running inside another app (qart, touchpoints_ex) |
| **Browser** | SQLite/OPFS Bitblock running entirely client-side |

The browser option connects back to the Chain Lens concept:
the local-first DB is a Bitblock, the filter defines what syncs to it.

## Configuration

A Bitblock is configured by a single file — its filter spec:

```elixir
# config/bitblock.exs
config :bitblocks, Bitblocks.Bitblock,
  name: "VisibleDAO",
  sync_source: "https://bitblocks.app",
  filter: %{
    protocols: [%{app: "visibledao"}],
    addresses: ["1ABC..."],
    from_height: 620_000
  }
```

Or as environment variables for container deployment:

```
BITBLOCK_NAME=VisibleDAO
BITBLOCK_SYNC_SOURCE=https://bitblocks.app
BITBLOCK_FILTER_PROTOCOL_APP=visibledao
BITBLOCK_FILTER_FROM_HEIGHT=620000
```

## Economics

Bitblocks (the full index) is expensive — 20TB node, full chain in Postgres.
A Bitblock is cheap — maybe 100MB of data, runs on a $5/month VPS or free on localhost.

The business model:
- Bitblocks charges for sync access (the pricing tiers)
- Bitblocks pays for the full chain infrastructure
- Bitblock operators pay for their subset (tiny) and their sync source (Bitblocks API)

This is the CDN model inverted:
instead of one server caching everything, millions of clients cache their slice.

## Relationship to Other Concepts

**Chain Lens** (docs/CHAIN_LENS.md): a Bitblock IS a chain lens — materialized and persistent.
The filter defines the lens. The local database is the materialized view.

**Command-first**: the filter is the command. "Show me all VisibleDAO transactions" is a
declarative query that produces a derived dataset. The Bitblock is the result.

**qart boundary**: qart could embed a Bitblock filtered to `app=qart`.
It would have its own explorer UI showing only qart transactions — no separate infrastructure needed.

## Prior Art: Unwriter's Planaria

Bitblock is directly inspired by Unwriter's Planaria architecture (2018-2020).
Planaria introduced the concept of a "programmable Bitcoin node" — define a filter,
get a derived database.

| Planaria | Bitblock |
|----------|----------|
| Gene (filter) | Filter spec |
| Planarium (host) | Bitblocks (full index) |
| Planaria instance | Bitblock instance |
| MongoDB | PostgreSQL |
| Bitquery (custom query language) | Standard Ecto/SQL queries |
| TXT (transaction tape) | MAP/Bitcom protocol parsing |
| BOB (Bitcoin OP_RETURN Bytecode) | Transaction parser |
| Neon (genesis sync) | Backfill from height 0 |
| Chronos (live sync) | TipSyncWorker + filtered webhooks |

Key Planaria concepts that carry forward:
- **The gene is the identity** — what you filter for defines what you are
- **Crawl + listen** — historical backfill + real-time tip following
- **State machine** — the derived DB is a projection of filtered chain events
- **Anyone can run one** — no permission needed, just a filter and a sync source

What Bitblock adds:
- **Elixir/OTP** — supervision trees, fault tolerance, LiveView for UI
- **Same codebase** — a Bitblock IS Bitblocks with a filter, not a separate tool
- **Design system** — consistent UI across all instances
- **API compatibility** — every Bitblock speaks the same API

Unwriter's work on GitHub: https://github.com/interplanaria

## Future: Mesh / P2P Between Bitblocks

If every Bitblock speaks the same API, they can sync from each other — not just from the canonical Bitblocks instance.

```
Bitblocks (full) ──┬── Bitblock A (app=qart)
                   │        │
                   │        └── Bitblock C (app=qart, address=1XYZ)
                   │                 syncs from A, not from Bitblocks
                   │
                   └── Bitblock B (app=visibledao)
                            │
                            └── Bitblock D (visibledao, height>900000)
                                     syncs from B
```

A Bitblock whose filter is a subset of another Bitblock's filter can sync from that peer instead of the root. This is a DAG of filtered views, where each node only holds what it needs and syncs from the nearest superset.

Questions to resolve later:
- **Discovery**: how does a Bitblock find peers whose filter is a superset of its own?
- **Trust**: do you trust a peer's data, or verify against the chain? (merkle proofs help here)
- **Consistency**: if two peers have overlapping filters, who's authoritative?
- **Gossip**: can Bitblocks announce new matching txs to peers, push-style?
- **DHT**: could the set of all Bitblocks form a distributed hash table where any txid is findable by routing through the mesh?
- **Incentives**: does a Bitblock that serves data to peers earn satoshis? (payment channels again)

This converges with the CDN concept — instead of S3 + CloudFront, the CDN is the mesh itself. Each Bitblock caches its slice and serves it to others. The chain's immutability means every peer's cache is verifiable.

The end state: no single Bitblocks instance is necessary. The full chain is distributed across millions of Bitblocks, each holding a shard defined by its filter. Any transaction is reachable by querying the right peer. The network *is* the index.

## Implementation Path

1. **Filter spec format** — define the JSON/config schema
2. **Filtered sync** — add filter params to the sync API (`/api/v1/txs?protocol=...&since_height=...`)
3. **Bitblock mode** — a config flag that limits indexing to matching txs
4. **Scoped UI** — homepage/search/API only shows filtered data
5. **Packaging** — Docker image + filter config = deployable Bitblock

How a consumer application hydrates a filter from this full-chain index (plan → snapshot pages → catch-up → follow), and how filters get registered as named applications, is drafted in `docs/USE_CASES.md`.
