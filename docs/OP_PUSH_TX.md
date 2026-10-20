# OP_PUSH_TX — How a Locking Script Sees Its Own Spend

Audience: developers and designers, intermediate level.
You should know what a transaction, an input, an output, and a locking/unlocking script are (`OUTPOINT.md` covers the pointer format).
No prior covenant or sCrypt experience assumed.

OP_PUSH_TX is not an opcode.
It is a *technique* — a way of arranging standard script operations so that the transaction being validated appears on the stack as data the script can inspect.
Once a script can read the transaction that is spending it, it can *constrain* that transaction: "you may spend me, but only into an output that looks like X."
That single capability is what turns Bitcoin outputs into state machines, and it is the foundation of the Layer 2 account contracts in `ACCOUNT_MODEL.md`.

## 1. The problem: script is blind

Bitcoin script is a validation language, not a query language.
When a node runs a locking script, the script sees only what the unlocking script pushed onto the stack — a signature, a public key, maybe some data.
It cannot ask "where is this money going?"
It has no built-in view of the outputs of the spending transaction.

```
              spending transaction
  ┌───────────────────────────────────────────┐
  │  input 0 ──── unlocking script            │
  │                   │                       │
  │                   ▼                       │
  │            locking script (me)            │
  │            sees: the stack. only.         │
  │                                           │
  │  output 0 ── ???   ┐                      │
  │  output 1 ── ???   ├─ invisible to me     │
  │  output 2 ── ???   ┘                      │
  └───────────────────────────────────────────┘
```

So a plain output can decide *who* may spend it (whoever produces a valid signature), but never *what happens next*.
Money, once unlocked, is unconstrained.
For payments this is fine.
For contracts that must persist state — a counter, a token balance sheet, an order book entry — it is fatal: state lives in an output, and without output constraints, the first spender could simply discard the state.

## 2. The loophole: OP_CHECKSIG already knows the transaction

There is exactly one place where standard script touches the spending transaction: **OP_CHECKSIG**.
To verify a signature, the node serializes a digest of the spending transaction — the **sighash preimage** — hashes it, and checks the signature against that hash.

So the node *has* the transaction data during validation.
It just never hands it to the script.

OP_PUSH_TX makes the spender hand it over instead:

1. The **unlocking script pushes the full sighash preimage** as a data blob.
2. The **locking script verifies that blob is genuine** — that it really is the preimage of the transaction being validated, not a fabrication.
3. With authenticity established, the script **parses the blob** and enforces whatever rules it likes on the fields inside.

Step 2 is the clever part, and the reason this works at all.

## 3. The verification trick

How can a script check that a supplied blob matches the *actual* spending transaction, when the script cannot see the actual transaction?
It recruits OP_CHECKSIG as an equality oracle.

The locking script, using a keypair that is fixed and publicly known (secrecy is not the point here):

1. Double-SHA256 the supplied preimage blob to get a digest.
2. **Compute an ECDSA signature over that digest, inside the script**, using the known private key and a fixed nonce — with the nonce fixed, the signature reduces to modular arithmetic (`s = k⁻¹(hash + r·d)`), which BSV's big-number opcodes (restored multiplication, split, mod) can evaluate directly.
3. Push that computed signature and the known public key to **OP_CHECKSIG**.

Now the two sides meet:

```
   spender (unlocking script)              node (consensus rules)
   ───────────────────────────             ──────────────────────
   pushes CLAIMED preimage                 serializes the ACTUAL
        │                                  spending transaction
        ▼                                       │
   hash256(claimed) ── digest                   ▼
        │                                  hash256(actual) ── digest
        ▼                                       │
   sign digest IN SCRIPT                        │
   (known key, fixed nonce)                     │
        │                                       │
        ▼                                       ▼
   signature ─────────────► OP_CHECKSIG ◄── actual digest
                                 │
                                 ▼
                    passes ⟺ claimed == actual
```

- The script's signature was derived from the **claimed** preimage (the blob the spender pushed).
- OP_CHECKSIG independently derives the sighash from the **actual** transaction being validated.

If the blob is genuine, the signature verifies.
If the spender pushed a doctored preimage — say, one advertising outputs that don't exist — the signature was computed over the wrong digest and OP_CHECKSIG fails, rejecting the spend.
The spender cannot lie about the transaction they are broadcasting.

