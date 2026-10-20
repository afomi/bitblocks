# Transaction Metadata

This document explores the concept of metadata as it relates to Bitcoin SV transactions in Bitblocks.
It starts from OOP basics — the object model of a transaction — then expands into the open-ended space of shapes, patterns, and payloads.

## The Object: Transaction

A transaction is the atomic unit.
Every transaction has intrinsic, structural properties:

| Property | Type | Source |
|----------|------|--------|
| txid | string (hex, 64 chars) | hash of serialized tx |
| version | integer | tx header |
| lock_time | integer | tx header |
| inputs | list | tx body |
| outputs | list | tx body |
| size | integer (bytes) | serialized form |

These are **identity** and **structure** — the equivalent of an object's class fields.
They exist on every transaction regardless of purpose or content.

## Derived Properties (Computed from Structure)

The next layer is metadata we compute deterministically from the raw bytes:

| Property | Derivation |
|----------|-----------|
| input_count | `length(inputs)` |
| output_count | `length(outputs)` |
| total_input_satoshis | sum of input values |
| total_output_satoshis | sum of output values |
| miner_fee | inputs − outputs |
| coinbase? | first input has null prevout |
| output_types | frequency map of script types across outputs |
| input_txids | distinct txids referenced by inputs |
| output_addresses | addresses derived from output scripts |

These are the object's **computed accessors** — pure functions of the structural fields.
They never change for a given txid.

## Script Types (Output Classification)

Each output has a locking script.
The script determines the output's **type**:

- `p2pkh` — pay to public key hash (standard payment)
- `p2pk` — pay to public key
- `p2sh` — pay to script hash
- `op_return` — data carrier (unspendable)
- `multisig` — m-of-n signature requirement
- `unknown` — non-standard or novel script

This is the **interface** layer — what behaviors the output exposes.
A P2PKH output implements "someone with this key can spend."
An OP_RETURN output implements "this carries data, not value."

## Protocol Detection (Behavioral Metadata)

OP_RETURN outputs carry payloads.
The first pushdata chunk often signals which **protocol** the payload conforms to:

| Address/Prefix | Protocol | Family |
|---------------|----------|--------|
| `19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut` | B:// | data storage |
| `1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5` | MAP | metadata |
| `15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva` | AIP | identity/signing |
| `1HA1P2exomAwCUycZHr8WeyFoy5vuQASE3` | HAIP | identity/signing |
| `meta` | Metanet | DAG structure |
| `ord` | 1SAT Ordinals | NFT/inscriptions |

Protocols are **mixins** or **interfaces** — a tx can implement multiple.
Piped OP_RETURN (`B:// | MAP | AIP`) is multi-protocol composition.

## The Open-Ended Space

Beyond the fixed schema, transactions carry content that is:

- **Unbounded in shape** — any byte sequence can exist in OP_RETURN
- **Contextual** — meaning depends on the protocol interpreting it
- **Compositional** — protocols pipe together, layering meaning
- **Evolving** — new protocols emerge without coordination

This is where the OOP analogy breaks down, or rather, where it becomes a type system over an open world.

### Shapes

A tx's "shape" is its structural silhouette:

- **1-in, 2-out** — standard payment with change
- **1-in, 1-out (OP_RETURN)** — pure data write
- **many-in, 1-out** — consolidation (UTXO cleanup)
- **1-in, many-out** — fan-out (distribution, airdrop)
- **many-in, many-out** — complex business logic

Shape is cheap to compute and useful for clustering without parsing payloads.

### Patterns

Patterns are recurring arrangements that imply purpose:

- **Anchor pattern** — OP_RETURN output + change output (Bitcom standard)
- **Metanet DAG** — parent reference chain forming a tree
- **Token transfer** — specific script templates with token metadata
- **Event sequence** — txid referencing a prior txid, forming a log
- **Batch attestation** — single tx embedding many hashes

Patterns sit between shape (structural) and protocol (semantic).
They require understanding the relationship between outputs, or between transactions over time.

### Payloads

The actual content within a protocol envelope:

- **Text** — UTF-8 content (posts, documents, records)
- **Binary** — images, files, arbitrary data
- **Structured** — JSON, CBOR, schema.org, vCard
- **References** — txids, URIs, content addresses
- **Proofs** — signatures, merkle paths, attestations

