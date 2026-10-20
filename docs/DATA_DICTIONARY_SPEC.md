# Data Dictionary Specification

This document defines a proposed `Data Dictionary` for Bitblocks.

The goal is to support a sub-product focused on:

- describing Bitcoin SV transaction and script formats in detail
- attaching real on-chain examples to those format definitions
- powering explorer rendering, taxonomy work, and protocol discovery

The dictionary should be treated as a versioned catalog of recognizable transaction, script, envelope, and payload formats backed by observed blockchain data.

## Relationship to the transaction pack

The dictionary is a **derivative catalog**, not an independent source of kind definitions.

Canonical kind definitions live in the **transaction pack** (and, until that pack exists as a package, in the sibling-app tables that will feed it): a locking template, unlocking template, decode rules, validity class, relay, and version.
Each definition is keyed by the **content hash of the whole definition**, not only the script pattern.
A definition is then a self-verifying object that can be published on chain, so any indexer that sees the same bytes derives the same dictionary entry.

Bitblocks indexes and matches against those definitions.
It does not invent templates.
When the dictionary and the pack disagree, the pack wins and the dictionary re-derives.

Registration may be on-chain (canonical) or via API/admin (convenience, marked `local-only`).
Bitblocks hosts the index of registrations, not the applications that use them.

Every registered definition is a **filter**.
All N filters run on every transaction; matches are independent tags.
A newly registered filter is applied to history by re-index, then to the tip at ingest.
Unmatched templates surface as a discovery report (`unregistered template <hash>, seen N times`).

Product framing for applications, identity, and hydration: `docs/USE_CASES.md`.

## Purpose

The Data Dictionary is intended to answer questions like:

- What format is this transaction or output?
- How is this format detected?
- What fields does it contain?
- What are canonical examples?
- How should the explorer describe or render it?

It is not just a protocol list.

It should serve as a hybrid of:

- protocol catalog
- script semantics catalog
- labeled example corpus

## Design Principles

- Format definitions should be explicit and versioned.
- Detection rules should be machine-usable.
- Real examples should be first-class records.
- Ambiguity should be preserved instead of hidden.
- External standards should be referenced where they exist.
- The structure should support both human editing and future automation.

## Core Entities

The Data Dictionary should use the following top-level record types:

- `format`
- `variant`
- `example`
- `detector`
- `field`
- `reference`
- `note`

### `format`

The canonical definition of a recognizable transaction, input, output, envelope, payload, or transaction pattern.

### `variant`

A known sub-shape of a format that is meaningfully distinct but still belongs to the same broader family.

### `example`

A concrete on-chain instance of a format.

### `detector`

A rule used to classify or suggest candidate matches.

### `field`

A named semantic field extracted from the format.

### `reference`

An external or internal source supporting the format definition.

### `note`

Analyst commentary, caveats, edge cases, or historical context.

## Classification Model

Each `format` should be classified across multiple dimensions.

### Category

Recommended `category` values:

- `locking_script`
- `unlocking_script`
- `op_return_protocol`
- `transaction_pattern`
- `envelope`
- `payload`
- `metadata`
- `proof`

### Family

Recommended `family` values:

- `payment`
- `identity`
- `data_storage`
- `token`
- `nft`
- `attestation`
- `indexing`
- `notarization`
- `infrastructure`
- `other`

### Scope

Recommended `scope.level` values:

- `transaction`
- `input`
- `output`
- `envelope`
- `payload`

### Status

Recommended `status` values:

- `draft`
- `candidate`
- `stable`
- `deprecated`
- `ambiguous`

## Confidence Model

The dictionary should distinguish between:

- definition confidence
- example match confidence

Definition confidence can use:

- `low`
- `medium`
- `high`

Example match confidence can use:

- numeric range `0.0..1.0`

This helps preserve uncertainty without blocking useful classification.

## `format` Record Specification

Each `format` record should be a hand-authored definition stored in YAML.

### Required Fields

- `id`
- `version`
- `name`
- `status`
- `category`
- `family`
- `scope`
- `short_description`
- `detection`
- `fields`

At least one of:

- `references`
- `notes`

### Recommended Fields