There are edge cases (digest values that fall outside valid signature ranges, the low-S rule), conventionally handled by grinding a transaction field like `nLockTime` until the digest is well-formed.
sCrypt's `Tx.checkPreimage` / `checkPreimageOpt` wrap the whole ritual, edge cases included — in practice you call one function and receive an authenticated preimage.
This is what "provided as a library by sCrypt" means: the technique is plain script, but nobody should hand-roll it.

## 4. What's in the preimage (the fields are the API)

Once verified, the preimage is a struct the script can OP_SPLIT apart.
BSV uses the BIP-143-style serialization, so the fields sit at predictable offsets:

| # | Field | What a covenant does with it |
|---|-------|------------------------------|
| 1 | `nVersion` | rarely used |
| 2 | `hashPrevouts` | detect which other inputs are present |
| 3 | `hashSequence` | rarely used |
| 4 | `outpoint` | learn *own* identity — the txid/vout being spent |
| 5 | `scriptCode` | read *own* locking script — the key to carrying state (§5) |
| 6 | `value` | learn own satoshi amount; enforce conservation |
| 7 | `nSequence` | relative timelock rules |
| 8 | **`hashOutputs`** | **the workhorse: constrain the successor outputs** |
| 9 | `nLocktime` | absolute timelock rules |
| 10 | `sighash type` | assert which flags the spender used |

The pattern for constraining the future is always the same:
the script *builds the outputs it demands* (as serialized bytes), hashes them, and asserts equality with `hashOutputs`.
The spending transaction must therefore contain exactly those outputs, or validation fails.

The choice of sighash flags matters.
`SIGHASH_ALL` commits to every output — total control, no room for the spender to add change.
`SIGHASH_SINGLE` commits only to the output at the same index as the input — the covenant controls its own successor and ignores the rest, which is friendlier for composing with fee inputs and change (and is why fee sponsorship composes naturally, per `ACCOUNT_MODEL.md`).
`ANYONECANPAY` frees the other *inputs*, letting a sponsor attach fees without invalidating anything.

## 5. From inspection to state: the covenant loop

Constraining outputs enables the signature move of stateful BSV contracts.
Convention: a contract output's script is laid out as `[code | state]` — an immutable code section followed by a data section holding current state.

A state transition then works like this:

1. The unlocking script pushes the verified preimage plus the "method arguments" (e.g. `increment`, or `transfer 5 to Bob` with a merkle proof).
2. The script reads its **own current script** from `scriptCode` and splits it into `code` and `state`.
3. It applies the transition rules to compute `state'`.
4. It serializes the demanded successor output: same `code`, new `state'`, appropriate satoshi value.
5. It hashes that and asserts equality with `hashOutputs`.

```
   my own script (from scriptCode)        successor output I demand
   ┌────────────────┬───────────┐         ┌────────────────┬───────────┐
   │      code      │  state n  │         │      code      │ state n+1 │
   └────────────────┴───────────┘         └────────────────┴───────────┘
            │             │                        ▲             ▲
            │             └── apply transition ────│─────────────┘
            └────────── copied unchanged ──────────┘
                                                   │
                                        serialize + hash256
                                                   │
                                                   ▼
                            assert == hashOutputs (from preimage)
```

The transaction is only valid if it re-creates the contract with correctly updated state.
Spend after spend, this produces a **state thread** — a chain of outpoints where each is the enforced successor of the last:

```
origin: TX_0 out 0   [code | count = 0]
          │  spend (increment)
TX_1 out 0           [code | count = 1]
          │  spend (increment)
TX_2 out 0           [code | count = 2]   ← current head (the only live UTXO)
```

The head is the account's current state; the thread is its audit log; the origin outpoint is its permanent identifier.
This is the structure bitblocks would index for Layer 2 accounts (`ACCOUNT_MODEL.md`, phasing step 3).

In sCrypt the entire section above collapses to a few lines:

```ts
export class Counter extends SmartContract {
  @prop(true)                    // "true" marks this property as mutable state
  count: bigint

  @method()
  public increment() {
    this.count++
    // demand a successor output: same code, new state, same value
    const output: ByteString = this.buildStateOutput(this.ctx.utxo.value)
    assert(this.ctx.hashOutputs == hash256(output), 'state not preserved')
  }
}
```

`this.ctx` *is* the verified sighash preimage — the compiler injects the whole OP_PUSH_TX ritual behind that property.

## 6. For designers: the mental model and its UX consequences

The one-sentence model: **a lock that inspects the outgoing truck, not just the key.**
An ordinary lock checks credentials and swings open.
A covenant lock checks credentials *and* the manifest of the transaction leaving with the goods — wrong manifest, door stays shut.

