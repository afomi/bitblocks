# Bitcoin node modes

A protocol reference for operators and for anyone reading `/status`.
Bitblocks is an indexer beside a node.
It is not itself a node.
The node software this project talks to is Bitcoin SV node.
Where a behavior belongs only to Bitcoin Core, the section says so.

"Fully synced" and "pruned" answer different questions.
A node can be both at once.
A node can be either one alone.

Source for the SV node prune rules: the Blocks page in the BSV node FAQ (`-prune`, the 288-block floor, `txindex` since 1.1.1).

## Fully synced is a place on the tip

Fully synced means this process has validated the same best chain the network is building on now.
`getblockchaininfo` is the report.

`blocks` is the height of the most-work chain this node has fully validated.
`headers` is how many headers it has checked.
`verificationprogress` is an estimate from 0 to 1 of how far validation has gotten.
`initialblockdownload` is true while the node is still catching up from genesis or from a long stall.
`pruned` is whether old block files are allowed to disappear.

`/status` paints "Fully Synced" when `blocks` equals `headers`.
That comparison is the node catching its own header tip.
The controller also reads `pruned` and the template does not show it.
A pruned node at the tip and an archival node at the tip look the same on that screen.

Initial block download is the walk to that tip.
The SV node documentation is explicit that the walk is the proof.
The node downloads and validates every block from the genesis block that BSV shares with Bitcoin.
That work includes the transactions inside the blocks.
The walk can take days.
It cannot be skipped on SV node.
An archival node and a pruned node both do this walk.
The difference shows up after a block has been validated, when the software decides whether to keep the bytes.

## Archival

Archival is the default.
Pruning is off (`-prune=0`, or the option left unset).

The node keeps every block file from genesis.
It keeps the UTXO set: the outputs that are still spendable.
It can answer `getblock` for any height it has validated.
With `txindex=1` it can answer `getrawtransaction` for any transaction in those blocks.
Without `txindex`, a historical transaction lookup fails even though the block file is on disk.
The index is a map from txid to location.
The block file is the body.
You need the map to find an arbitrary body by id.

This is the node an explorer, an Electrum-style index, or Bitblocks can backfill from.
Mining templates also want this kind of node once it is at the tip, because `getblocktemplate` needs a validated chain and a mempool.
See `MINING.md`.

Disk is the whole chain.
On BSV that is the large ongoing cost, because block bodies are the data.

## Pruned

A pruned node validates the same way.
After validation it deletes old block files and tries to stay under a size target.

SV node's settings:

- `-prune=0` leaves pruning off.
- `-prune=1` allows manual pruning through the `pruneblockchain` RPC.
- `-prune=<n>` automatically deletes block files to stay under `n` megabytes.

The node keeps at least 288 blocks no matter what target you set.
There is no recommended `n`.
Operators should assume a single block can exceed 4 GB when they pick `n`.
The 288-block floor wins over a small target, so a few hundred multi-gigabyte blocks are still a large disk.
"Pruned" on BSV is not a laptop mode.

`getblock` and `getdata` fail for a block that has been deleted.
The error is an open failure on a block file the node no longer has.
Since SV node 1.1.1, `txindex=1` is allowed together with prune.
A lookup whose block file is gone returns "transaction cannot be found."
The index does not resurrect bytes that were deleted.

What a pruned node still has:

- The header chain.
- The UTXO set, so it can validate new spends.
- The recent block files, at least the last 288.
- A mempool, if it is participating in transaction relay.

What it no longer has is the historical body of the chain.
It already checked those bodies once.
It cannot show them to you again, and it cannot hand them to a peer.

A fully synced pruned node is a real full node that has reached the tip and then forgotten the old files.
It is a finished validator with a short memory.

## Other variants

These are real, and they are not points on a single slider between archival and pruned.

**Still downloading.**
Headers can run ahead of fully validated blocks.
`verificationprogress` below 1, or `initialblockdownload` true, means the node has not finished the walk.
RPC that assumes a complete chain will lie or fail in this window.
Bitblocks tip sync reads `getblockchaininfo` through a cache, so "caught up" on our side can lag the node.
See `SYNCING.md`.

**Manual pruning.**
`-prune=1` does not delete on a timer.
The operator calls `pruneblockchain` and chooses a height.
The 288-block floor still applies.
This is the same retention idea as automatic prune, with a person holding the knife.

**Transaction index.**
`txindex` is not a sync mode.
It is an extra map on whatever blocks are still stored.
On an archival node it makes arbitrary historical transactions addressable.
On a pruned SV node (1.1.1 and later) the map may outlive the body, and the call still fails when the body is gone.
Bitcoin Core has historically refused to combine `txindex` with prune.
A Core change to allow the combination was still a proposal in late 2026.
Do not copy Core advice onto an SV node, or the reverse.

