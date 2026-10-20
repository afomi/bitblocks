# Validation Oracles — Off-Chain Validation, On-Chain Enforcement

Run full data validation off-chain.
Return a signed attestation.
The covenant checks the signature, not the data.

## The Problem

On-chain script can't practically run:
- JSON Schema validation
- Schema.org vocabulary checks
- Regex pattern matching
- Business logic ("price must be > 0", "email must be valid")

These are too complex and expensive for Bitcoin Script.
But we want the chain to enforce that data is valid.

## The Pattern

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────┐
│  Client (qart)  │────▶│  Validation Oracle    │────▶│  On-chain   │
│                 │     │                      │     │  covenant   │
│  "I want to     │     │  1. Receive data     │     │             │
│   set title to  │     │  2. Load schema by   │     │  Checks:    │
│   Vintage Guitar│     │     hash (immutable) │     │  - sig from │
│   on card X"    │     │  3. Run validation   │     │    oracle V │
│                 │     │  4. Sign attestation │     │  - schema   │
│                 │◀────│  5. Return signature │     │    hash     │
│                 │     │                      │     │    matches  │
│  Builds tx with │     └──────────────────────┘     │             │
│  data + oracle  │─────────────────────────────────▶│  If valid:  │
│  signature      │                                  │  allow spend│
└─────────────────┘                                  └─────────────┘
```

## Validation Function Identity

The validation function (schema) is identified by its content hash:

```
Schema file:    https://public.cards/schemas/person.v1.json
Content hash:   SHA256(file contents) = abc123def456...
```

The hash is immutable — if the schema changes, it gets a new hash.
The on-chain covenant references the hash, not the URL.
Anyone can download the schema, re-run the validation, and verify the oracle's attestation.

```json
{
  "$id": "pcrd:schema:person:v1",
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["title"],
  "properties": {
    "title": {
      "type": "string",
      "minLength": 1,
      "maxLength": 200
    },
    "schema_type": {
      "const": "schema:Person"
    },
    "name": {"type": "string"},
    "email": {"type": "string", "format": "email"},
    "url": {"type": "string", "format": "uri"}
  }
}
```

SHA256 of this file = the schema identity on-chain.

## The Attestation

The oracle signs a compact attestation:

```
Attestation = sign(oracle_key, SHA256(
  schema_hash  ||  data_hash  ||  "valid"  ||  timestamp
))
```

This says: "I verified that data with hash X conforms to schema with hash Y at time T."

The spending transaction includes:
- The data (in OP_RETURN / witness envelope)
- The attestation signature
- The schema hash (for the covenant to check)

## The Covenant

```
contract ValidatedCard {
  bytes32 schemaHash;      // which schema this card uses
  PubKey  oracleKey;       // trusted validator's public key
  PubKey  custodyKey;      // card owner

  public function update(
    SigHashPreimage txPreimage,
    Sig ownerSig,           // proves custody
    Sig oracleSig,          // proves data was validated
    bytes32 dataHash        // hash of the CBOR payload
  ) {
    // 1. Owner must sign
    require(checkSig(ownerSig, custodyKey));

    // 2. Oracle must attest that data is valid for this schema
    bytes message = schemaHash + dataHash + "valid";
    require(checkSig(oracleSig, oracleKey));

    // 3. Covenant perpetuates itself
    // (next output has same contract with same schema + oracle)
  }
}
```

The covenant is small and fast — two signature checks.
All the validation complexity lives off-chain in the oracle.

## Trust Model

**"But you're trusting the oracle!"**

Yes, but:

1. **The schema is public.** Anyone can download it and re-validate.
   If the oracle lied (signed "valid" for invalid data), anyone can prove it.

2. **Multiple oracles.** The covenant can require signatures from N-of-M validators.
   No single oracle can approve bad data alone.

3. **The oracle is stateless.** It takes data + schema, returns valid/invalid.
   Anyone can run one. There's no monopoly on validation.

4. **Reputation.** An oracle that signs off on invalid data loses trust.
   Since attestations are on-chain, cheating is permanent and provable.

The trust is in the validation function (the schema), not the validator.
The validator just runs the function. Anyone can check their work.

## Analogy to ActiveRecord

```ruby
# ActiveRecord — runs on your server, bypassable
class Listing < ApplicationRecord
  validates :title, presence: true, length: { maximum: 200 }
  validates :price, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: %w[active sold cancelled] }
end
```

```
# Validation Oracle — runs off-chain, result enforced on-chain
Schema (JSON Schema):
  title:  required, string, maxLength 200
  price:  required, integer, minimum 1
  status: required, enum [active, sold, cancelled]

Oracle: validates data against schema, signs attestation
Covenant: checks oracle signature before allowing UTXO spend

Same validation rules.
AR enforces in the app.
Oracle enforces via the chain.
AR can be bypassed (raw SQL, console, bugs).
Oracle cannot (covenant won't accept unsigned data).
```

## Implementation Path

### Phase 1: Schema Registry (no oracle yet)

Public Cards defines schemas as JSON Schema files.
Bitblocks indexes schema-definition transactions.
Validation is application-layer only (current state).

### Phase 2: Validation Service

Build a simple HTTP endpoint:

```
POST /validate
{
  "schema_hash": "abc123...",
  "data": { ... }
}

Response:
{
  "valid": true,
  "attestation": "<signature>"
}
```

The service loads the schema by hash, validates, signs.
Clients call this before broadcasting.
Still application-layer — no covenant yet.

### Phase 3: Covenant Enforcement

sCrypt contract that checks the oracle signature.
Card UTXOs now require attestation to spend.
Invalid data can't get on-chain, period.

### Phase 4: Decentralized Validation

Multiple oracle operators.
N-of-M attestation required.
Schema registry on-chain.
Anyone can run a validator node.

## What This Enables

- **Typed on-chain data that's actually validated** — not just convention
- **Validation rules versioned by content hash** — upgrade schema = new hash, old data stays valid under old rules
- **Separation of concerns** — chain handles ordering/custody, oracle handles validation, client handles UX
- **Composable** — different card types use different schemas, all validated the same way
- **Upgradeable without hard forks** — new schema hash = new validation rules, no protocol change
