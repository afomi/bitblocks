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
The AIP signature must cover every MAP field of the record, as `docs/BAP.md` already requires for BAP: an AIP that signs chosen field indexes and leaves a MAP field out counts for nothing.

`app` is `pba-election` for now, pending Ryan's choice of one app name for the format.
It is one line to change: `config :bitblocks, :election_app` in `config/config.exs`, which `Bitblocks.Elections.Records.app/0` reads.
The aim is one `app` for the format, with the tenant told apart by the administrator's key and the election's outpoint, so one projection filter finds every election.

The field names follow Open Civic Data and NIST SP 1500-100 where they overlap: `name`, `number_elected` and `votes_allowed`.
They stay a draft until the first record is published.

### Encoding

- A list (`choices`, `candidates`) is one JSON array in a single MAP value.
  MAP can't carry a list by repeating a key: `Bitblocks.MapParser` keeps only the last value of a repeated key.
- An integer (`number_elected`, `votes_allowed`, every `*_at_height`) is decimal ASCII with no leading zeros, so `1000`, never `01000` or `1e3`.
- A candidate id is one or more of `a-z`, `0-9` and `-`, so it reads the same in a ballot, a URL and the lot.
- An election is named by its record's outpoint, `<txid>.<vout>`, the txid as lowercase hex in display order.
  The election record carries no id of its own; a reader takes it from where the record sits, and hands it to the count as `election`.
  Ballots and the result name that outpoint in `election`.
- A block hash is lowercase hex in RPC and display order (as `getblockhash` and explorers show it), the reverse of the header's internal byte order.

### Records

Each record's `type` carries its version, so a later format can sit beside this one.

| Record | Signed by | Fields |
|---|---|---|
| Roll | the administrator's key | a JSON B:// file, `{"members": [...]}`, sorted and unique, with `type=roll_v1` in the same output; it names no election |
| Election | the administrator's key | `type=election_v1`, `name`, `number_elected`, `votes_allowed` (optional, defaults to `number_elected`), `candidates` (a JSON array of `{"id", "name"}`), `opens_at_height`, `closes_at_height`, `roll` (the roll's outpoint), `roll_sha256` (over the roll's exact bytes on chain) |
| Ballot | the member's key | `type=ballot_v1`, `election` (the election's outpoint), `choices` (a JSON array of candidate ids, at most `votes_allowed`) |
| Result | the administrator's key | `type=result_v1`, `election`, `archive_sha256`, `closes_at_height`, `close_block_hash` |

The roll comes first, so the election can name it by outpoint and hash, and the roll never needs to name the election.
`roll` is the outpoint of the output that holds the B:// file, and `roll_sha256` is the sha256 of the file's bytes exactly as they are on chain.
The election record and the roll must both confirm below `opens_at_height`, so the rules are fixed before the first ballot can count.

The window is in block heights, not wall-clock time, so anyone can tell from headers alone whether a ballot was in time.

### Who is on the roll

A member is a P2PKH address, written exactly as the AIP section writes it, and compared as an exact string.
A compressed and an uncompressed public key give different addresses for the same private key, so the roll lists the form the member's wallet signs with.
A BAP id is not on the counting path.
Where a member is known by a BAP id, the administrator resolves it to the address when the roll is published, and keeps the BAP id only as a note beside the roll.

## The counting rule

Built: `Bitblocks.Elections.Count.count/4`, a pure function (`lib/bitblocks/elections/count.ex`).
It takes the election record, the roll and every ballot seen, and reads no database, chain or clock.
The live page, the archive writer and a third-party recount all call it, or match it, on the same input.

Each ballot comes to it as `txid`, `election`, `height`, `position`, `signer` and `choices`.
`height` is null while the ballot is unconfirmed, or after a reorg removes its block.
`position` is the tx's index in its block, with the coinbase at 0, the same as its leaf offset in the BUMP.
`signer` is the address whose AIP signature checked, or null when none did; checking the signature, the tx bytes, the roll file against `roll_sha256` and the proofs happens before the count.
The election and the roll may carry `height`, the block each confirmed in; when they do, the count holds it below `opens_at_height`.

A ballot counts when it passes every rule below.
When it doesn't, it is listed against the first rule it fails, in this order:

| # | Rule | Fails when |
|---|---|---|
| 1 | `other_election` | it names a different election |
| 2 | `no_signature` | no AIP signature checked |
| 3 | `not_on_roll` | its signer isn't on the roll |
| 4 | `unconfirmed` | it isn't in a block |
| 5 | `before_open` | its block is below `opens_at_height` |
| 6 | `after_close` | its block is above `closes_at_height`; both ends of the window count |
| 7 | `malformed_choices` | `choices` isn't a list of strings |
| 8 | `too_many_choices` | it names more than `votes_allowed` candidates |
| 9 | `duplicate_choice` | it names one candidate twice |
| 10 | `unknown_candidate` | it names an id not on the election's list |
| 11 | `replaced` | the same signer has a later ballot, in chain order, that passed rules 1 to 10 |

