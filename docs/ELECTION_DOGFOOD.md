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

Built: `Bitblocks.Elections.Count.count/4`, a pure function (`lib/bitblocks/elections/count.ex`).
It takes the election record, the roll and every ballot seen, and reads no database, chain or clock.
The live page, the archive writer and a third-party recount all call it, or match it, on the same input.

Each ballot comes to it as `txid`, `election`, `height`, `position`, `signer` and `choices`.
`height` is null while the ballot is unconfirmed, or after a reorg removes its block.
`position` is its index in the block.
`signer` is the key whose AIP signature checked, or null when none did; checking the signature, the tx bytes and the proofs happens before the count.

A ballot counts when it passes every rule below.
When it doesn't, it is listed against the first rule it fails, in this order:

| # | Rule | Fails when |
|---|---|---|
| 1 | `other_election` | it names a different election |
| 2 | `no_signature` | no AIP signature checked |
| 3 | `not_on_roll` | its signer isn't on the roll |
| 4 | `unconfirmed` | it isn't in a block |
| 5 | `before_open`, `after_close` | its block is outside `opens_at_height` to `closes_at_height`; both ends count |
| 6 | `malformed_choices` | `choices` isn't a list of strings |
| 7 | `too_many_choices` | it names more than `seats` candidates |
| 8 | `duplicate_choice` | it names one candidate twice |
| 9 | `unknown_candidate` | it names an id not on the election's list |
| 10 | `replaced` | the same signer has a later ballot, in chain order, that passed rules 1 to 9 |

Chain order is height, then position in the block.
A member may change their vote until close, and their latest ballot that passes rules 1 to 9 is the one that counts.
A ballot that fails a rule never replaces an earlier one, so a late or mistaken ballot can't undo a good one.
An empty ballot passes, votes for no one, and so withdraws a member's earlier votes.

The tally gives one vote to each candidate a counted ballot names, listed in the election's order with zeros included.
The winners are the candidates with at least one vote, most votes first, up to `seats`; a seat no one has a vote for stays empty.
Candidates tied above the last seat all win, listed in the election's order.

**Ties for the last seats go by lot from the closing block.**
The tied candidates are ordered by `sha256("<close_block_hash>:<candidate id>")` as lowercase hex, lowest first, where `close_block_hash` is the hash of the block at `closes_at_height` in lowercase hex, as explorers show it.
No one knows that hash while voting is open, so no one can steer the lot, and anyone can check it from the headers.
Until that block exists, the count reports those seats as `undecided`, with the tied candidates.

This is an open ballot: who voted for whom is public, which suits a membership board vote.
A secret ballot is out of scope for the dogfood.

The count refuses an input that can't be a real election, rather than judging it: seats below one, duplicate candidate ids, a window that closes before it opens, the same txid twice, or two ballots at one height and position.

### The test vectors

The rule's vectors are published at [`GET /interop/elections/count/v1.json`](https://bitblocks.app/interop/elections/count/v1.json), open to anyone with no key, alongside the interop vectors (`docs/INTEROP_KIT.md`).
The file is `priv/data/interop/election_count_v1.json`, with its expected outcomes written by hand.
`test/bitblocks/elections/count_test.exs` runs every vector through `Count`, and checks that the file names every rule the code applies and that each rule has a vector, so the file can't drift from the code.

Each vector gives `id`, `description`, `input` (`election`, `roll`, `ballots`, and `close_block_hash` when the vector needs it) and `expected`.
`expected` is each ballot's `txid`, `counted`, `rule` and `replaced_by`, then `counted`, `not_counted`, `tally`, `winners` and `undecided`; or, for an input to refuse, `error`.
The file's header explains every field and rule, so a recount (https://github.com/afomi/bitblocks/issues/138) can be written against it without reading our code.
Within v1, a vector's id, input and expected outcome stay as they are, except to correct a mistake; new vectors raise the minor version, and a change to the rule gets a new file.

The record field names the vectors use are the same draft as the table above.

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
- The election, roll and ballot parsers (the counting rule and its vectors are built, above).
- The live election page and its API.
- The archive writer, and a recount tool that reads only the archive.
- Ballot composing in qart.

Needs real hands:
- Funded keys: the administrator's, and a few sats for each test voter.
- A wallet that signs a ballot (qart).

## Order

1. The counting rule and its vectors, offline (built).
2. The scoped tip lane, so the election's txs arrive as they confirm.
3. The live page and API.
4. The archive and the recount.
5. PBA's election, end to end, with real keys.
6. Modular City's election, published on its site.