What this does to the experience surface:

**Contracts are threads, not balances.**
The natural visualization of a stateful contract is a vertical chain — origin at top, head at bottom, one card per transition showing what changed.
Bitblocks' Metanet explorer already renders parent/child outpoint graphs; a state thread is the single-file special case.

**There is exactly one head, and people race for it.**
Only the current head UTXO is spendable; every writer targets it simultaneously.
If two users act at once, one transaction confirms and the other becomes invalid — not queued, not merged, *rejected*, because it spends an outpoint that no longer exists.

```
                     head: TX_2 out 0
                    ┌────────┴────────┐
             Alice spends it    Bob spends it
                    │                 │
                    ▼                 ▼
              TX_3 confirms     ✗ rejected — TX_2 out 0
              (new head)          no longer exists
```
Design for this: optimistic UI with a clear "superseded — retry against new state" recovery, not a generic error toast.
(The mitigation strategies — sharding, sequencers — live in `ACCOUNT_MODEL.md`.)

**Failure happens at the door, with a reason.**
A covenant rejection means the proposed transition violated a rule the contract enforces.
That is a *legible* failure — "transfer exceeds balance," "state not preserved" — and the UI should surface the rule, not a hex error.
Contract methods and their assertions are effectively the product's validation copy.

**Wallets must be told what to build.**
A standard wallet cannot spend a covenant output; it doesn't know it must reproduce the successor output the script will demand.
Spending requires contract-aware construction — predicting the required outputs and embedding the preimage — which in this ecosystem is qart's job (compose/sign) while bitblocks serves the reads.
Design implication: "your balance" and "what you can do with it" come from different subsystems, and flows should not pretend a generic Send button will work on contract UTXOs.

**Fees can be someone else's problem.**
Because a sponsor can attach a fee input without touching the contract input, "the app pays the fees" is a native pattern, not a workaround.
Onboarding flows can and should hide fee mechanics entirely.

## 7. Costs and constraints (the honest section)

**The preimage contains the script, and the script processes the preimage.**
`scriptCode` is the *entire current locking script*, so a contract with a large script gets a large preimage, and the unlocking data grows with it.
Naive designs go quadratic; the standard mitigations are keeping state tiny (32-byte merkle roots instead of full maps, per `ACCOUNT_MODEL.md`), the optimized `checkPreimageOpt` variants, and hash-referencing bulky code (`REUSABLE_SCRIPTS.md`).

**Bigger scripts, bigger fees — but BSV-scale.**
A covenant spend carries the preimage plus proofs plus computed outputs; hundreds of bytes to a few kilobytes where a P2PKH spend is ~107 bytes.
At BSV fee rates this is fractions of a cent, but it is not free, and it compounds on high-frequency threads.

**The covenant only rules its own successor.**
A covenant constrains the spending transaction — it cannot reach further into the future than the outputs it demands, so every generation of the contract must re-impose the rules (which the `[code | state]` convention does automatically).
And it cannot see anything *outside* the transaction: no price feeds, no clocks beyond locktime, no other UTXOs' contents.
External facts enter only as signed attestations checked in-script — the oracle pattern (`VALIDATION_ORACLES.md`).

**Authorization is separate from validity.**
A covenant that only checks state transitions is *anyone-can-advance* — sometimes desirable (anyone may crank a public state machine), sometimes not.
Where identity matters, the method adds an ordinary signature check alongside the preimage check; the two compose in one script.

**Node policy is the quiet dependency.**
The technique relies on BSV-specific ground rules: restored big-number arithmetic, no script size ceiling, the BIP-143 sighash with FORKID.
It is portable in concept but not in bytes — this is a BSV pattern, which is precisely why it can anchor a BSV differentiation story.

## 8. Pointers

- `ACCOUNT_MODEL.md` — what to build with this: account contracts, state threads, the indexer's role.
- `COMPOSABLE_PRIMITIVES.md` — OP_PUSH_TX in the primitive table, alongside its siblings.
- `VALIDATION_ORACLES.md` — bringing off-chain facts into covenant checks.
- `REUSABLE_SCRIPTS.md` — hash-referencing script code to fight preimage growth.
- sCrypt documentation (external) — `scrypt.io/docs`, particularly *Stateful Contracts* and `ScriptContext`.
- nChain / Bitcoin SV "OP_PUSH_TX" write-ups (external) — the original derivation of the in-script signature construction.
