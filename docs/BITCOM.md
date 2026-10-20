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

## Directory tiers

Tier is derived, never stored:

- **proven**: a valid `$ useradd` from the address.
- **self-described**: the owner wrote at least one file.
- **listed**: known from the registry seed or a protocol handler, with no on-chain word from the owner.

`verification_status` on `protocols` is curation, not proof, and the directory does not use it.
Usage is the count of indexed txs carrying the namespace's protocol tag, capped at 10,000 so the page never scans a whole protocol's history.

## Surfaces

- `/bitcom`: the directory.
- `/bitcom/:address`: a namespace's home (proof, files, routes, recent txs, command log).
- `GET /api/v1/bitcom` and `GET /bitcom.json`: the full export, with every txid needed to re-verify each entry.
- `GET /api/v1/bitcom/:address`: one namespace.

## Not built yet

- bit:// resolution and bitblocks as a route provider (#22).
- Command composer that hands unsigned commands to qart (#23).
- Discovery of historical commands in blocks bitblocks hasn't fetched (#24).
- On-chain anchoring of export snapshots (#21).
