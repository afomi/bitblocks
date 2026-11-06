# BAP identities

Who an identity is, read from the chain and not from a wallet (#32).
A read-only index: `Bitblocks.Bap`, filled by the `index_bap` pipeline step.
It stores what each output says once its AIP signature checks, and works out what the records mean when asked, so a change to a rule below needs no re-index.

```text
OP_FALSE OP_RETURN 1BAPSuaPnfGnSBM3GLV9yhxUdYe4vGbdMT
  ID <bap_id> <declared address>    | AIP…
  ALIAS <bap_id> <profile JSON>     | AIP…
  ATTEST <attestation hash> <seq>   | AIP…
  REVOKE <attestation hash> <seq>   | AIP…
```

A BAP ID is `base58(ripemd160(sha256(root address)))`, so it names one root key.
The vectors in `test/support/data/vectors/bap_id_v1.json` are copied unchanged from the wallet project.

## The rules

**Valid.**
A record counts only if its AIP signature checks with `Bitblocks.Aip`, and that signature covers every BAP field of the record.
An AIP that signs chosen field indexes and leaves a BAP field out counts for nothing.
The signed output must also have the shape of its action, with an ID, address or hash that reads as one.

**Accepted.**
A record is valid on its own; whether it is accepted depends on the chain before it.

- The first ID record must be signed by the root: the one key whose address hashes to the BAP ID.
  So nobody can claim an ID but its owner, however early they publish.
- A later ID record is a rotation, accepted if signed by the root or by the address the chain declares at that moment.
- An ALIAS, ATTEST or REVOKE is accepted if signed by the root, or by the address the chain declared when it was published.

A key rotated away can't speak for the identity after that point.
What it signed while it held the key stands.

**Rotation, and why both keys.**
The original BAP spec has the root sign every ID record.
`@1sat/actions` `rotateIdentity`, which Yours publishes with, has the outgoing key sign, and keeps the root key off the wallet's everyday path.
We accept both.
Requiring the root would reject every rotated Yours identity, and requiring the previous key would reject identities following the spec.
Each form is signed by a key the identity already holds, so accepting both lets no stranger in.
The cost is that a stolen current key can rotate.
The root stays able to rotate back, because a root-signed record is always accepted, and that is the same recovery the spec gives.

**Newest.**
Chain order decides: block height, then the tx's byte offset in its block, then txid, then output.
Within one tx an ID comes before anything else, because a wallet's first publish puts an ID and the ALIAS it authorises side by side.
An offset is known once the block's object is stored, and a tx without one sorts after those with one in the same block.
The wallet's `publishedAt` tag isn't on chain, so it plays no part.
The current profile is the newest accepted ALIAS holding a JSON object.
Its image stays as written, an unresolved `1sat://` outpoint.

**The stored chain.**
Only records on the stored chain count: a tx whose block hash is no longer the header at its height is ignored, and height and block are read from the `transactions` row, so a reorg that moves a row moves its records.

**What the answer can't know.**
`first_record` is the earliest accepted record we hold, and `as_of.first_record_final` says whether every block up to it is complete.
Until it is true, an earlier record may still turn up as the sync fills in.

`rejected` lists records that named this identity and weren't accepted, each with its reason.

## Reading it

```
GET /api/v1/bap/:bap_id               — first_record, rotations, current_address, current_profile, rejected, as_of
GET /api/v1/bap/:bap_id/attestations  — what the identity attested, each marked revoked or not
GET /api/v1/bap?address=              — the identities an address signs for, and whether it is their current key
```

Attestations cover what an identity made.
What others attested about it can't be listed: an attestation names only the hash of a claim, and only the claim's holder knows what was hashed.

A read loads at most 1,000 ID records and 100 ALIAS records for an identity.
Anyone can publish a validly signed record naming any BAP ID, so those bounds keep such noise from costing more than a bounded read.

## Coverage

New txs are indexed as they come in, through the pipeline.
Two ways to reach older rows:

```bash
# Rows already stored: run script analysis over the range first; dry run, then apply
bin/bitblocks rpc 'Bitblocks.Release.backfill_bap(600_000, 650_000)'
bin/bitblocks rpc 'Bitblocks.Release.start_backfill("bap", 600_000, 974_000, apply: true)'

# One record in a block the sync hasn't reached: from a txid, checked against its bytes
bin/bitblocks rpc 'Bitblocks.Release.import_bap(["<txid>"])'
```

A txid from any source is only a candidate: its bytes must hash to it, and its record must pass the rules above.

## Not built

- Destroying an identity: `@1sat/actions` has the root key end one, and nothing here reads that yet.
- A real mainnet ID and ALIAS as fixtures: none is held yet, so the tests sign their own records with the vector's script format.