**Blocks-only, and not listening.**
`blocksonly` asks the node to skip loose transaction relay and still validate blocks in full.
A non-listening node makes outbound connections and does not accept inbound ones.
Both can be archival or pruned, and both can be fully synced.
They change who the node talks to.
They do not change how much of the chain it checks.

**Mining.**
A mining node is a fully synced node that builds templates from its mempool and calls `submitblock` when a hasher finds a header.
The template job needs the tip and the mempool.
It does not need every historical block file to stay on disk.
A pruned node at the tip can do this job inside its retained window.
Backfill of old transactions cannot.
`MINING.md` covers the split between the node and the hasher.

**Script-check shortcuts in other software.**
Bitcoin Core can start with `-assumevalid`, skipping script checks below a trusted block while still checking proof of work, structure, and the UTXO accounting along that chain.
Core's assumeutxo loads a UTXO snapshot and validates the historical blocks in the background.
Until that background pass finishes, the node is serving on a trust assumption about the snapshot.
The SV node FAQ says the initial download cannot be cut short.
Treat those two flags as Core behavior unless you have confirmed them on the binary you actually run.

**SPV.**
Simplified payment verification keeps headers and checks a Merkle branch for a transaction it cares about.
It does not run the scripts of the chain.
It does not hold the UTXO set.
Whitepaper §8 is the spec.
`SPV_TUTORIAL.md` is the local walkthrough.
An SPV client can be "caught up" on headers in the same sense a full node is caught up on blocks.
It has not become a full node by catching up.

**Whitepaper §7 is a third design.**
Section 7, "Reclaiming Disk Space," sketches dropping spent transactions inside a block's Merkle tree and keeping the branch hashes so the header still commits to them.
That is not what today's pruned node does.
A pruned node deletes entire old block files after full validation and keeps the UTXO set in a separate database.
Section 7 is closer to "keep a proof, drop the spent body."
Modern prune is "check everything, then drop the file."

**Compact-filter light clients.**
BIP 157 and BIP 158 let a client download a filter per block and request a full block only when the filter hits.
This is a Bitcoin Core ecosystem technique (Neutrino is the well-known client).
The client still does not execute every transaction on the chain.
It is a privacy-minded cousin of SPV, not a pruned full node.

**Trusting an API.**
A wallet that calls an indexer and believes the JSON has not run a node mode at all.
SPV applies when the client recomputes the Merkle root against headers it checked itself.
`SPV_TUTORIAL.md` draws that line.

**An indexer beside the node.**
Bitblocks copies headers and, later, raw transactions into Postgres.
Its own sync states (`header_only` through `completed`) describe that copy.
They do not describe the node's prune flag.
A pruned node will serve the tip and then fail `getblock` for a height below its prune floor.
Backfill of history needs an archival node, or some other store that still has the bodies.
`DATA_MANAGEMENT_CONSIDERATIONS.md` is the local note on not putting a full archival chain on every machine.

**A cluster-shaped full node.**
Teranode is a BSV node built as separate services for validation and storage, aimed at very large blocks.
It is still a full validator.
It is not a prune setting and it is not an SPV client.
Running it is a deployment choice about how one full node is split across machines.

**Network name.**
`main`, `test`, and regtest are which chain you joined.
`/status` shows main versus test.
That choice does not say whether the node is archival, pruned, or caught up.

## Is there a spectrum?

Yes.
It is four axes, and a node picks a position on each.

| Axis | One end | The other end |
| --- | --- | --- |
| Caught up | Initial block download. Headers may be ahead of validated blocks. | `blocks` equals `headers`. Validation progress is essentially 1. |
| What it checked | A trusted API response. Then SPV, which checks inclusion. Then compact filters, which still skip most scripts. | Every transaction from genesis, scripts included. Core's assumevalid and assumeutxo sit in between, and only while their shortcut applies. |
| What it kept | A prune window: at least the last 288 blocks, older files deleted. | Every block file. `txindex` adds a map. An external index (Electrum server, Bitblocks) adds another copy. |
| What it will serve | Blocks-only, or not listening, or a pruned RPC that errors on old heights. | Historical blocks and arbitrary transactions, to peers and to RPC callers. |

The corners matter more than a blended score.

- Archival and fully synced: checked everything, kept everything, can serve history.
- Pruned and fully synced: checked everything, kept the tip and the UTXO set, serves new blocks, refuses old bodies.
- Archival and still downloading: will be able to serve history, and is not ready for templates or a complete backfill.
- SPV and caught up on headers: small disk, inclusion proofs, no claim that every script in the chain was run.
- Pruned is not "a little bit SPV." The validation already happened. The files did not stay.

Whitepaper §7, Core prune, and SV node `-prune` are three different answers to "must I keep the old bytes?"
Only the last one is a setting on the node Bitblocks calls.
Fully synced is never that setting.
It is whether the walk from genesis has reached the tip you intend to trust.