Chain order is height, then position in the block.
A member may change their vote until close, and their latest ballot that passes rules 1 to 10 is the one that counts.
A ballot that fails a rule never replaces an earlier one, so a late or mistaken ballot can't undo a good one.
An empty ballot passes, votes for no one, and so withdraws a member's earlier votes.

The tally gives one vote to each candidate a counted ballot names, listed in the election's order with zeros included.
The winners are the candidates with at least one vote, most votes first, up to `number_elected`; a seat no one has a vote for stays empty.
Candidates tied above the last seat all win, listed in the election's order.

**Ties for the last seats go by lot from the closing block.**
The tied candidates are ordered by `sha256("<close_block_hash>:<candidate id>")` as lowercase hex, lowest first.
`close_block_hash` is the hash of the block at `closes_at_height`, as lowercase hex in RPC and display order, the reverse of the header's internal byte order.
No one knows that hash while voting is open, so no one can steer the lot, and anyone can check it from the headers.
Until that block exists, the count reports those seats as `undecided`, with the tied candidates.
The result record carries `close_block_hash`, so a reader sees the lot's input without looking it up.

This is an open ballot: who voted for whom is public, which suits a membership board vote.
A secret ballot is out of scope for the dogfood.

The count refuses an input that can't be a real election, rather than judging it (`Count.refusals/0` lists each refusal):
an election id or roll that isn't an outpoint, a `roll_sha256` that isn't 64 lowercase hex characters, `number_elected` or `votes_allowed` below one, a candidate id outside `a-z`, `0-9` and `-`, duplicate candidate ids, heights that aren't integers, a window that closes before it opens, an election or roll that confirmed at or above `opens_at_height`, a roll whose members aren't strings, sorted and each once, a ballot without a txid or with a bad height or position, the same txid twice, or two ballots at one height and position.

### The test vectors

The rule's vectors are published at [`GET /interop/elections/count/v0.json`](https://bitblocks.app/interop/elections/count/v0.json), open to anyone with no key, alongside the interop vectors (`docs/INTEROP_KIT.md`).
The file is `priv/data/interop/election_count_v0.json`, with its expected outcomes written by hand.
`test/bitblocks/elections/count_test.exs` runs every vector through `Count`, and checks that the file names every rule the code applies, in the code's order (`rule_order`), that each rule has a vector, and that each refusal has a vector, so the file can't drift from the code.

Each vector gives `id`, `description`, `input` (`election`, `roll`, `ballots`, and `close_block_hash` when the vector needs it) and `expected`.
`expected` is each ballot's `txid`, `counted`, `rule` and `replaced_by`, then `counted`, `not_counted`, `tally`, `winners` and `undecided`; or, for an input to refuse, `error` and `error_detail`.
The file's header explains every field, rule and record, so a recount (https://github.com/afomi/bitblocks/issues/138) can be written against it without reading our code.
Its `claim` says what the count takes as given: that each signer's AIP signature checked and covers every MAP field, that the roll matches its hash, and that each height is on the chain the headers agree on.

The file is v0, a draft, until the first election record is published on chain: nothing consumes it yet, so a vector may still change.
Then a v1 file freezes the inputs: within v1 a vector's id, input and expected outcome stay as they are, except to correct a mistake; new vectors raise the minor version; and a change to the rule gets a new file.

The licence is given as an SPDX id with its URL, as the other vector files give theirs: `MIT`, as the repository.
MIT or CC0 for the vectors is pending Ryan.

## Reading the records

Built: `Bitblocks.Elections.Records` reads a record from a tx's raw bytes into the shape `count/4` takes, and `Bitblocks.Elections` gathers and counts an election from our index.
Bitblocks reads only: nothing here signs or sends.

