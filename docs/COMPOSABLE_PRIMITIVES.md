# Composable Primitives

Bitcoin transactions and keypairs are not just a payment system.
They are a small set of primitives from which verifiable, composable programs can be built.

This document maps those primitives, the patterns they enable today, the gap that remains, and the interface paradigm that emerges when composition becomes the primary mode of interaction.

## The Primitives

| Primitive | What it is | Role in composition |
|-----------|-----------|---------------------|
| Keypair | Public/private key | Identity, authorization, signature |
| Outpoint | `txid_vout` | Stable pointer to any published artifact |
| Locking script | ScriptPubKey on an output | Declares spending conditions |
| Unlocking script | ScriptSig on an input | Satisfies spending conditions |
| OP_RETURN | Unspendable data output | Publish immutable typed data |
| OP_PUSH_TX | Injects spending tx into execution | Covenant — enforce output constraints |
| OP_CHECKDATASIG | Verify sig over arbitrary data | Oracle attestation bridge |
| Merkle proof | Path from txid to block header | Verifiable inclusion without full chain |

These are the atoms.
Every pattern is a molecule built from some combination of them.

## Patterns That Work Today

### Content-Addressed Publication

Publish any artifact — schema, code, template, credential — as an OP_RETURN output.
The outpoint becomes its permanent, verifiable identifier.

```
TX_A:
  output 0: OP_RETURN | <type_prefix> | <payload>
  → identifier: TX_A_0
```

Anyone can fetch TX_A_0, verify the hash, and trust the content is unchanged.
This is the foundation for reusable script templates, schema registries, and protocol definitions.

### Covenant (Enforced Spending Rules)

Using `OP_PUSH_TX`, a locking script can inspect the spending transaction itself.
This enables:

- **Enforced recipient** — "this output can only go to address X"
- **Enforced data** — "the spending tx must include an OP_RETURN with specific content"
- **State machine** — the contract forces its own next state into the spending tx

Covenants are the primitive that turns Bitcoin outputs into programs with memory.

### Oracle-Attested Evaluation

An oracle reads a published artifact (by outpoint), evaluates logic off-chain, and signs the result.
The locking script verifies the oracle's signature with `OP_CHECKDATASIG`.

```
Published rule at TX_A_0
        ↓
Oracle reads TX_A_0, evaluates input_data, signs (input_data + result + TX_A_0_hash)
        ↓
Locking script: verify oracle_sig, then enforce result
```

The oracle is the dynamic linker.
It fills the gap left by the absence of `OP_EVALFROMUTXO`.

### Reusable Script Template (by Outpoint)

A script template published at a known outpoint can be referenced by any contract that needs it.
Contracts don't inline the logic — they point to the outpoint and delegate evaluation to an oracle.

```
Template registry entry:
  TX_TEMPLATE_0: "validate card ownership"

Contract UTXO:
  "spendable if oracle O attests input satisfies TX_TEMPLATE_0"
```

100M UTXOs referencing the same template cost ~50 bytes each instead of ~500 bytes each.
The template lives once on-chain.

## The Missing Primitive

`OP_EVALFROMUTXO` (hypothetical) — fetch a referenced output's contents and execute them during script evaluation.
This would close the loop: trustless composition without an oracle.

Until it exists, the oracle is the trusted evaluator.
The pattern is sound; the trust assumption is explicit.

## Toward Declarative Composition

These primitives suggest a declarative model:

```
program = [
  ref(TX_SCHEMA_0),          # type definition, published on-chain
  ref(TX_VALIDATION_0),      # validation rule, published on-chain
  keypair(owner_pubkey),     # authorization
  covenant(next_state_rule)  # state transition constraint
]
```

A "smart contract" in this model is not code stored in a global VM.
It is a composition of outpoint references, keypairs, and script fragments.
Each component is independently verifiable, reusable, and content-addressed.

This is the Unix philosophy applied to contracts:
small tools, composable, connected by pointers rather than copies.

## Interface Paradigm

The composable primitive model connects to a lineage of interface research:

**Engelbart** — augmenting human intellect through structured, linkable artifacts.
Every outpoint is a link.
Every OP_RETURN publication is a node in a knowledge graph.
The chain is a shared, append-only, verifiable hypertext system.

**Kay** — objects with message passing, late binding, encapsulation.
A UTXO is an object: it has state (the locked value), behavior (the locking script), and identity (the outpoint).
Spending is message passing.
Covenants are method constraints.

**Victor** — live, inspectable, direct manipulation of programs and their outputs.
An explorer that shows a transaction not as raw hex but as a live graph of references — inputs pointing to outputs, outpoints linking to published artifacts, covenants showing their constraints — is the interface Victor points toward.
The data is already on-chain.
The gap is the representation layer.

## What This Means for Bitblocks

Bitblocks is positioned at the intersection of all three:

- **Indexer** — knows what's published at every outpoint
- **Parser** — understands protocol-tagged OP_RETURN payloads
- **Explorer** — can render the composition graph, not just raw data

The next layer is a **pattern registry**: a catalog of reusable script templates and composition patterns, each identified by outpoint, with human-readable descriptions, field definitions, and example transactions.

That is what the Data Dictionary is becoming.

## Related Docs

- `docs/OUTPOINT.md` — outpoint format and semantics
- `docs/REUSABLE_SCRIPTS.md` — content-addressed functions and the oracle pattern
- `docs/DATA_DICTIONARY_SPEC.md` — pattern registry specification
- `docs/VALIDATION_ORACLES.md` — oracle attestation pattern
