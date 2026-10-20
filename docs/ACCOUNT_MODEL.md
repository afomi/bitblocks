# Account Model on BSV — Design Draft

Status: design & vision (aspirational).
Nothing in this doc is implemented unless it names an existing endpoint or module.

The idea: use BSV's restored script capabilities (and sCrypt where it helps) to offer an **account-based model and interface** on top of the UTXO ledger.
UTXO management is a real friction point for users and developers — wallet infrastructure, coin selection, change handling, key rotation.
It is also a deliberate feature: the whitepaper (§10, Privacy) recommends a new keypair per transaction precisely so ownership is not linkable.
This draft treats that tension as a design input, not a bug to paper over.

## Why

1. **Unlock new capabilities** — persistent contract state, balances with transfer semantics, nonces, and event streams enable application patterns that raw UTXOs make awkward.
2. **Meet Ethereum developers where they are** — millions of developers think in accounts, balances, nonces, contract storage, and events. A faithful account interface over BSV lowers their switching cost to nearly zero.
3. **Second-order implications** — fee sponsorship, account abstraction, and an indexer-native "state read" API fall out of the design almost for free (detailed below).

## The core insight: two layers, not one

An "account model" can live at two different layers, and they compose.

### Layer 1 — Account as a *view* (indexer-level, no consensus change)

Ethereum's account state is itself derived — nodes fold transactions into a state trie.
Bitblocks can do the same fold over UTXOs and present accounts as a read-side abstraction.
No script tricks required; this is pure indexing.

Bitblocks already has most of the ingredients:

