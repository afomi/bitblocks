# Outpoint

An **outpoint** is a reference to a specific output of a previous transaction.
It is the fundamental pointer used by Bitcoin transaction inputs to identify which coins they are spending.

## Format

```
<txid>_<vout>
```

- `txid` — the 64-character hex transaction ID of the transaction containing the output
- `vout` — the zero-based integer index of the output within that transaction

## Example

```
4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b_0
```

This refers to output index `0` of the genesis coinbase transaction.

## How It Works

Every transaction input (except a coinbase) must reference an outpoint.
The outpoint tells the network: "I am spending output N from transaction X."
The network looks up that output, checks that it is unspent, and verifies that the unlocking script in this input satisfies the locking script on that output.

```
Transaction A                      Transaction B
─────────────────────              ─────────────────────
output 0: 1.0 BSV  ──outpoint──▶  input 0: spends A_0
output 1: 0.5 BSV
```

## Separator Convention

The canonical Bitcoin serialization uses a colon (`:`) internally.
For this application and its APIs, outpoints are written with an underscore (`_`) as the separator:

```
<txid>_<vout>
```

This avoids ambiguity in URLs and makes the format safe for use as a key in query strings, filenames, and identifiers.

## In the Explorer

On `/transactions/:id`, each input displays its outpoint under **Previous Output (UTXO being spent)**.
The txid portion links to the source transaction.
The vout index identifies which specific output of that transaction is being consumed.

## Relation to UTXO Set

An outpoint that has not yet been spent is part of the **UTXO set** (Unspent Transaction Output set).
Spending an outpoint removes it from the UTXO set.
The UTXO set represents the complete current state of who owns what on the chain.