Payload interpretation requires knowing the protocol.
The same bytes mean different things under B:// vs. MAP vs. a custom scheme.

## Metadata Layers

Pulling it together, transaction metadata exists in layers:

```
┌─────────────────────────────────────────────┐
│ Layer 5: Semantic / Application              │
│ "This is a Twetch post by user #12345"       │
├─────────────────────────────────────────────┤
│ Layer 4: Protocol                            │
│ "Contains B://, MAP, AIP"                    │
├─────────────────────────────────────────────┤
│ Layer 3: Pattern                             │
│ "Anchor pattern with piped OP_RETURN"        │
├─────────────────────────────────────────────┤
│ Layer 2: Derived                             │
│ "2 inputs, 3 outputs, 0.015 BSV fee"        │
├─────────────────────────────────────────────┤
│ Layer 1: Structural                          │
│ "txid, version, inputs[], outputs[]"         │
└─────────────────────────────────────────────┘
```

Each layer builds on the one below.
Lower layers are deterministic and universal.
Higher layers are interpretive and protocol-specific.

## Current State in Bitblocks

The `transactions` table currently stores through Layer 4:

- **Layer 1**: `txid`, `raw`, `version`, `inputs`, `outputs`
- **Layer 2**: `input_count`, `output_count`, `total_input_satoshis`, `total_output_satoshis`, `input_txids`, `output_addresses`, `coinbase`
- **Layer 3**: `output_types` (frequency map of script types)
- **Layer 4**: `protocols` (array of detected protocol names)

Layer 5 (semantic/application) is handled by specialized parsers (`ProtocolParser`, `MetanetParser`, `MapParser`, `VcardParser`) but not persisted in the transaction row itself.

## Design Tension

The fundamental tension:

- **Fixed schema** wants to know the columns up front.
- **Open-ended protocols** produce unbounded key-value metadata.

Options for resolving:

1. **JSONB column** — `metadata` map storing protocol-specific parsed fields.
   Flexible but untyped. Good for exploration, hard to index efficiently.

2. **Separate tables per protocol** — `metanet_nodes`, `b_files`, `map_records`.
   Typed and indexable. But each new protocol needs a migration.

3. **EAV / tag system** — `tx_attributes(txid, key, value)`.
   Infinitely flexible. Performance and query ergonomics suffer.

4. **Materialized views** — parse on read, cache the result.
   No schema changes. But stale unless refreshed.

5. **Hybrid** — fixed columns for universal metadata (Layers 1–3), JSONB for Layer 4+, dedicated tables for high-value protocols that need indexed queries.

## Progressive Enhancement Sequence

We don't need to understand everything about a transaction at once.
Metadata accrues over time — start with the cheapest, most universal facts and layer on interpretation as the system matures.

The sequence below is ordered by dependency and cost.
Each phase unlocks the next but is independently useful.

### Phase 1: Spent or Not

The most fundamental question about any output: has it been consumed?

An output is either **unspent** (a live UTXO) or **spent** (referenced as an input in a later tx).
This is a single boolean per output, derivable from the input set of all known transactions.

**What it unlocks:**
- UTXO set — the current state of the ledger
- Live vs. historical distinction — which coins still exist
- Foundation for everything else (you can't compute balances without knowing what's spent)

**What it requires:**
- For each output: scan inputs across all transactions for a matching `(txid, vout)` pair
- Or: maintain a spend index that records `spending_txid` per outpoint

**Cost:** medium (requires cross-referencing inputs and outputs across txs), but the result is a single bit per output.

### Phase 2: Coinbase or Not

Is this transaction the first transaction in a block — the miner's reward?

Coinbase transactions are the **origin** of all coins.
Every satoshi in circulation traces back to a coinbase output.
They have no real inputs (the "input" is the block reward + fees).

**What it unlocks:**
- Distinguishing minted coins from transferred coins
- Identifying miner activity and revenue
- The root of every chain of spends

**What it requires:**
- Check if the first input references a null prevout (all zeros)
- Already computed in `TransactionParser.is_coinbase?/1` and stored in the `coinbase` column

