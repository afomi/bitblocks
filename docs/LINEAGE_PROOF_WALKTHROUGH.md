# Inductive Lineage Proof — An Opcode-Level Walkthrough

Audience: developers who have read `SCRIPT_RUNTIME.md` (the execution model, especially §5 on ancestor introspection) and `OP_PUSH_TX.md` (the preimage technique).
This doc makes scope-2 introspection concrete: one token covenant, one spend, every stage of the proof traced at the stack-and-opcode level.
It closes with the honest cost analysis — the "recursion tax" — and why that tax explains the split between consensus-enforced lineage (this doc) and indexer-enforced lineage (bitblocks' BSV-20 pipeline, `BSV20_TOKENS.md`).

The scripts below are illustrative hand assembly, not compiler output.
Real toolchains (sCrypt's `Backtrace` library) emit optimized equivalents of exactly these stages.

## 1. The claim being proven

Cast:

- **Genesis outpoint** `G` — a plain P2PKH output the issuer owned; its 36 bytes (`txid` + `vout`) are baked into the token contract as a constant.
  An outpoint can be spent exactly once, which is what makes `G` a unique, unforgeable token ID.
- **Mint transaction** — spends `G` and creates the first token output carrying the contract script.
- **Token script** — laid out as `[code | state]` per the covenant convention (`OP_PUSH_TX.md` §5); `code` contains everything below, `state` holds balances/owner.

Every spend of a token output proves this disjunction:

```
valid(me) ⟺  my parent tx spent G            (base case: parent is the mint)
           ∨ my parent's output that created me carries my same code
                                              (inductive step)
```

Why the inductive step suffices: if my parent's output carried this same code, then *creating* my parent required spending a grandparent token output, and that spend executed this same check one generation earlier.
Each spend validates exactly one link; the chain of spends assembles the full proof by induction, grounded at the mint.
No single execution ever sees more than one generation — that is the whole trick.

## 2. Serialization ground truth

Two byte layouts do all the work.
The **transaction**:

```
nVersion(4) | inCount(varint) | inputs… | outCount(varint) | outputs… | nLockTime(4)
input:  prevTxid(32, raw hash order) | vout(4, LE) | scriptSigLen(varint) | scriptSig | nSequence(4)
output: value(8, LE) | scriptLen(varint) | scriptPubKey
```

The **sighash preimage** (BIP-143 layout, fixed offsets up to field 5):

```
offset   0: nVersion(4)
offset   4: hashPrevouts(32)
offset  36: hashSequence(32)
offset  68: outpoint(36)          ← my parent's txid + my vout
offset 104: scriptCode(varint+n)  ← my own current script
…then value(8), nSequence(4), hashOutputs(32), nLocktime(4), sighashType(4)
```

Two conventions to internalize:

- Txids inside transactions and outpoints are the **raw double-SHA256 bytes** (internal order); block explorers display them reversed. `OP_HASH256` output therefore compares directly with an outpoint's txid field — no reversal opcodes needed.
- `OP_SPLIT` is the workhorse: `x n OP_SPLIT` pops both and pushes `x[0..n)` and `x[n..end)`.

Demo template, to keep varint parsing readable: the transfer transaction has **exactly one input** (the token) and the token output at **vout 0**, with all counts and lengths under `0xfd` (one-byte varints).
§6 discusses what relaxing the template costs.

## 3. What the unlocking script pushes

The spender (wallet / qart-side SDK) supplies, bottom to top:

```
<sighash preimage of this spend>     ~1 KB+ (contains my whole script in scriptCode)
<full serialized parent transaction> the recursion payload — see §6
<method args>                        new owner, amount, signatures…
```

Remember the runtime's division of labor (`SCRIPT_RUNTIME.md` §1): the unlocking script *proposes bindings*; every byte it pushes is a claim, and the locking script's only job is to check the claims against each other and against consensus-anchored facts.
There are exactly two anchors available: OP_CHECKSIG (authenticates the preimage → the spending tx) and OP_HASH256-vs-outpoint (authenticates the parent bytes → history).
Everything below is plumbing between those two anchors.

## 4. The walkthrough

### Stage 1 — authenticate the preimage

The full OP_PUSH_TX ritual: hash the pushed preimage, compute an ECDSA signature over it in-script with a fixed key and nonce, hand signature + key to `OP_CHECKSIG`.
Passes iff the pushed bytes describe the transaction actually being validated.
Mechanism and edge cases: `OP_PUSH_TX.md` §3 — from here on, treat the preimage as **trusted**.

```
; stack after stage 1 (top at right):
;   … preimage
```

### Stage 2 — extract my own outpoint

My outpoint sits at preimage bytes [68, 104): parent txid (32) then my vout (4).

```
OP_DUP              ; preimage | preimage
0x44 OP_SPLIT       ; preimage | pre[0..68) | pre[68..)      (0x44 = 68)
OP_NIP              ; preimage | pre[68..)
0x24 OP_SPLIT       ; preimage | outpoint(36) | rest          (0x24 = 36)
OP_DROP             ; preimage | outpoint
0x20 OP_SPLIT       ; preimage | parentTxid(32) | myVout(4)   (0x20 = 32)
OP_DROP             ; preimage | parentTxid     (vout is 0 by template; a general
                    ;                            contract keeps it and uses it in stage 5)
```

I now know, with consensus-grade certainty, *which transaction created me*.
I do not yet know anything about its contents.

### Stage 3 — authenticate the parent bytes

The unlocking script pushed something *claiming* to be the parent transaction.
One opcode settles it, because a txid **is** the hash of the full serialized transaction:

```
; stack: preimage | parentTxid | parentTx(claimed)
OP_TUCK             ; preimage | parentTx | parentTxid | parentTx
OP_HASH256          ; preimage | parentTx | parentTxid | hash256(parentTx)
OP_EQUALVERIFY      ; preimage | parentTx
```

If the spender pushed doctored parent bytes, the hashes differ and the spend dies here.
This is the second anchor: from this point the parent's bytes are as trustworthy as the chain itself.
Note the asymmetry with stage 1: authenticating the *present* took an ECDSA construction; authenticating the *past* took one hash — history is cheap to verify because txids are already content addresses (the git-for-money pump from `SCRIPT_RUNTIME.md` §5).

### Stage 4 — parse the parent: the base case

Extract the outpoint the parent spent.
Under the demo template (one input), it sits at fixed offset: `nVersion(4) + inCount(1)` = byte 5.

```
; stack: preimage | parentTx
OP_DUP              ; preimage | parentTx | parentTx
0x04 OP_SPLIT       ; preimage | parentTx | version(4) | rest
OP_NIP              ; preimage | parentTx | rest
0x01 OP_SPLIT       ; preimage | parentTx | inCount(1) | rest
OP_SWAP             ; preimage | parentTx | rest | inCount
0x01 OP_EQUALVERIFY ; preimage | parentTx | rest        (template: exactly 1 input)
0x24 OP_SPLIT       ; preimage | parentTx | parentInputOutpoint(36) | rest
OP_DROP             ; preimage | parentTx | parentInputOutpoint
<G>                 ; preimage | parentTx | parentInputOutpoint | G(36-byte constant)
OP_EQUAL            ; preimage | parentTx | isBaseCase(bool)
```

`<G>` is the genesis outpoint constant, physically present in the code section of every generation's script — the token's identity, carried in its DNA.
If `isBaseCase` is true, the parent spent `G`: the parent is the mint transaction, the induction grounds out, and lineage is proven.

```
OP_IF
    ; base case: lineage proven — fall through to stage 6
OP_ELSE
    ; inductive step: stage 5
OP_ENDIF
```

### Stage 5 — parse the parent: the inductive step

Not the mint, so the parent must itself be a token transaction: its output 0 (which created me, per my vout) must carry my exact code.
Walk the parent to output 0's script.
The only variable-length region in the way is the parent's scriptSig:

```
; stack: preimage | parentTx
0x29 OP_SPLIT OP_NIP   ; strip version+inCount+outpoint (4+1+36 = 41 = 0x29)
0x01 OP_SPLIT          ; sigLenByte(1) | rest
OP_SWAP OP_BIN2NUM     ; rest | sigLen(number)     — varint byte → integer
OP_SPLIT OP_NIP        ; skip the parent's scriptSig itself
0x04 OP_SPLIT OP_NIP   ; strip nSequence
0x01 OP_SPLIT OP_NIP   ; strip outCount            (template: assume < 0xfd)
0x08 OP_SPLIT OP_NIP   ; strip output0 value       (a real token also CAPTURES this
                       ;                            for supply-conservation rules)
0x01 OP_SPLIT          ; scriptLenByte | rest
OP_SWAP OP_BIN2NUM
OP_SPLIT OP_DROP       ; parentOutput0Script
```

Now compare code sections.
The script layout is `[code | state]` and the compiler knows its own code length `C` as a constant; my own script arrives via the trusted preimage's `scriptCode` field (offset 104, after its varint):

```
; parent's code:
<C> OP_SPLIT OP_DROP           ; parentCode = parentOutput0Script[0..C)
; my code, from the preimage copy still on the stack:
;   (strip preimage[0..104) + scriptCode varint, then take C bytes — same
;    OP_SPLIT choreography as stage 2, elided)
                               ; parentCode | myCode
OP_EQUALVERIFY                 ; lineage link proven
```

`myCode` contains this very comparison logic — including the `<G>` constant and the `OP_EQUALVERIFY` that just ran.
Asserting `parentCode == myCode` therefore asserts *the parent enforced this same proof when it was created*.
That sentence is the entire induction, executed as one opcode.

### Stage 6 — the forward half

Backtrace only authenticates the past.
The same spend must also constrain the future — demand a successor output carrying `[myCode | newState]` — via the `hashOutputs` assertion walked through in `OP_PUSH_TX.md` §5.
Past-proof (stages 2–5) plus future-constraint (stage 6) in one script is what makes the token *closed*: every reachable state descends from `G`, and every spend re-imposes the rules.
A pure-transfer token also asserts amount conservation here, using output values captured during stage 5's parse.

## 5. Forgery analysis — where counterfeits go to die

**Copy the code, deploy a fake?**
Anyone can create an output carrying byte-identical token code.
It will sit on-chain looking exactly like the real thing — until someone tries to *spend* it.
The first spend runs stages 4–5 against the fake's actual parent: that parent neither spent `G` (spent once, by the real mint, forever) nor carries validly-created token code.
The disjunction fails; the fake is **stillborn** — mintable, but never movable.

**The parse can't be gamed.**
Every extraction above operates on bytes pinned by one of the two anchors.
Feed the parser a differently-shaped-but-real parent and offsets misread — but a misread yields wrong bytes at some `OP_EQUALVERIFY`, and wrong bytes **fail closed**: the spend is rejected, never mis-accepted.
(The flip side: fail-closed means an overly rigid template can strand real value — a parent that legitimately has two inputs is unspendable under the demo template.
Template generality is a safety-liveness tradeoff paid in parsing opcodes.)

**What the proof does *not* cover.**
Lineage ≠ supply control: one mint transaction could emit many token outputs unless the base case also constrains the mint's shape.
Lineage ≠ authorization: who *may* transfer is a separate signature check composed alongside (`OP_PUSH_TX.md` §7).
And the issuer's P2PKH key for `G` is a single point of failure *before* the mint — steal it pre-mint and you mint the "real" token.

**And note what the fake-detection story implies for indexers.**
Stillborn counterfeits are only exposed at spend time; an indexer that displays token balances *at creation time* must run the same induction itself or it will show forgeries as real.
That is precisely the validation bitblocks' token pipeline performs off-chain — same algorithm, different runtime (§7).

## 6. The recursion tax (the honest section)

Stage 3 requires pushing the **entire parent transaction**.
But the parent was itself a token spend, so *its* unlocking script contained *its* parent, and so on:

```
|tx_n| ≈ |tx_{n-1}| + template overhead
      ⇒ |tx_n| grows linearly with generation n
      ⇒ cumulative thread size grows quadratically
```

The induction is one generation deep *logically*, but the bytes accrete *physically*: every transfer drags the serialized weight of its whole ancestry, because a txid commits to full transaction bytes — scriptSigs included — and script has no way to hash-verify a partial serialization.
At BSV fee rates this is tolerable for short threads and ruinous for long-lived, high-frequency tokens.

Field-tested mitigations, each trading away something:

- **Checkpointing via oracle** — an attestation service signs "this outpoint's lineage is valid," and the script accepts `sig(oracle)` in place of the inductive branch, resetting accumulated size to zero.
  Trades trustlessness for constant size (`VALIDATION_ORACLES.md`); the Sensible Contract ecosystem ran production tokens this way.
- **Issuer co-signing** — a special case of the oracle: the issuer's key blesses each transfer.
  Cheapest, most centralized.
- **Indexer-enforced lineage** — drop consensus enforcement entirely; publish intent as data and let indexers run the induction off-chain.
  This is BSV-20's actual design (§7).
- **Proof compression (prospective)** — a succinct proof (zk or otherwise) that "a valid ancestry exists" would restore constant-size trustless transfers; nothing production-grade exists on BSV today.

## 7. The pairing: this proof vs. the BSV-20 indexer

Here is the symmetry this walkthrough was built to expose.

BSV-20 (`BSV20_TOKENS.md`) enforces **nothing** in script: mint/transfer are JSON inscriptions, and validity — does this transfer descend from a real mint, are balances conserved, was the ticker claimed first — is decided by indexers replaying the rules over the transaction graph.
The bitblocks token pipeline walks parents, checks code/rule continuity, grounds at a genesis event, and rejects counterfeit branches.

Read that against stages 2–5: **it is the same induction.**

| | In-script (this doc) | Indexer (bitblocks) |
|---|---|---|
| Who runs the proof | every validating node, at spend time | the indexer, at sync time |
| Cost model | fee bytes, paid per transfer, accreting (§6) | disk and CPU, paid once, amortized |
| Trust required | none beyond consensus | trust the indexer (or re-run it yourself) |
| Counterfeits | stillborn at first spend | filtered at display time |
| Rule upgrades | impossible — code is in the UTXOs | a re-index away |
| Failure mode | fail closed (value can strand) | fail open (bad indexer shows fakes) |

Neither column dominates; the recursion tax is the price of the left column and the trust assumption is the price of the right.
The SPV lens (`SPV_TUTORIAL.md` §6) names the underlying spectrum: between "consensus enforces it" and "a server says so" lies "anyone can re-verify it" — and an indexer whose validation algorithm is *published and re-runnable*, over data that is *hash-anchored*, sits in that middle ground.
An explorer that can display, for any token UTXO, the very lineage chain a covenant would have verified — parent by parent, back to genesis — is making the right column auditable.
That is a product statement hiding inside an opcode walkthrough.

## 8. Pointers

- `SCRIPT_RUNTIME.md` — execution model; §5 introduced ancestor introspection abstractly.
- `OP_PUSH_TX.md` — stage 1 in full (preimage verification), stage 6 in full (successor constraint), state-thread UX.
- `BSV20_TOKENS.md` — the indexer-enforced column of §7 as implemented in this repo.
- `VALIDATION_ORACLES.md` — the checkpointing mitigation for §6.
- `SPV_TUTORIAL.md` — the verification-cost spectrum that frames §7.
- External: sCrypt `Backtrace` library docs (`scrypt.io/docs`) — the production packaging of stages 2–5; Xiaohui Liu's inductive-token articles — the original derivations and the size-growth discussion.
