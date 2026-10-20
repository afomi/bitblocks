# Observations, Challenges, and Opportunities

> Notes from the Trello integration and plan execution — 2026-03-28

---

## Observations

### Bitblocks has strong visualization infrastructure
The THREE.js hooks (block_graph, peer_map, network_pulse, fork_graph, ecosystem_graph) provide a solid foundation for any 3D blockchain visualization.
The LOD system, instanced meshes, and force-directed layouts are production-quality.

### The DID system is surprisingly complete
DID Live already handles did:web creation, JWK key generation (ES256 + EdDSA), Verifiable Credential issuance (JWT-VC), full verification with DID resolution, StatusList2021 revocation checking, and vanity DID generation.
Adding vCard support was minimal work on top of this.

### Protocol detection is extensible
TransactionParser's protocol detection pipeline makes it easy to add new protocol parsers (vCard, schema.org, etc.) without modifying the core parsing logic.

### Qart and Bitblocks share the `bsv` library
Both depend on `bsv ~> 2.1`.
Qart uses a git fork (`afomi/bsv-ex`), bitblocks uses the hex package.
This is the most concrete shared dependency.

---

## Challenges

### Qart/Bitblocks boundary is porous at the tx layer
Bitblocks `BuilderLive` is a partial copy of qart's tx builder — it constructs transactions (inputs, outputs, signing, broadcast), which directly overlaps with qart's `protocol/encoder.ex`, `transactions/` modules, and wallet infrastructure.
`BuilderLive` should be removed from bitblocks or replaced with a link to qart.
The canonical tx builder lives in qart.
The boundary needs enforcement: bitblocks reads, qart writes.

### Transaction outputs stored as string arrays
The `Transaction` schema stores inputs/outputs as `{:array, :string}` where each element is a JSON string.
This requires `Jason.decode` on every element during graph traversal and protocol detection.
A dedicated input/output schema would be cleaner but requires a migration.

### No shared package for tx primitives
Both projects independently depend on the `bsv` library.
Neither has extracted their tx encoding/decoding into a reusable package.
Common primitives that could be shared:
- OP_RETURN parsing and protocol detection
- B:// and ordinal content detection
- UTXO models
- Script type identification (P2PKH, P2SH, etc.)

### LiveBook integration is a deployment gap
The plan calls for LiveBook data access, but this requires deployment configuration (connecting LiveBook to the bitblocks database/Repo), not application code.

---

## Next-Level Opportunities

### 1. Extract a shared `bsv_tools` package
Create an Elixir package containing:
- **TransactionParser** (OP_RETURN extraction, protocol detection)
- **ContentDetector** (B://, ordinals, MIME categorization)
- **VcardParser** (vCard from OP_RETURN)
- **SchemaTemplate** (schema.org payloads)
- **Script type identification**

Both bitblocks and qart would depend on this.
Qart's `protocol/encoder.ex` and `protocol/decoder.ex` would be the write-side counterparts.

### 2. Qart's encoder/decoder could be the standard BSV tx library
Qart already has:
- `Qart.Protocol.Encoder` — tx encoding
- `Qart.Protocol.Decoder` — tx decoding
- `Qart.Protocol.LegacyDecoder` — backward compatibility
- `Qart.Transactions.UTXO` — UTXO management
- `Qart.Transactions.SplitTx` — tx splitting
- `Qart.BSV.Inscription` — ordinal inscriptions
- `Qart.SPV` — SPV verification

Packaging these as a standalone library (`bsv_ex` or extending `afomi/bsv-ex`) would give every BSV Elixir project a batteries-included tx toolkit.

### 3. Bitblocks as the read-side oracle for qart
Bitblocks syncs blocks, parses transactions, detects protocols, and indexes content.
Qart constructs and broadcasts transactions.
A natural integration: qart queries bitblocks' API to confirm transactions, check UTXO status, and verify on-chain state.
The existing `/api/v1/protocols` API is a start.

### 4. Event sourcing across both projects
`SchemaTemplate.aggregate/1` demonstrates event-sourced state from schema.org transactions.
Combined with qart's `Commanded` (event sourcing framework in deps), this could power a full CQRS architecture:
- **Qart** = command side (create transactions)
- **Bitblocks** = query side (read and aggregate state from chain)

### 5. Shape Layer NFTs could become a mapping product
The `ShapeLayer` module + GeoJSON viewer is a starting point.
Combined with qart's marketplace (`Qart.Marketplace`), shape layers could be minted, listed, and traded.
Geographic data on-chain has applications in property records, zoning, and civic data.

### 6. Public Official credentials as a civic product
`CredentialTypes.public_official/1` + the DID system could power a "verify your representative" product.
A city could issue VCs for elected officials, and citizens could verify them via bitblocks' verification flow.
This aligns with the Trello card about "editable profile on-chain for elected person."

---

## Summary

The plan is fully executed (items 1–10).
The biggest architectural opportunity is extracting shared tx primitives into a package that both bitblocks and qart use.
The second biggest is establishing the bitblocks-reads / qart-writes boundary as a formal integration pattern.
