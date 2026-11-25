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

## Composing the records

Built: `/elections/new`, for admins, where the administrator defines an election and sees its two records exactly as they'll be published (https://github.com/afomi/bitblocks/issues/136, steps 1 and 2).
Bitblocks composes and never signs or sends a tx, as the Bitcom composer does (https://github.com/afomi/bitblocks/issues/23).

- **The form** takes the title (`name`), seats (`number_elected`), votes per member (`votes_allowed`, blank for one per seat), the candidates, the roll's addresses and the window as `opens_at_height` and `closes_at_height`.
  It shows today's tip, the height our headers reach (`Sync.tip/0`).
- **About a week** fills in the heights: opening 6 blocks after the tip, about an hour for both records to confirm, and running 1,008 blocks, ten minutes each, both ends counting (`Draft.week_window/1`).
  Under the heights, the page says how many blocks the window is and about how long, always "about", since blocks don't keep time.
- **Candidates** go one per line, as `id: Name`, or the name alone, its id made from it (`Chen Wei` is `chen-wei`).
- **The roll's addresses** go one per line (or apart by commas), each a mainnet P2PKH address; they're sorted, and each kept once.
- **The count's own rules check the form.**
  `Bitblocks.Elections.Draft` reads the text into the shapes `Count.count/4` takes, then puts each part (seats, votes, candidates, the window) to the count on its own, beside known-good values for the rest, so every part that breaks a rule is named at once.
  Each refusal in `Count.refusals/0` has plain words beside its field (`Draft.message/2`), and `test/bitblocks/elections/draft_test.exs` fails if one doesn't.
  The records are taken to confirm no sooner than `tip + 1`, so a window that opens too soon is refused as the count would refuse it.

The records, in order (`Bitblocks.Elections.Compose`):

1. **The roll**, a B:// file `roll.json` (`application/json`) with `type=roll_v1`, and its sha256 over the file's exact bytes.
2. **The election**, which names the roll by outpoint.
   That outpoint isn't known until the roll is broadcast, so the page shows the election as a template until the roll's txid (output 0) or `<txid>.<vout>` is pasted, then checks it with the count once more and builds the record.

For each record the page gives:

- the fields, numbered as AIP numbers them (`0` is `OP_RETURN`);
- the unsigned output script, `OP_FALSE OP_RETURN <fields…>`, as hex;
- the bytes AIP signs as a Bitcoin Signed Message: `0x6a`, every field, then `|`;
- a BRC-100 `createAction` request with the record as output 0, a 0-sat output, and `randomizeOutputs: false`, so the record's outpoint is `<txid>.0`;
- "Sign in your wallet", which copies that request.

AIP signing is the wallet's job.
Before it signs the tx, the wallet appends `| 15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva BITCOIN_ECDSA <address> <signature>` to the output, with the administrator's key and no field indexes, so the signature covers every field.
Both records are signed by the same key, which gathering checks.
A wallet that sends the request unchanged publishes a record without a signature, which isn't counted.

`test/bitblocks/elections/compose_test.exs` composes both records, signs them with a test key as a wallet would, reads them back with `Records` and gets the same election and roll, which the count then takes.
`test/bitblocks_web/live/election_new_live_test.exs` walks the page, and `test/bitblocks_web/election_new_axe_test.exs` checks it with axe at phone width, in light and dark mode.

No qart URL takes a `createAction` request or an election record yet, so the page links none.

## The voting window

Built: `/elections/<outpoint>` opens with one line on the window, from the election's heights and our headers' tip (`Sync.tip/0`, already in the count's coverage), so there is no new chain-tip lookup (https://github.com/afomi/bitblocks/issues/137).

- Before open: "Voting opens at block N (in about X)."
- While open: "Voting closes at block N (about X)."
- After close: "Voting closed at block N."

The state goes by the next block, `tip + 1`, the first block a ballot sent now can be in, and both ends of the window count: upcoming while `tip + 1 < opens_at_height`, open while `tip + 1 <= closes_at_height`, closed after.
The time is the blocks to go times 10 minutes, rounded to minutes, hours or days, and always "about", since blocks don't keep time (`BitblocksWeb.ElectionCount.about/1`).
`GET /api/v1/elections/:outpoint` carries the same `state` (`upcoming | open | closed`) and `tip_height` beside `opens_at_height` and `closes_at_height`.
`test/bitblocks_web/live/election_window_test.exs` covers the states before close and the rounding; `election_live_test.exs` covers the closed state.

## Did my ballot count?

Built: on `/elections/<outpoint>`, a member enters a ballot's txid or their address, and `GET /api/v1/elections/:outpoint/ballots/:query` gives the same answer as JSON (https://github.com/afomi/bitblocks/issues/137).
Both read the count the page already shows (`BitblocksWeb.ElectionCount.lookup/2`), so there is no second rule.

- **A txid** gives that ballot's status in the count's own words, and the rule's reason in a sentence with the heights it was judged against.
- **An address** gives its ballots in chain order, which one counts, and whether the address is on the roll.
- **"Counted"** appears only for a ballot the count counted, which is in a block inside the window, and links its merkle proof and its block's header, both open.
  The proof is the one gathering built, climbed from the txid to the merkle root of the header we hold at that height.
- **"Not counted: this key isn't on the roll."** names the roll's txid.
- **"Not counted: confirmed after block N."** and **"Replaced by a later ballot."** (with the later ballot's txid) come straight from the rules `after_close` and `replaced`.
- **"Waiting for a block."** covers a ballot a reorg left unconfirmed, a tx we hold in no block, and a txid we don't hold at all.
  For the last, it says what we can't see: "This transaction is not in our index yet; our index reaches block N."
  No answer asks WhatsOnChain.
- A stored tx that holds no ballot for this election is "Not a ballot in this count."
- Anything that is neither a txid nor a P2PKH address asks for one, and marks the field invalid.

Every answer says the block it is current to, and sits in a polite live region, so a screen reader hears it without moving focus.
`test/bitblocks_web/live/election_live_test.exs` covers each answer and the API; `test/bitblocks_web/election_ballot_axe_test.exs` checks the answer with axe at phone width, in light and dark mode.

## The archive

Built: `Bitblocks.Elections.Archive`.
When `closes_at_height` is 6 blocks deep and our index covers every block through it, the administrator builds one archive, a directory of static files.
Until then it is refused, naming how many blocks remain (`{:too_shallow, %{blocks_remaining: n}}`), or how far the index reaches (`{:not_covered, …}`).

| File | What it holds |
|---|---|
| `archive.json` | The index: the election's outpoint, `app`, the administrator's address, the roll's outpoint and sha256, the window, `close_block_hash`, the headers' range, the recount tool and its guide (`recount`), and every record in chain order (`kind`, `txid`, `vout`, `height`, `position`, `block_hash`, `signer`, and its `tx` and `proof` files) |
| `count.json` | `input`, exactly what `count/4` was given (`election`, `roll`, `ballots`, `close_block_hash`), and `result`, what it returned |
| `roll.json` | The roll file, its exact bytes on chain |
| `headers.bin` | One 80-byte block header per height, from the roll's block (at or below the election's) to `closes_at_height + 6`, in height order |
| `txs/<txid>.bin` | Each record tx's raw bytes: the roll, the election and every ballot gathered |
| `proofs/<txid>.bump` | Each confirmed record's BUMP (BRC-74); a ballot a reorg left unconfirmed has none |
| `MANIFEST.sha256` | `sha256sum` lines (`<hex>  <path>`) for every file above, sorted by path |

`archive_sha256`, which the result record carries, is the sha256 of `MANIFEST.sha256`.
The same chain gives byte-identical files: nothing in the archive reads a clock, and every JSON file is written with its keys sorted, two-space indent and a closing newline (`Archive.json/1`).
Every ballot gathered sits at or below `closes_at_height + 6`, so its header is in `headers.bin`.

### Beside the manifest

Three more files sit in the archive's folder, outside the hashed set, and `archive.json` names them under `beside`:

| File | What it is |
|---|---|
| `index.html` | The archive page, made from the archive's own `count.json` bytes (`Bitblocks.Elections.ArchivePage`) |
| `recount.py` | A copy of the recount tool, byte for byte the one at `/elections/recount.py` |
| `recount.html` | A copy of its guide |

The manifest covers the evidence; these are what a reader opens and runs.
`index.html` shows `archive_sha256`, and that hash is taken over the manifest, so the page can't be listed in it.
The tool and guide are kept out too, so a fix to the tool never changes the hash of an archive already built, or of one built again later.
A reader checks the copies against the published ones, or reads `recount.py` before running it; what the recount prints, not the page, is the result.
The recount checks only the files the manifest lists, so the three beside it never fail it.

### The archive page

`index.html` is one self-contained page, HTML and CSS only, with no script and nothing fetched, so it works from a folder on a laptop or from any static host, and stays up when Bitblocks is down (https://github.com/afomi/bitblocks/issues/138).
It shows the election's name, the winners, the tally (each candidate's votes, and whether elected), how many ballots counted, `archive_sha256`, the closing block's hash, and the result record's txid, or "Result record not published yet".
"Recount it yourself" links `recount.html` and `recount.py` beside it, and gives the command to run from inside the folder, `python3 -I recount.py . --archive-sha256 <archive_sha256>` (`-I`, so Python loads nothing else from the folder).
It follows DESIGN.md's light look with the guide's colours, and reads no clock, so the same archive gives the same page.

The result record carries `archive_sha256`, so it can only be published after the archive is built.
Building again with the result record's txid (`result_txid:`, or the field on the page) changes `index.html` only; `archive_sha256` and every file in the manifest stay the same.

### Build the archive

Built: on `/elections/<outpoint>`, admins get "The archive" (https://github.com/afomi/bitblocks/issues/136, step 5; `BitblocksWeb.ElectionArchive`).

- **Until it can be built**, the button is disabled, with `Archive.plan/2`'s refusal in a sentence: "Builds once block N is 6 deep: X blocks to go.", or how far the index reaches.
  There is no second rule: the page asks `plan/2`.
- **Once it can**, "Build the archive" runs `Archive.build/3` into a fresh temporary directory, reads each file back against its sha256, and lists every file with its size and sha256, the three beside the manifest apart, and `archive_sha256`.
  The directory is removed after.
- **"Download the archive (.zip)"** is `GET /elections/<outpoint>/archive.zip?sha256=<archive_sha256>`, admins only.
  It builds again (the same chain gives the same files) and zips every file in the manifest and the three beside it, under one folder `election-<txid>-<vout>/`, each entry dated 1980-01-01, so the same archive gives the same zip, byte for byte (`Archive.zip/1`).
  When the archive now hashes to something other than the `sha256` shown (a reorg can do that), it answers a 409 saying so, never a different zip; a refusal is a 409 with the same sentence as the page.
- **Bounded**: each build runs under `:election_archive_timeout_ms` (20 seconds), and a timeout or failure is a sentence on the page.
  An election's archive is a few dozen small files and builds in well under a second, so it needs no job queue.

Unzipped, the folder is ready to publish as static files: for PBA, a page of its own; for Modular City, its GitHub Pages site.

`test/bitblocks/elections/archive_test.exs` covers the page against `count.json`, the files beside the manifest, the result txid leaving `archive_sha256` alone, and the zip's contents and bytes.
`test/bitblocks/elections/recount_test.exs` unzips the download and runs the copy of `recount.py` inside it.
`test/bitblocks_web/live/election_archive_live_test.exs` covers the button before and after six deep, the file list, the download and its refusals, the page's tally against the archive's, and the admin gate; `test/bitblocks_web/election_archive_axe_test.exs` checks each state with axe at phone width, in light and dark mode.

An observer recounts with the files alone, offline (https://github.com/afomi/bitblocks/issues/138); the recount tool below does each step:

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

## The recount

Built: [`recount.py`](https://bitblocks.app/elections/recount.py), one Python 3 file with the standard library only (a small secp256k1 checks the AIP signatures), and its guide for a non-developer, [`/elections/recount.html`](https://bitblocks.app/elections/recount.html).
Both are static files in `priv/static/elections/`, so an administrator can copy them beside the archive and they outlive our servers.
Python, because it is already on every Mac and Linux machine and a free install on Windows, and a single readable file is something an observer can check before running.

```bash
python3 recount.py pba-2026 --archive-sha256 <archive_sha256 from the result record>
python3 recount.py pba-2026 --result-tx result.hex      # the result record's tx, raw or hex: its signature, archive_sha256 and close_block_hash too
python3 recount.py --self-test election_count_v0.json   # the counting rule's vectors
```

It makes no network calls, and runs the five steps above in order, then compares the tally and winners with `count.json` and the result record.
The records are re-read from the tx bytes, with the same parsing and AIP rules as `Bitblocks.Elections.Records`, and the count's input is rebuilt from them, never taken from `count.json`.
A signature checks as a wallet makes it: the key recovered from it, compressed or not as its header byte says, must hash to the signer's address, over the Bitcoin Signed Message digest.
For a message of exactly 253 bytes both tools also take bsv-ex's digest, which frames that length as one byte rather than `fd fd 00`, so a record signed with `BSV.Message` still counts (`Bitblocks.Aip`, `test/bitblocks/aip_test.exs`).
It prints every ballot as counted or with the rule it failed, the tally and the winners, then "Matches the published result", and exits 0.
When a check fails it names each file or tx, prints no tally and exits 1; a usage mistake exits 2.
It prints the hash of the closing block and of the archive's last block, so the observer can tie the headers to the real chain on any explorer or node, and it says so when the headers' targets are easier than mainnet allows (a test chain).

What a recount can't show: a ballot left out of the archive (anyone with the chain can look for more), or who holds a key on the roll.

`test/bitblocks/elections/recount_test.exs` builds an archive from the fixtures and runs the tool on it: a good archive matches, and a changed byte, a missing proof, a broken header chain and a changed tally each fail with the file or tx named.
It also runs `--self-test` on `election_count_v0.json`, so the tool and `Count` can't drift; CI installs Python for it, and it is skipped where `python3` isn't on PATH.

## What exists, and what doesn't

Exists:
- AIP checking, MAP parsing and BAP identities (`docs/BAP.md`).
- Projections with hydrate and follow (`docs/MANAGED_SERVICES.md`).
- BEEF and BUMP proofs, BEEF checking, and open headers (`docs/MERKLE_PROOFS.md`, `docs/INTEROP_KIT.md`).
- Verifiable snapshots with a published sha256 (the Bitcom registry, `docs/BITCOM.md`).
- **Current data**, built and dormant: our index stops near block 389,000, and an election happens at the tip, so a tip lane keeps the election projection's slice current, each new block read once and only the matching txs (and spends of their outputs) kept (https://github.com/afomi/bitblocks/issues/139, `Bitblocks.TipLane`, `docs/SYNCING.md`).
  It runs once an operator starts it with `Release.start_tip_lane/2`.
- The record parsers, gathering from our index, the live count and the archive writer, CLI and context only (above).
- The read-only live page and open API: `/elections`, `/elections/<outpoint>` and `GET /api/v1/elections/:outpoint`, both from `Elections.gather/2` then `Elections.count/1`.
- "Did my ballot count?" on the election's page, and `GET /api/v1/elections/:outpoint/ballots/:query`, from the same count (above).
  Bitblocks still does not sign or send a ballot.
- The recount tool and its guide, static files at `/elections/recount.py` and `/elections/recount.html` (above).

- `/elections/new`, which composes the roll and election records, unsigned, with a `createAction` request for each (above).
- "Build the archive" on the election's page, for admins, with the zip download and the static archive page inside it (above).

Not built:
- A wallet that adds the AIP signature to a `createAction` output, and a qart URL to open a request in.
- "Published" on `/elections/new`, with both txids, once the wallet sends them.
- The result record's composer, and "Closed" on `/elections/<outpoint>`, linking the published archive and the result txid.
- Ballot composing in qart.

Needs real hands:
- Funded keys: the administrator's, and a few sats for each test voter.
- A wallet that signs a ballot (qart).

## Order

1. The counting rule and its vectors, offline (built).
2. The scoped tip lane, so the election's txs arrive as they confirm (built, dormant).
3. The record parsers, the live count and the archive, from the CLI (built).
4. The live page and API, read side only (built).
5. The recount (built).
6. PBA's election, end to end, with real keys.
7. Modular City's election, published on its site.
