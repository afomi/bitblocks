# Data Management Considerations

This document outlines a practical strategy for working with Bitcoin SV chain data when a full local chain download is not realistic on available hardware.

At current chain size, a Bitblocks development workflow should not assume a full archival node plus full historical app sync on every machine. Instead, the application should support importable chain datasets with explicit scope, fidelity, and purpose.

## Problem Framing

There are several distinct needs:

- local development needs fast, reproducible data
- UI and design work need realistic blocks and transactions without multi-day sync times
- debugging and research need known historical periods and special-case blocks
- experiments need small, portable datasets that can be reloaded repeatedly

These needs should not all be served by a single giant database dump or by standard Phoenix seed data.

## Recommendation

Use a `tiered dataset pack` model instead of:

- one monolithic snapshot
- ad hoc fixture exports
- overloading `priv/repo/seeds.exs`

The core idea is to create versioned, importable chain packs that contain bounded slices of data with clear provenance and import semantics.

## Dataset Types

Bitblocks should likely support several dataset categories.

### 1. Header Baseline Packs

Broad coverage with minimal data, for example:

- block headers
- block hashes
- heights
- timestamps
- transaction counts
- sizes

Example scope:

- `0..600_000` as `headers_only`

This gives the application chronological coverage without requiring full transaction storage for the entire range.

### 2. Full Range Packs

Chronological ranges with fuller data, for example:

- `0..99_999`
- `100_000..199_999`
- `200_000..299_999`

These are useful for:

- reproducible local development
- deterministic UI work
- focused historical exploration

### 3. Event Packs

Curated slices for special periods or behaviors, such as:

- large blocks
- protocol-heavy periods
- stress-test eras
- fork or reorg scenarios
- OP_RETURN-rich blocks

These are often more useful than arbitrary height windows for product work.

### 4. Single-Block Cassettes

Special-case blocks for demos, rendering work, or debugging pathological behavior.

Examples:

- one extremely large block
- one protocol-dense block
- one interesting historical block with unusual structure

## Range Design

Chronological windows like:

- `0..99_999`
- `100_000..199_999`
- `200_000..299_999`

are a good starting point because they are:

- easy to reason about
- easy to name
- easy to import independently
- easy to resume after interruption

For filenames and manifests, ranges should be represented consistently.

Recommended naming:

- `mainnet-000000-099999-full`
- `mainnet-100000-199999-full`
- `mainnet-500000-599999-headers`

Avoid inconsistent labels like `100000-200k`, which become awkward in code, manifests, and tooling.

## Fidelity Levels

Not all datasets should store the same depth of information.

Bitblocks should likely support at least three fidelity levels.

### `headers_only`

Contains:

- header fields
- hash references
- timestamps
- block sizes
- transaction counts

Useful for:

- broad chain coverage
- navigation and timeline views
- lightweight historical baselines

### `index_only`

Contains:

- block metadata
- transaction IDs
- minimal transaction metadata

Useful for:

- explorer indexing
- search
- block-level transaction browsing
- later large-block handling

### `full`

Contains:

- block metadata
- raw transaction hex
- parsed transaction fields
- optional derived protocol analysis

Useful for:

- transaction detail pages
- protocol analysis
- realistic local demos
- data-intensive debugging

This mixed-fidelity approach is more realistic than trying to make all historical ranges fully complete.

## Why Not Use Standard Seeds

This should not be treated as normal Phoenix seed data.

`priv/repo/seeds.exs` is appropriate for:

- small bootstrap records
- tiny reference data
- environment setup

It is not the right abstraction for:

- large chain imports
- resumable historical datasets
- versioned data cartridges
- partial sync replay

These imports need their own workflow and tooling.

## Why Not Use One Giant Database Dump

A database dump is tempting, but it has drawbacks:

- tightly coupled to one schema version
- tightly coupled to one Postgres version and restore workflow
- harder to inspect or partially import
- awkward to diff or transform as the app evolves

Database snapshots may still be useful operationally, but they should not be the primary portability format.

## Why Not Use Raw RPC Cassettes As The Main Format

Raw RPC captures are valuable for tests, but they are a poor primary format for app bootstrapping.

They are generally:

- too verbose
- too coupled to node responses
- less stable as the application evolves
- less useful for partial import workflows

Raw RPC cassettes are better treated as test fixtures than as shared data distribution artifacts.

## Preferred Artifact Shape

The most practical long-term format is an app-native dataset pack.

A pack should likely contain:

- `manifest.json`
- `blocks.jsonl.zst`
- `transactions.jsonl.zst`
- `README.md`

Possible future additions:

- `protocols.jsonl.zst`
- `state_diffs.jsonl.zst`
- `checksums.txt`

Recommended default compression:

- `zstd`

This is preferable to uncompressed JSON and usually preferable to gzip for large archival-style artifacts.

## Manifest Requirements

Each dataset pack should include enough metadata to validate and understand it before import.

Suggested manifest fields:

- dataset name
- network
- height range
- first block hash
- last block hash
- block count
- transaction count
- compressed size
- uncompressed size
- extraction date
- source node identity or notes
- schema version
- fidelity level
- import mode

This makes packs inspectable, comparable, and safer to automate.

## Import Requirements

Import tooling should support:

- importing a single pack
- importing multiple packs from a directory
- resumable imports
- idempotent upserts
- validation before import
- checksum verification
- schema compatibility checks

This matters more than trying to build the cleverest extraction format.

## Practical Strategy For Early Bitblocks

A reasonable first operational strategy would be:

- `0..300_000` as `full` packs if storage allows
- `300_000..600_000` as `headers_only` or `index_only` packs first
- curated event packs for later large-block eras
- single-block cassettes for especially large or interesting blocks

This avoids pretending that all history should be ingested the same way.

## Naming Model

It is useful to think of these artifacts as `chain cartridges`, not seeds.

Each cartridge should encode:

- scope
- fidelity
- purpose

Examples:

- `mainnet-000000-099999-full`
- `mainnet-300000-399999-index`
- `mainnet-500000-599999-headers`
- `mainnet-large-block-demo-643055-index`

This naming discipline will make future tooling much simpler.

## Main Tradeoff

The key product decision is what these packs are optimized for.

Possible priorities:

- exact replay of raw node data
- application bootstrapping
- frontend demos
- testing
- archival preservation

The best initial target for Bitblocks is likely:

- application bootstrapping
- frontend demos

That implies a format that is:

- normalized enough to import quickly
- complete enough to drive the UI
- portable enough to share
- not necessarily a perfect archival mirror of every raw RPC response

## Working Thesis

Bitblocks should use versioned, importable dataset packs with multiple fidelity levels and both chronological and curated slices.

That approach is more flexible and more sustainable than:

- downloading the full chain everywhere
- relying on a single giant snapshot
- treating historical imports as ordinary seed data
