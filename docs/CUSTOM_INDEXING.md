# Custom Indexing

How Bitblocks evolves from a fixed-schema explorer to a programmable indexing service.

## What exists today

Bitblocks already has the core pieces.

**Transaction Parser** (`TransactionParser.analyze/1`)
Runs on every transaction during sync.
Extracts output types, detected protocols, and coinbase status.
Stores results directly on the transaction record.
Bumping `script_analysis_version` triggers reanalysis across all stored transactions (`Release.analyze_transactions/1` backfills).

**Protocol Handler behaviour + compile-time registry** (`Bitblocks.Protocol.Handler`, `Bitblocks.Protocol.Handlers`)
These are the primary extension points for protocol detection and parsing.
Each protocol is one handler module implementing the `Handler` behaviour: a declarative `segment_matcher/0` (prefix / exact / contains on a segment's first chunk), an optional `detect/1` context predicate (MAP `app=` values, hex sniffs, joined-text formats), and an optional `parse/1` deep parser.
Handlers are registered, in detection order, in the compile-time list inside `Handlers` — compile-time because detection runs on every transaction during sync, so there are no DB round-trips on the hot path.
Adding a protocol that needs custom detection or deep parsing = one handler module + one registry entry.

**Registry cache for prefix-only protocols** (`Bitblocks.Protocol.RegistryCache`)
An ETS cache of `{address, name}` pairs from the `ProtocolRegistry` DB, consulted by `Handlers.detect_all/1` only for OP_RETURN segments no compile-time handler claimed.
This means an admin can add a PREFIX-ONLY protocol without a deploy: insert a `ProtocolRegistry` row (address + name) and call `RegistryCache.refresh/0`.
Detection stays ETS-lookup-only per tx; an empty or unavailable cache degrades to compile-time handlers alone.

**Protocol Registry** (`ProtocolRegistry`)
A database of known protocols with:
- Bitcom address (the prefix identifier)
- Name, category, verification status
- A `schema` field (map) intended for defining how to parse OP_RETURN data — **not yet wired to parsing** (see below)
- Relationships to stats, audits, and instances

It remains the metadata/stats/display layer, keyed by the same names as the handler registry — and, via `RegistryCache`, the no-deploy path for prefix-only detection.

**Protocol Parser** (`ProtocolParser`)
Deep parsing dispatches through `Handlers.parse/2` to each handler's `parse/1` — structured data from Twetch posts, MAP key-value pairs, Metanet nodes, etc.

**Script-addressed API** (`/api/v1/script/*`)
Scripthash history/unspent lookups, `POST /script/decode`, and a `script_templates` registry (`Bitblocks.Script.Templates`) let developers query by script shape rather than address.

The pipeline is: raw tx → parse script → detect protocols (compile-time handlers, then RegistryCache prefixes) → extract structured data → store.

## What's missing

Schema-driven parsing remains future work.
`RegistryCache` closes the detection gap for prefix-only protocols, but the gap between "we detect protocol X" and "here's a queryable table of all protocol X records" is still manual for anything needing structured extraction.
Each such protocol requires code: a handler module with a `parse/1`, maybe a new schema, a new API endpoint.

The ETH ecosystem solved this with tools like Subgraph, Shovel, and Ponder — they let developers define custom indexing without modifying the core indexer.

## The path forward (aspirational — not yet built)

Everything in this section is future work; nothing below exists in code today.

### 1. Protocol definitions drive parsing

The Protocol schema already has a `schema` field.
This should define the structure of the OP_RETURN data: field names, types, positions.

```
%{
  "fields" => [
    %{"name" => "app", "type" => "string", "position" => 1},
    %{"name" => "type", "type" => "string", "position" => 2},
    %{"name" => "content", "type" => "string", "position" => 3}
  ]
}
```

When TransactionParser detects a protocol with a schema definition, it parses the OP_RETURN data according to that schema and stores the result as structured metadata.

### 2. Protocol data lands in queryable storage

Parsed protocol data needs to be queryable — not buried in a JSON blob on the transaction record.
Options, from simplest to most flexible:

- **JSONB column on transactions** — `protocol_data` map, queryable via Postgres JSON operators. Simplest. No migrations per protocol.
- **Protocol instances table** — the existing `instances` relation on Protocol. One row per detected instance, with parsed fields stored as a map.
- **Materialized views** — Postgres views built from protocol_data queries. Named, queryable, refreshable. This is the "developer pays for a view" model.

### 3. Views as a product

A developer registers a protocol (or references an existing one), defines the schema, and requests a view.
Bitblocks backfills the view from existing transactions and keeps it current as new blocks sync.

The view is:
- A Postgres materialized view or table, populated by the indexing pipeline
- Exposed via API (filtered `/api/v1/protocols/:address/feed` already exists)
- Refreshed on each block

This is the paid tier.
The free tier is the explorer and basic API.
The paid tier is custom indexing: your protocol, your schema, your view, kept current.

### 4. What this looks like for the adoption spectrum

| Spectrum level | Indexing need | Product |
|---|---|---|
| **Pay** | Basic tx lookup | Free explorer |
| **Note** | "Show me all txs with prefix X" | Protocol registry + detection (free) |
| **Prove** | "Give me a live table of all records matching my schema" | Custom view (paid) |

## Relationship to ETH tools

| ETH tool | What it does | Bitblocks equivalent |
|---|---|---|
| Subgraph | Developer writes schema + mappings, indexer populates | Protocol schema + TransactionParser pipeline |
| Shovel | Config-driven, no code, chain → Postgres | Protocol registration with schema definition |
| Ponder | Local dev indexer with hot reload | Not needed — Bitblocks is the hosted service |

The key difference: Bitcoin's OP_RETURN model is simpler than Ethereum's event log system.
A protocol is a prefix and a data layout.
The schema definitions can be simpler too.

## Next steps (aspirational)

1. Use the Protocol `schema` field to drive parsing in the handler pipeline (a generic schema-driven handler alongside the compile-time ones)
2. Store parsed protocol data on the existing `instances` table
3. Expose via the existing `/api/v1/protocols/:address/feed` endpoint
4. Add materialized view generation for paying developers

Application-level framing (registry of products, not just protocols; identity; first-time and ongoing hydration of a consumer DB) is in `docs/USE_CASES.md`.