**Cost:** trivial.
Already done.

### Phase 3: Chain Length (Depth of Spend)

How many times has value moved since it was minted?

Starting from a coinbase output (depth 0), follow the spend chain:
- Coinbase output → spent by tx B → depth 1
- Tx B output → spent by tx C → depth 2
- Tx C output → unspent → depth 2 (current tip)

This is the **chain length** or **spend depth** of a UTXO.

**What it unlocks:**
- Age of money — how many hops from the coinbase
- Velocity signal — frequently re-spent coins vs. long-held coins
- Graph structure — the spine of the transaction DAG
- "Coin days" style metrics — combine chain length with block timestamps

**What it requires:**
- Phase 1 (spent tracking) as prerequisite
- Phase 2 (coinbase identification) to know where chains start
- Recursive traversal: follow `input_txids` backward to find the coinbase, counting hops
- Or: compute incrementally — when a tx spends an output, its depth = parent depth + 1

**Cost:** high for historical backfill (recursive graph walk), cheap to maintain going forward if computed on ingest.

### Phase 4: Script Type Classification

What kind of lock does each output use?

This is the `output_types` map: p2pkh, p2pk, p2sh, op_return, multisig, unknown.
Already partially implemented — `TransactionParser.determine_script_type/1` classifies outputs by opcode pattern.

**What it unlocks:**
- Knowing which outputs are payments vs. data carriers vs. multi-party contracts
- Filtering the UTXO set by script type
- Understanding the composition of blocks (what fraction is payments vs. data)

**What it requires:**
- Raw script bytes (already stored)
- Pattern matching on opcode sequences

**Cost:** cheap per output.
Already done for analyzed transactions.

### Phase 5: Script Parsing (Addresses, Keys)

Extract the semantic fields from each script type.

For p2pkh: the public key hash (→ address).
For p2pk: the public key.
For multisig: the m, n, and all public keys.
For op_return: the payload (protocol detection follows from here).

**What it unlocks:**
- Address-level indexing — "show me all outputs paying to address X"
- The prerequisite for balance computation
- Public key association for identity protocols

**What it requires:**
- Phase 4 (know the script type before parsing its fields)
- Already partially done: `output_addresses` extraction exists for p2pkh/p2sh

**Cost:** cheap per output.
Incremental over what exists.

### Phase 6: Account Balance

The balance of an address is the sum of its unspent outputs.

`balance(address) = Σ satoshis for all UTXOs where output_address = address`

This is not a property of a single transaction — it's an aggregate across the UTXO set, filtered by address.

**What it unlocks:**
- Wallet-style views — "how much does this address hold?"
- Rich list / distribution analysis
- The question most users ask first

**What it requires:**
- Phase 1 (spent tracking) — must know which outputs are unspent
- Phase 5 (address extraction) — must know which address each output pays to
- Aggregation query: sum unspent output values grouped by address

**Cost:** query cost scales with UTXO set size.
Optionally materialized as a `balances` table or view for fast reads.

### Summary

| Phase | Question | Depends On | Cost | Status |
|-------|----------|-----------|------|--------|
| 1 | Spent or not? | — | medium | not yet |
| 2 | Coinbase or not? | — | trivial | done |
| 3 | Chain length? | 1, 2 | high (backfill) | not yet |
| 4 | Script type? | — | cheap | done |
| 5 | Parsed fields? | 4 | cheap | partial |
| 6 | Account balance? | 1, 5 | aggregate | not yet |

The first three phases are about **the graph** — understanding the structure of value flow.
The last three are about **the content** — understanding what the scripts say and what they mean.

Graph first, content second.
Spent tracking is the foundation.

## What's Next

Open questions as we learn more:

- Which Layer 5 data is worth persisting vs. computing on demand?
- Should protocol-parsed results live in the transaction row or in satellite tables?
- How do we handle multi-protocol transactions (a tx that is simultaneously B://, MAP, AIP)?
- What indexing strategy supports "find all txs matching this pattern" efficiently?
- How does this connect to the Data Dictionary's `format` and `example` records?
- What's the right granularity for spend tracking — per output or per tx?
- Should chain length be stored or computed on the fly?
- How do we handle fan-in (multiple chains merging) when computing depth?