- `long_description`
- `network`
- `tags`
- `render_hints`
- `examples`
- `variants`

### Example

```yaml
id: bsv.p2pkh
version: 1
status: stable
definition_confidence: high
category: locking_script
family: payment
name: Pay to Public Key Hash
short_description: Standard payment output locking script using a public key hash.
long_description: >
  A standard Bitcoin locking script that requires a valid signature and public
  key matching the embedded public key hash.
network:
  - mainnet
  - testnet
scope:
  level: output
  applies_to:
    - txout
detection:
  primary_detector: detector.p2pkh.asm_pattern.v1
  confidence: high
fields:
  - name: pubkey_hash
    type: hex
    required: true
    repeated: false
    source: script
    path: script.pushdata[0]
    description: 20-byte public key hash embedded in the locking script.
render_hints:
  badge: P2PKH
  color_token: amber
  preferred_label_field: pubkey_hash
examples:
  - example.mainnet.000001.txid.vout0
references:
  - id: ref.bitcoin.dev.script
    type: normative
    title: Bitcoin Script Reference
    url: https://bitco.in/en/developer-reference
tags:
  - standard
  - payment
  - script
```

## `variant` Record Specification

Variants capture a meaningful sub-shape of a broader format.

### Required Fields

- `id`
- `format_id`
- `name`
- `status`

### Recommended Fields

- `differences`
- `detectors`
- `fields`
- `examples`

### Example

```yaml
id: bsv.envelope.map.v1
format_id: bsv.envelope.map
name: MAP canonical envelope
status: stable
differences:
  - Uses MAP command structure in OP_RETURN payload.
  - Commonly includes app, type, and channel keys.
detectors:
  - detector.map.envelope_prefix.v1
fields:
  - app
  - type
  - channel
  - payload_items
examples:
  - example.mainnet.643055.txid.vout1
```

## `detector` Record Specification

Detectors should be machine-usable and explicit enough to support automated classification.

### Supported Detector Methods

- `asm_pattern`
- `opcode_sequence`
- `envelope_prefix`
- `pushdata_prefix`
- `field_presence`
- `multi_rule`
- `manual`

### Required Fields

- `id`
- `applies_to`
- `method`

### Recommended Fields

- `pattern`
- `normalization`
- `confidence_rules`
- `false_positive_notes`

### Example

```yaml
id: detector.p2pkh.asm_pattern.v1
applies_to: txout
method: asm_pattern
pattern: "OP_DUP OP_HASH160 <20-byte-push> OP_EQUALVERIFY OP_CHECKSIG"
normalization: standard_asm
confidence_rules:
  exact_match: high
false_positive_notes:
  - Non-standard scripts that mimic opcode order may still require manual review.
```

## `field` Definition Specification

Fields should be defined consistently across formats.

### Required Attributes

- `name`
- `type`
- `required`
- `repeated`
- `source`
- `description`

### Recommended Attributes

- `path`
- `normalization`
- `example_values`

### Example

```yaml
name: content_type
type: string
required: false
repeated: false
source: payload
path: envelope.mime_type
description: MIME type declared by the protocol payload.
normalization: lowercase
example_values:
  - text/plain
  - image/png
```

## `example` Record Specification

Examples should be extracted from dataset packs and stored as machine-readable records.

Examples are the bridge between:

- abstract format definitions
- concrete observed chain data

### Required Fields

- `id`
- `network`
- `txid`
- `block_height`
- `scope`
- `format_id`
- `confidence`
- `raw`
- `provenance`

### Recommended Fields

- `block_hash`
- `timestamp`
- `variant_id`
- `decoded`
- `notes`
- `matched_detector_ids`
- `candidate_format_ids`

### Example

```yaml
id: example.mainnet.643055.abcd1234.vout3
network: mainnet
txid: abcd1234...
block_height: 643055
block_hash: 000000...
timestamp: 2025-10-13T06:58:55Z
scope:
  level: output
  index: 3
format_id: bsv.envelope.b
variant_id: bsv.envelope.b.v1
confidence: 0.98
matched_detector_ids:
  - detector.b.envelope_prefix.v1
candidate_format_ids:
  - bsv.envelope.b
raw:
  script_hex: "006a..."
  asm: "OP_0 OP_RETURN ..."
decoded:
  content_type: text/plain
  encoding: utf-8
  body_preview: "hello world"
provenance:
  dataset_pack: mainnet-large-block-demo-643055-index
  extractor_version: 1
notes:
  - Clean canonical example.
```

