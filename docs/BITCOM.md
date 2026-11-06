# Bitcom registry

Status: current system (#19, #20, #21 in progress — see epic #18).

Bitblocks runs a live instance of unwriter's Bitcom registry.
Spec: [unwriter/Bitcom](https://github.com/unwriter/Bitcom) (`bin/` for the commands, `0.1.0.md` for `cat`, `route`, and bit://).
Bitcom is unwriter's convention (2019); this is an independent implementation, verifiable against the chain.

## Model

Bitcom treats Bitcoin as a Unix computer.
Every address is a user, and a protocol is the address its OP_RETURN data is prefixed with.
A user writes into its own home with `$` commands.
A command speaks for the address that funded the tx (its first input): that is Bitcom's only authentication.

| Command | Namespace | Allowed when |
|---|---|---|
| `$ useradd <address>` | `<address>` | the actor is `<address>` |
| `$ echo <content> to <file>` | actor | always |
| `$ cat bit://<address>/<txid> to <file>` | actor | the source is a `bit://` URI |
| `$ route enable <matcher>` | actor (the admin) | always |
| `$ route add <address> <matcher> <endpoint>` | `<address>` | the actor is not `<address>` (providers add, admins enable) |

A command is a `$` push at the start of an OP_RETURN or right after a `|`, running to the next `|`.

## Storage

`bitcom_commands` is an append-only log, one row per tx output (`Bitblocks.Bitcom.Command`).
Invalid commands are kept with `valid: false` and a `reason`, so the log is complete and rejections are inspectable.
Files and routes are views over the valid rows; the latest write wins, and an unconfirmed write counts as newest.
Non-UTF-8 pushes are stored as `0x<hex>`.

Indexing runs at ingest (`Chain.index_bitcom/1` from `TxIngest`) and in the analyze backfill (`Release.analyze_transactions/1`).
A valid `useradd` also sets `protocols.ownership_proof_txid` (`ProtocolRegistry.prove_ownership/2`).

## Historical discovery (#24)

Ingest only sees txs bitblocks has fetched, so a command in a block the sync hasn't reached is invisible until it gets there.
`Bitblocks.Bitcom.Discovery` reads an address's WhatsOnChain history, a page of 1,000 at a time, fetches the txs we hold no copy of, and logs their commands exactly as ingest would.
Each tx's bytes are hashed against its txid, and a command still speaks for the address that funded its tx.
The block height is WhatsOnChain's word until the sync reaches that block.
It writes `bitcom_commands` only, with no `transactions` row, and ingest later finds the same row and leaves it.

```bash
# Dry run: the first page, nothing written
bin/bitblocks rpc 'Bitblocks.Release.discover_bitcom("<address>") |> IO.inspect()'
# The walk, as Oban jobs on the collections lane: 50 pages at most by default
bin/bitblocks rpc 'Bitblocks.Release.discover_bitcom("<address>", apply: true)'
bin/bitblocks rpc 'Bitblocks.Release.discover_bitcom(:all, apply: true, pages: 5)'
```

## Directory tiers

Tier is derived, never stored:

- **proven**: a valid `$ useradd` from the address.
- **self-described**: the owner wrote at least one file.
- **listed**: known from the registry seed or a protocol handler, with no on-chain word from the owner.

`verification_status` on `protocols` is curation, not proof, and the directory does not use it.
`/protocols` follows the same rule: a protocol reads **Proven** only with an `ownership_proof_txid`, and a seeded `verified` reads **Curated**.
`GET /api/v1/protocols` carries `proven` and `ownership_proof_txid` beside the curation field.
Usage is the count of indexed txs carrying the namespace's protocol tag, capped at 10,000 so the page never scans a whole protocol's history.

## Surfaces

- `/bitcom`: the directory.
- `/bitcom/:address`: a namespace's home (proof, files, routes, recent txs, command log).
- `GET /api/v1/bitcom` and `GET /bitcom.json`: the full export, with every txid needed to re-verify each entry.
- `GET /api/v1/bitcom/:address`: one namespace.
- `GET /api/v1/bitcom/snapshots`: every versioned snapshot, newest first, with its sha256.
- `GET /api/v1/bitcom/snapshots/:version` (or `latest`): one snapshot's exact bytes.
- `GET /api/v1/bit/:address/*path`: resolves `bit://<address>/<path>` to the endpoints providers added for it.
  Endpoints are returned and never fetched, so there is no server-side request to forge.
- `GET /b/:txid`: a B:// file, parsed from its tx on the fly, with the same untrusted-content headers as `/content`.

## Snapshots

`Bitblocks.Bitcom.Snapshots` keeps the registry as versioned files, in the `bitcom_snapshots` table.
A snapshot is canonical JSON: keys sorted, namespaces sorted by address, and no timestamp or usage count, so the same on-chain facts always give the same bytes.
A new version is written only when a fact changed, daily by `Workers.BitcomSnapshotWorker` or by hand with `bin/bitblocks rpc 'Bitblocks.Release.bitcom_snapshot()'`.
The version is the row's id, and the served bytes are the hashed bytes, so `sha256sum` on a download matches the listed hash.
Snapshots read `bitcom_commands` and `protocols`, never `transactions`.

## Waiting on a bitblocks-owned funded address

Both of these are one transaction away, and the code is ready for them.
Choosing and funding the address is Ryan's call, and the wallet signs and broadcasts.

- **Anchor a snapshot.** `$ echo <sha256> to registry.json` from that address, then set `anchor_txid` on the snapshot's row (#21).
  `POST /api/v1/bitcom/compose` builds the unsigned script.
- **Be a route provider.** `$ route add <namespace> /:tx https://bitblocks.app/b/${tx}` from that address (#22).
  A provider can only attach to a route the namespace's admin has enabled, so B:// needs its own admin to run `$ route enable /:tx`.

## Not built yet

- BCat files reassembled and served (#15).
- Discovery of historical commands in blocks bitblocks hasn't fetched (#24).
