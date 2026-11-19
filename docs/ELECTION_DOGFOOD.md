# Election dogfood: an election anyone can check

We run a real election on Bitblocks ourselves before we offer one to anyone else.
The first is a board election for the **Public Blockchain Association** (PBA), our fictional seed nonprofit.
The second runs the same flow for **Modular City**, our example city, whose public site is a static Jekyll site on GitHub Pages ([modular-city](https://github.com/civicstudio/modular-city)).

The goal is a result that anyone can check without trusting Bitblocks.
Then the live infrastructure spins down, and the result outlives it as static files.

Epic: https://github.com/afomi/bitblocks/issues/140.
Stories: the secretary https://github.com/afomi/bitblocks/issues/136, a member https://github.com/afomi/bitblocks/issues/137, an observer https://github.com/afomi/bitblocks/issues/138, and the operator https://github.com/afomi/bitblocks/issues/139.

## Who is involved

- **The election administrator** (the PBA secretary, later the Modular City clerk) defines the election, publishes the voter roll, watches the count and publishes the result.
- **A member** (a voter) casts a ballot from a wallet and checks it was counted.
- **An observer** (a member, a journalist, anyone) recounts the result from the archive and the chain alone.
- **The operator** (us) keeps the election's slice of the chain current while it runs, then archives and spins down.

Bitblocks reads and indexes; it never signs or sends a ballot.
Writing a tx is qart's job (the wallet), so a ballot is composed and signed there.

## What goes on chain

Every record is a MAP `SET` signed with AIP, the same shapes `Bitblocks.Aip` already checks and the pipeline already indexes.
`app` is `pba-election` (or `modular-city-election`), so one projection filter finds them all.
The field names below are a draft, to check with the standards steward before the first record is published.

| Record | Signed by | Fields |
|---|---|---|
| Election | the administrator's key | `type=election`, `election` (an id), `title`, `seats`, `candidates` (ids and names), `opens_at_height`, `closes_at_height`, `roll` (the roll record's txid) |
| Roll | the administrator's key | `type=roll`, `election`, and the members as a B:// file (JSON: each member's address or BAP id), with its sha256 |
| Ballot | the member's key | `type=ballot`, `election`, `choices` (candidate ids, at most `seats`) |
| Result | the administrator's key | `type=result`, `election`, `archive_sha256`, `closes_at_height` |

The window is in block heights, not wall-clock time, so anyone can tell from headers alone whether a ballot was in time.

## The counting rule

A ballot counts when all of these hold, and the archive says which one failed when it doesn't:

1. Its AIP signature checks, and the signer is on the roll.
2. It is confirmed in a block from `opens_at_height` to `closes_at_height`, on the chain the headers agree on.
3. It names at most `seats` candidates, all from the election's list.
4. It is the member's latest counted ballot: a member may change their vote until close, and the last one in chain order (height, then position in the block) wins.

This is an open ballot: who voted for whom is public, which suits a membership board vote.
A secret ballot is out of scope for the dogfood.

## The archive

When the window closes, the administrator publishes one archive, a directory of static files:

- `election.json`: the election and roll records, with their txids.
- `ballots.json`: every ballot seen, each with its txid, height, signer, choices, and whether it counted (and if not, which rule it failed).
- `tally.json`: the counts per candidate and the winners.
- `proofs/`: a BUMP (merkle proof) for every record's tx, and the block headers from the election record's block to `closes_at_height`.
- `MANIFEST.sha256`: the sha256 of every file above, whose own sha256 is the `archive_sha256` in the result record.

An observer recounts with the files alone: each tx's bytes against its txid, each BUMP against its header, the headers against each other, and then the counting rule over the ballots.
The archive is published on a static site (for PBA, a page of its own; for Modular City, its GitHub Pages site), so it needs no Bitblocks server to stay up.

## What exists, and what doesn't

Exists:
- AIP checking, MAP parsing and BAP identities (`docs/BAP.md`).
- Projections with hydrate and follow (`docs/MANAGED_SERVICES.md`).
- BEEF and BUMP proofs, BEEF checking, and open headers (`docs/MERKLE_PROOFS.md`, `docs/INTEROP_KIT.md`).
- Verifiable snapshots with a published sha256 (the Bitcom registry, `docs/BITCOM.md`).

Not built:
- **Current data.** Our index stops near block 389,000, and an election happens at the tip.
  The election needs its slice of the chain kept current: each new block read once, keeping only the txs that match its filter (https://github.com/afomi/bitblocks/issues/81, scoped to one projection).
- The count: the election, roll and ballot parsers, and the counting rule as a pure function with test vectors.
- The live election page and its API.
- The archive writer, and a recount tool that reads only the archive.
- Ballot composing in qart.

Needs real hands:
- Funded keys: the administrator's, and a few sats for each test voter.
- A wallet that signs a ballot (qart).

## Order

1. The counting rule and its vectors, offline.
2. The scoped tip lane, so the election's txs arrive as they confirm.
3. The live page and API.
4. The archive and the recount.
5. PBA's election, end to end, with real keys.
6. Modular City's election, published on its site.