## `reference` Record Specification

References should distinguish between formal and informal sources.

### Recommended Reference Types

- `normative`
- `informative`
- `internal`

### Example

```yaml
id: ref.tsc.envelope
type: normative
title: Envelope Specification
url: https://tsc.bsvblockchain.org/standards/envelope-specification/
```

## Render Hints

The Data Dictionary should include optional UI metadata to support explorer rendering.

Recommended `render_hints` fields:

- `badge`
- `icon`
- `color_token`
- `summary_template`
- `preferred_label_field`
- `priority`
- `show_in_search`

### Example

```yaml
render_hints:
  badge: MAP
  color_token: cyan
  summary_template: "{app} / {type}"
  preferred_label_field: app
  priority: 70
  show_in_search: true
```

## Storage Model

Use different file formats for:

- hand-authored definitions
- extracted corpora

Recommended:

- YAML for `format`, `variant`, and `detector` definitions
- JSONL or JSONL.zst for extracted `example` corpora

This balances:

- readability
- maintainability
- machine processing

## Directory Layout

Recommended repository structure:

```text
data_dictionary/
  schema/
    format.schema.json
    variant.schema.json
    detector.schema.json
    example.schema.json
  formats/
    locking_scripts/
      p2pkh.yaml
      p2pk.yaml
      multisig.yaml
    op_return/
      envelope.yaml
      map.yaml
      aip.yaml
      b.yaml
    transaction_patterns/
      simple_payment.yaml
      consolidation.yaml
      fan_out.yaml
  examples/
    mainnet/
      000000-199999/
        examples.jsonl
      curated/
        large_blocks.jsonl
        protocol_rich.jsonl
  references/
    sources.yaml
```

## Extraction Integration

Dataset exporters should emit candidate example records using the dictionary shape.

Recommended extracted fields:

- `candidate_format_ids`
- `matched_detector_ids`
- `confidence`
- `decoded_fields`
- `raw script`
- `raw payload excerpt`

This supports a workflow where extracted blockchain data feeds taxonomy development.

## Promotion Workflow

A practical format lifecycle should be:

1. Extract examples from dataset packs.
2. Cluster examples by script or payload shape.
3. Create candidate format definitions.
4. Attach references and field definitions.
5. Promote candidate entries to stable entries.

Recommended promotion thresholds:

- `candidate`
  1-2 examples
- `stable`
  3 or more high-quality examples plus at least one strong reference or internally consistent definition

Do not define a stable format from a single example.

## Initial Coverage Recommendation

The first dictionary coverage should likely focus on five areas:

### 1. Standard Locking Scripts

Examples:

- P2PKH
- P2PK
- multisig variants

### 2. Standard Transaction Patterns

Examples:

- simple payment
- consolidation
- fan-out

### 3. OP_RETURN Envelopes

Examples:

- generic envelope
- MAP
- AIP
- B

### 4. Protocol-Bearing Outputs

Examples:

- token patterns
- NFT patterns
- identity-related outputs

### 5. Large-Block Special Cases

Examples:

- high-throughput batching
- archival writes
- repetitive payload structures common in very large blocks

## Relationship To Dataset Packs

The Data Dictionary and dataset packs should remain distinct.

Dataset packs provide:

- historical scope
- example corpora
- transportable local data

The Data Dictionary provides:

- semantic definitions
- detection rules
- field descriptions
- explorer rendering hints

The connection point is the `example` record.

## Working Thesis

The Bitblocks Data Dictionary should be a versioned, machine-readable, human-maintainable specification for transaction and script formats on Bitcoin SV.

It should:

- define recognizable formats
- explain how they are detected
- describe their fields
- attach real on-chain examples
- support taxonomy work and explorer rendering

That makes it useful as both:

- an internal engineering artifact
- a user-facing knowledge product