- **One output, one record.**
  A data output carries an optional B:// file, then the MAP `SET`, then the AIP section, apart by `|`.
  The signature counts only when it checks and covers every field of the B and MAP segments; for the roll, that includes the file.
  Parsing is strict about the encoding (a key given twice, a leading zero or a list that isn't one JSON array is refused, with the field named) and leaves the election's own rules to the count, which refuses those with its reasons.
  An election, roll or result without a signature that counts is no record; a ballot without one is still a ballot, with `signer` null, so the count lists it as `no_signature`.
- **Gathering.**
  `Elections.gather/2` reads the election by its outpoint, the roll by the outpoint the election names, and the ballots among the stored txs tagged `MAP` (the `protocols` GIN column), or matching a projection's filter when one is given, from the election's block to `closes_at_height + 6`.
  Every query is bounded: by txid, or by tag and height in keyset pages, up to `:election_max_scanned` rows (50,000), past which it refuses rather than count part of the chain.
  It checks each tx's bytes against its txid, the roll's bytes against `roll_sha256`, and that the roll is signed by the election's key.
  A record's height is its block's when our headers hold that block at that height, and null otherwise (a reorg moved it); its `position` is its index in the block, read from its merkle proof.
- **Coverage.**
  What a count can see is what our index holds, so every answer says how far that reaches: `complete_through`, and, with `projection:`, how far its tip lane has read (`tip_lane_through_height`).
  Ballots are read only from blocks the index covers.
- **The live count.**
  `Elections.count_now/2` is `gather/2`, then `count/4`, with `current_to` (the block the count is current to) and `final` (the index covers `closes_at_height + 6`).
  Once we hold the block at `closes_at_height`, its hash goes to the count as `close_block_hash`, for a tie by lot.

```bash
bin/bitblocks rpc 'Bitblocks.Release.election_count("<txid>.0") |> IO.inspect(limit: :infinity)'
bin/bitblocks rpc 'Bitblocks.Release.election_count("<txid>.0", projection: 1) |> IO.inspect(limit: :infinity)'
```

## The archive

Built: `Bitblocks.Elections.Archive`.
When `closes_at_height` is 6 blocks deep and our index covers every block through it, the administrator builds one archive, a directory of static files.
Until then it is refused, naming how many blocks remain (`{:too_shallow, %{blocks_remaining: n}}`), or how far the index reaches (`{:not_covered, …}`).

| File | What it holds |
|---|---|
| `archive.json` | The index: the election's outpoint, `app`, the administrator's address, the roll's outpoint and sha256, the window, `close_block_hash`, the headers' range, and every record in chain order (`kind`, `txid`, `vout`, `height`, `position`, `block_hash`, `signer`, and its `tx` and `proof` files) |
| `count.json` | `input`, exactly what `count/4` was given (`election`, `roll`, `ballots`, `close_block_hash`), and `result`, what it returned |
| `roll.json` | The roll file, its exact bytes on chain |
| `headers.bin` | One 80-byte block header per height, from the roll's block (at or below the election's) to `closes_at_height + 6`, in height order |
| `txs/<txid>.bin` | Each record tx's raw bytes: the roll, the election and every ballot gathered |
| `proofs/<txid>.bump` | Each confirmed record's BUMP (BRC-74); a ballot a reorg left unconfirmed has none |
| `MANIFEST.sha256` | `sha256sum` lines (`<hex>  <path>`) for every file above, sorted by path |

`archive_sha256`, which the result record carries, is the sha256 of `MANIFEST.sha256`.
The same chain gives byte-identical files: nothing in the archive reads a clock, and every JSON file is written with its keys sorted, two-space indent and a closing newline (`Archive.json/1`).
Every ballot gathered sits at or below `closes_at_height + 6`, so its header is in `headers.bin`.

An observer recounts with the files alone, offline (https://github.com/afomi/bitblocks/issues/138, not built):

1. `sha256sum -c MANIFEST.sha256`, and the manifest's own sha256 against the result record.
2. Each header in `headers.bin` hashes below its own target and names the one before it.
3. Each `txs/<txid>.bin` hashes to its txid, and its BUMP climbs from that txid, at the offset given as its `position`, to the merkle root of the header at the BUMP's height.
4. Each record re-read from its tx's output `vout`, with its AIP signature over every field, gives the `input` in `count.json`, and `roll.json` hashes to `roll_sha256`.
5. The counting rule over that input gives `result`.

The archive is published on a static site (for PBA, a page of its own; for Modular City, its GitHub Pages site), so it needs no Bitblocks server to stay up.

```bash
bin/bitblocks rpc 'Bitblocks.Release.build_election_archive("<txid>.0", "/tmp/pba-2026") |> IO.inspect()'               # dry run: each file's path, size and sha256, and archive_sha256
bin/bitblocks rpc 'Bitblocks.Release.build_election_archive("<txid>.0", "/tmp/pba-2026", apply: true) |> IO.inspect()'  # write, and read each file back
```

## What exists, and what doesn't

Exists:
- AIP checking, MAP parsing and BAP identities (`docs/BAP.md`).
- Projections with hydrate and follow (`docs/MANAGED_SERVICES.md`).
- BEEF and BUMP proofs, BEEF checking, and open headers (`docs/MERKLE_PROOFS.md`, `docs/INTEROP_KIT.md`).
- Verifiable snapshots with a published sha256 (the Bitcom registry, `docs/BITCOM.md`).
- **Current data**, built and dormant: our index stops near block 389,000, and an election happens at the tip, so a tip lane keeps the election projection's slice current, each new block read once and only the matching txs (and spends of their outputs) kept (https://github.com/afomi/bitblocks/issues/139, `Bitblocks.TipLane`, `docs/SYNCING.md`).
  It runs once an operator starts it with `Release.start_tip_lane/2`.
- The record parsers, gathering from our index, the live count and the archive writer, CLI and context only (above).

Not built:
- The live election page and its API.
- A recount tool that reads only the archive.
- Ballot composing in qart.

Needs real hands:
- Funded keys: the administrator's, and a few sats for each test voter.
- A wallet that signs a ballot (qart).

## Order

1. The counting rule and its vectors, offline (built).
2. The scoped tip lane, so the election's txs arrive as they confirm (built, dormant).
3. The record parsers, the live count and the archive, from the CLI (built).
4. The live page and API.
5. The recount.
6. PBA's election, end to end, with real keys.
7. Modular City's election, published on its site.