- `GET /api/v1/script/:scripthash/history` and `/unspent` — per-script history and UTXO set (an account's ledger and balance, keyed by script instead of address).
- `GET /api/v1/tokens/:id/holders` — this is *literally* an account-balance view already, derived from BSV-20 transfer UTXOs.
- SSE streams (`/api/v1/stream/*`) — the event-log analog.
- Metanet DAG traversal — chain-of-outpoints traversal, the same shape as walking a contract's state thread.

Layer 1 gives Ethereum-style *reads* (`getBalance`, `getTransactionCount`, `getLogs`) without touching consensus.
The trade-off: nothing on-chain *enforces* account semantics — the view is honest only if the indexer is.
Mitigation: every account fact is backed by outpoints, and outpoints are backed by merkle proofs (`/api/v1/txs/:txid/proof`), so the view is auditable via SPV.

### Layer 2 — Account as a *contract* (on-chain enforced, sCrypt territory)

BSV's restored opcodes (OP_CAT, OP_SPLIT, big-number arithmetic) plus the removal of script size limits make **stateful covenants** practical.
The key technique is OP_PUSH_TX (a sighash-preimage trick, provided as a library by sCrypt): the locking script inspects the transaction that spends it and can therefore constrain its own successor output.
`OP_PUSH_TX.md` explains the technique in depth, with diagrams.

That turns a chain of UTXOs into a state machine:

```
TX_0: output 0 → [contract code | state_0]
TX_1: spends TX_0_0, forced to create → [contract code | state_1]
TX_2: spends TX_1_0, forced to create → [contract code | state_2]
```

The contract is an **account**: one live outpoint at any time, carrying its current state, with transitions enforced by script rather than by an indexer's goodwill.
See `COMPOSABLE_PRIMITIVES.md` (covenant pattern) and `VALIDATION_ORACLES.md` (off-chain validation with on-chain signature checks) — this doc is the account-shaped application of both.

For accounts holding *many* balances (an ERC-20-style token contract), the state cannot be a flat map in the output.
The known sCrypt pattern: store a **merkle root** of the balance map in the state; a spender supplies the leaf and proof in the unlocking script; the covenant verifies the proof, applies the delta, and enforces the new root in the successor output.
State stays O(32 bytes) on-chain regardless of account count.

## What the interface looks like

An Ethereum-to-BSV mapping, so the target DX is concrete:

| Ethereum concept | BSV realization | Layer |
|---|---|---|
| Address / EOA | pubkey, script hash, or paymail | 1 |
| `eth_getBalance` | sum of unspent outputs for a script | 1 |
| Nonce / `getTransactionCount` | monotonic counter in contract state (replay protection) | 2 |
| Contract storage | state field in the covenant output (or merkle root of it) | 2 |
| Contract call | spend of the contract UTXO with method args in unlocking script | 2 |
| Events / logs | OP_RETURN outputs in the state-transition tx, indexed and streamed | 1 over 2 |
| `eth_getLogs` / subscriptions | protocol feed + SSE endpoints | 1 |
| Gas paid by sender | anyone can add fee inputs — sponsorship is *native* | — |

Proposed read API (Layer 1, additive to the existing surface):

```
GET /api/v1/accounts/:id            — balance, utxo count, first/last seen, contract state if Layer 2
GET /api/v1/accounts/:id/history    — folded ledger (debits/credits, not raw outpoints)
GET /api/v1/accounts/:id/state      — current state thread head (Layer 2 accounts)
GET /api/v1/accounts/:id/state/at/:height — historical state (time travel — Ethereum archive nodes charge for this; we get it free from the chain)
GET /api/v1/stream/accounts/:id     — SSE of state transitions / balance changes
```

`:id` resolves like `get_block!/1` does today — accept pubkey hash, scripthash, or a contract's origin outpoint (`txid_vout`), the natural "account address" for Layer 2.
The origin outpoint as account identifier follows the same convention as BSV-20 token ids (`OUTPOINT.md`).

## Implications (the inklings, spelled out)

**Fee sponsorship / meta-transactions come free.**
In Ethereum, account abstraction (ERC-4337) exists largely so someone else can pay gas.
In BSV, a transaction's inputs need not come from the "actor" — a sponsor adds a fee input and the user's signature only covers their own input.
The account interface should expose this as a first-class flow instead of rediscovering it later.

**Account abstraction is just script.**
Multi-sig, social recovery, spending limits, session keys — on Ethereum these need contract wallets and a new mempool.
Here the account contract's method table *is* the validation logic; sCrypt expresses each as a public method.

**Serialization is the real cost.**
UTXOs are parallel by construction; a Layer 2 account is a single spendable outpoint, so all writers contend on it.
This reintroduces exactly the global-state bottleneck the UTXO model avoids — plus a front-running surface, since anyone who can satisfy the covenant races to spend the state head.
Mitigations: shard one logical account across N state UTXOs; or route writes through a sequencer (a qart-side ordering service) while reads stay trustless.
This trade-off should be stated honestly in any developer-facing docs: accounts where coordination is needed, UTXOs where parallelism is needed, in the same transaction when useful.

**Privacy inverts.**
The whitepaper's per-transaction keys make ownership unlinkable; a persistent account is *deliberately* linkable.
That is often the point (a token contract, an order book, a public registry wants continuity), but the interface should make the choice explicit: ephemeral keys remain the default for payments, accounts are opted into for state.
`PROVENANCE.md` covers the same pseudonymity trade-offs from the attribution angle.

**Reorgs need a story.**
Ethereum clients re-derive state on reorg; our Layer 1 fold must do the same (re-fold from the fork point), and Layer 2 state heads can be orphaned.
The sync pipeline's fork tracking is the hook; account views must be reorg-aware from day one, not patched later.

**The indexer becomes the RPC node.**
Ethereum developers do not run tries by hand — they call JSON-RPC on a node or Infura.
Bitblocks in this design *is* the Infura-equivalent for BSV accounts, which aligns with the paid-API direction (`PAYMENT_CHANNELS.md`, `CUSTOM_INDEXING.md`).

## Where sCrypt fits (and where it doesn't)

- **Not needed for Layer 1.** Pure Elixir indexing.
- **Needed for Layer 2 contract authoring.** sCrypt (scrypt-ts) compiles TypeScript-ish contracts to script and ships the OP_PUSH_TX preimage machinery, stateful-contract base classes, and merkle-tree state helpers — reimplementing that in raw script is possible but not a good use of time.
- **Boundary:** contract *authoring, composing, and signing* is write-side and belongs in qart; bitblocks *indexes* contract state threads, verifies transitions, and serves reads.
This mirrors the existing split (qart writes, bitblocks reads) and the DEX decision (index here, sign there).

## Phasing sketch

1. **Account read API (Layer 1).** `accounts/:id` + `history` folded from existing scripthash and token infrastructure. Smallest step, immediately useful to Ethereum-minded developers, zero consensus novelty.
2. **Account entity in the explorer UI.** An account page: balance over time, ledger view, linked outpoints. The explorer stops being only block/tx-centric (`NEXT_GEN_BLOCK_EXPLORER.md` argues for exactly this entity-centric shift).
3. **State-thread indexing (Layer 2 read side).** Detect covenant state chains (origin outpoint → successive spends), store the thread, serve `state` and `state/at/:height`. Reuses the Metanet traversal shape.
4. **Reference account contract (Layer 2 write side, in qart).** One sCrypt stateful contract — a counter or a minimal balance-map token — deployed on testnet, with bitblocks indexing its thread end-to-end. This is the round-trip proof.

Each phase is independently shippable and each earlier phase is useful without the later ones.

## Open questions

- Account identifier canonical form: scripthash (Electrum convention, already served) vs origin outpoint vs paymail — probably "accept all, canonicalize to one."
- How much state verification does the indexer do on Layer 2 threads — full covenant re-execution, or trust-the-chain (miners already validated the script)?
- Sharded accounts: is N-way state sharding a contract-level pattern (sCrypt) or an indexer-level aggregation (bitblocks), or both?
- Does the order book (`ORDER_BOOK_PROTOCOL.md`) migrate to account-style listings, or stay pure-UTXO with an account *view* over sellers?
