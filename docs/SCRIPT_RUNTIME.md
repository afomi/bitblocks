# The Bitcoin Script Runtime — Execution Model, Meta-Programming, and Introspection

Audience: a developer fluent in OOP and functional paradigms (Ruby, Elixir), with light exposure to logic programming (Prolog).
This doc builds the execution model from paradigms you already hold, then maps BSV's introspection and meta-programming capabilities across three scopes: within a transaction, across existing transactions, and in the mempool.
It leans on intuition pumps (Dennett's sense: small thought experiments that make an abstract mechanism *feel* obvious).
`OP_PUSH_TX.md` covers the central reflection technique in depth; this doc positions it rather than re-derives it.

## 1. The first reframe: script is not a program, it is a predicate

The single most load-bearing idea, and the one most foreign to a Ruby/Elixir mindset:

**A locking script never "runs" in the sense of doing work.**
**It is evaluated, once, at validation time, to answer one boolean question: is this spend authorized?**

There is no main loop, no process, no runtime sitting somewhere executing your contract.
The "runtime" is every validating node, and it fires only at the moment someone attempts to spend the output.
Between spends, a script is inert data at rest in the UTXO set.

### Intuition pump: Prolog without the search

You know how a Prolog query works: state a goal, and the engine *searches* for variable bindings that satisfy it.
Bitcoin script is the same relation — minus the search.

- The **locking script** is the goal: a predicate with free variables.
- The **unlocking script** is the bindings: concrete values (a signature, a preimage, method arguments) proposed as a solution.
- The **node** is a proof *checker*, never a proof *finder*.

Bitcoin only ever verifies; it never solves.
The expensive, creative work of finding satisfying bindings happens off-chain, in wallets and contract SDKs (in this ecosystem: qart composes and signs, bitblocks indexes and reads — see `COMPOSABLE_PRIMITIVES.md`).
This is the NP-verifier pattern: solutions may be hard to find, but checking one is cheap and mechanical.
Every design consequence of Bitcoin flows from keeping the chain on the cheap side of that asymmetry.

### Intuition pump: the function head that outlives its module

In Elixir you write guards on a function head: `def spend(sig, pubkey) when valid?(...)`.
A locking script is a function head *detached from any module and frozen into the ledger*.
It waits, potentially for years, for someone to call it with arguments that match.
And like a guard, it is deliberately restricted: total, side-effect-free, guaranteed to terminate.

## 2. The machine itself

The execution model is a **stack machine** in the Forth family — concatenative, point-free, no named variables.

- Two stacks: the main stack and an alt stack (`OP_TOALTSTACK` / `OP_FROMALTSTACK` as a scratch register).
- Every stack element is an untyped byte string; opcodes impose interpretation (number, boolean, hash, signature) at the moment of use.
- Control flow is `OP_IF / OP_ELSE / OP_ENDIF` only — branches, but **no backward jumps and no loops**.
- Therefore every script is **total**: execution time is linear in script length, termination is guaranteed, and no gas metering is needed — fees price bytes, not steps.

Evaluation order for one input:

1. The **unlocking script** runs first — post-Genesis BSV requires it to be push-only, so "runs" means "loads data onto the stack."
2. The **locking script** then runs against that stack.
3. The spend is valid iff the final top-of-stack is truthy.

Each input of a transaction gets its own isolated evaluation.
There is no shared memory between inputs, no globals, no heap, no I/O.
A script cannot read the block height, the time, another UTXO, or the network.
It sees exactly two things: the stack it was handed, and (through one keyhole, §4) the transaction spending it.

### What BSV specifically restored (the Genesis upgrade, Feb 2020)

BSV's runtime is materially more capable than BTC's, and the difference is what makes the meta-programming story real:

| Capability | BTC | BSV post-Genesis |
|---|---|---|
| `OP_CAT`, `OP_SPLIT` (byte surgery) | disabled | restored |
| `OP_MUL`, `OP_DIV`, `OP_MOD`, shifts, `OP_INVERT` | disabled | restored |
| Number size | 4-byte ints | effectively arbitrary-precision bignums |
| Script size / opcode count | hard low limits | no practical ceiling |
| P2SH | standard | disabled for new outputs (scripts live in the open) |
| `OP_CHECKLOCKTIMEVERIFY` / `OP_CHECKSEQUENCEVERIFY` | active | removed (post-Satoshi additions); timelocks via the `nLockTime`/`nSequence` fields instead |

The restorations matter because **in-script ECDSA arithmetic** (bignum multiply/mod) and **in-script byte manipulation** (`OP_CAT`/`OP_SPLIT`) are exactly the ingredients OP_PUSH_TX needs.
BTC cannot express the technique; BSV can, which is why the covenant/state-machine ecosystem (sCrypt) grew here.

### Intuition pump: homoiconicity by accident

Lisp is homoiconic on purpose: code is lists, so programs can build programs.
Script is homoiconic *by accident of representation*: a script is just bytes, the stack holds bytes, and `OP_SPLIT`/`OP_CAT` slice and splice bytes.
So a script can hold another script (or its own script — §4) on the stack, cut it apart, inspect a field, swap a segment, and hash the result.
That is template-style meta-programming: not `eval` (a script can never *execute* constructed code in-place), but code *construction and verification* — closer to a macro assembler than to a metacircular evaluator.
The constructed code becomes live only by being embedded in an output of the next transaction, which is exactly the covenant loop.

## 3. Where the paradigms map — and where they break

**From OOP (Ruby):**
A UTXO is like an object with exactly one public method, `unlock(args) → bool`, and a frozen state.
But there is no `self`-mutation, ever.
"Changing state" means destroying the object and minting a successor — the UTXO model is a persistent (immutable) data structure at ledger scale.
Identity-over-time is therefore not primitive; it is *reconstructed* by following spend chains, which is precisely an indexer's job (`ACCOUNT_MODEL.md`).

**From Elixir/OTP — the frozen GenServer pump:**
A stateful covenant output is a GenServer frozen between calls.
The outpoint is its pid; the script's data segment is its state.
A spend is a `handle_call`: arguments arrive (unlocking script), the reply is a new frozen process (the successor output), and the old pid is dead forever.
Two callers racing for the same head?
One wins, one gets `:noproc` — not queued, not merged, rejected (see the head-race section of `OP_PUSH_TX.md`).
And the registry mapping a stable name to the current pid?
That is bitblocks: the indexer *is* the process registry for on-chain state machines.

**From Prolog:**
Already covered — verification without search.
One refinement: sighash flags (§4) act like selective quantification, choosing which parts of the spending transaction the predicate binds tightly and which it leaves free (free variables the ecosystem exploits for fee sponsorship and change).

**Where all three break:**
No paradigm you know has *validation-time-only existence*.
There is no ambient runtime, no ticking clock, no scheduler.
A contract "acts" only when an external party pays to poke it.
If nobody spends, nothing happens, forever.
Every liveness property in a Bitcoin system is social/economic, not computational.

## 4. Introspection scope 1: within the transaction — reflection through a keyhole

Natively, script has **zero** reflection: no opcode returns "the outputs of the transaction spending me."
The runtime was designed blind on purpose.

The escape hatch is that `OP_CHECKSIG` must hash the spending transaction to verify signatures — so the transaction data *is present* at validation, just not exposed.
**OP_PUSH_TX** is the technique that makes the spender push that digest preimage onto the stack and then proves, in-script, that the pushed bytes match the real transaction.
Full mechanism, field table, and design consequences: `OP_PUSH_TX.md`.
The one-line summary: *the script recruits OP_CHECKSIG as an equality oracle between a claimed transaction and the actual one.*

What this buys, in meta-programming terms:

- **Introspection of self**: the preimage's `scriptCode` field is the script's *own source code*.
  A script that reads its own code and demands a successor carrying that same code is a quine with a payload — self-replication with a state transition riding along.
- **Introspection of context**: own outpoint (identity), own satoshi value, the hash of the spending transaction's outputs, locktimes, sighash flags.
- **Constraint of the future**: assert `hashOutputs` equals the hash of outputs the script itself constructs.
  The script cannot *see* the future, but it can *veto every future except the ones it enumerates*.

### Intuition pump: the Gödel move at the border crossing

A transaction cannot show the border guard (the script) its passport, because the script has no eyes.
So the transaction slips a *description of itself* into its own luggage (the unlocking script).
The guard cannot check the description against the traveler directly — but there is a machine at the border (OP_CHECKSIG) that stamps papers only when description and traveler hash to the same digest.
Self-reference smuggled through a channel meant for something else: the same structural trick as Gödel numbering — a system's statements encoded as objects the system itself manipulates.
The result is a language with no reflection API that nevertheless supports programs that reason about themselves.

## 5. Introspection scope 2: existing transactions — induction up the ancestry

The preimage shows a script its *own* outpoint: the txid and index that created it.
A txid is a hash of the full parent transaction.
So the unlocking script can push the **entire serialized parent transaction**, and the locking script can hash it and assert equality with the outpoint's txid.
Now the script holds authenticated bytes of its parent and can `OP_SPLIT` them apart: read the parent's outputs, its scripts, its parents' outpoints.

Repeat the move and you get **inductive lineage proofs**:

```
genesis tx ◄── tx₁ ◄── tx₂ ◄── ... ◄── me
   each spend verifies: "my parent carried this same contract,
   or my parent IS the genesis outpoint"
```

Each generation checks only one link, but because every generation performed the same check, the property holds by induction back to genesis.
This is how a token contract can prove "I descend from the authentic issuance" *without trusting any indexer* — sCrypt packages it as its `Backtrace` library.
Note the division of labor it implies: the chain verifies lineage one hop at a time; an indexer (bitblocks) is what answers lineage questions *wholesale*, across all tokens at once (`BSV20_TOKENS.md`, `PROVENANCE.md`).

Two honest limits:

- **Cost grows with what you drag in.**
  Proving facts about an ancestor means pushing that ancestor's bytes; deep or fat ancestors mean fat unlocking scripts.
  Mitigations mirror the state-size story in `OP_PUSH_TX.md` §7: hash commitments, merkle proofs, keeping the checked slice minimal.
- **Only ancestors, never siblings.**
  A script can authenticate its own causal history — the chain of txids is a hash-linked spine — but it has no authenticated path to an *unrelated* transaction elsewhere in the chain.
  Cross-lineage facts must enter as signed oracle attestations (`VALIDATION_ORACLES.md`) or merkle proofs against a committed root (`MERKLE_PROOFS.md`).

### Intuition pump: git for money

A txid is a commit hash; inputs are parent pointers; the UTXO set is the set of branch tips.
Ancestor introspection is `git log` performed *inside the commit hook*: a commit that verifies its own parentage before allowing itself to exist.
And the sibling limitation is familiar too — a commit can prove its history, but knows nothing about other branches unless someone hands it a merge base.

## 6. Introspection scope 3: the mempool — deliberately invisible

Flat statement: **script cannot see the mempool at all.**
No opcode references pending transactions, and this is not a missing feature — it is load-bearing.

The mempool is not a data structure of the protocol; it is each node's private waiting room.
Two nodes may hold different mempools at the same instant, and consensus never requires them to agree on it.
If validity could depend on mempool contents, validity would differ per node and per moment, and re-validating historical blocks would be impossible.
Script's blindness to the mempool is what keeps validation **deterministic and replayable forever** — the same property that lets bitblocks re-derive all state from raw blocks.

So mempool-scope "introspection" splits into two off-chain capabilities:

**Observation is the indexer's job.**
Watching pending transactions, racing heads, unconfirmed lineages — that is infrastructure like bitblocks (SSE streams, `SYNC_PIPELINE.md`), not script.
When the docs here talk about order-book liveness or 0-conf UX, the mempool awareness always lives on this side of the line.

**Mutation-before-finality is the protocol's one concession.**
A transaction with `nSequence < 0xFFFFFFFF` and a future `nLockTime` is *non-final*: nodes hold it, and a version with a higher `nSequence` replaces it.
The mempool becomes a negotiation space — parties exchange and re-exchange updated versions off-chain or through nodes, and only the final version settles.
That is the substrate of payment channels (`PAYMENT_CHANNELS.md`): thousands of state updates in the waiting room, one transaction on the ledger.

### Intuition pump: the notary's lobby

The chain is a notary's archive: stamped, bound, immutable.
The mempool is the lobby, where drafts circulate and get marked up.
Asking "can a contract read the mempool?" is asking whether a stamped document can reference the lobby chatter that preceded it — it cannot, *by design*, because the archive must be interpretable by someone who never saw the lobby.
Anything worth remembering from the negotiation must be written into the document itself before stamping.

## 7. The whole computer: transactions as steps, the chain as the tape

Assemble the scopes and a two-level computational model emerges:

- **Within a script**: total, terminating, loop-free — decidable by construction.
  Each script is one *frame* of computation.
- **Across transactions**: unbounded.
  A covenant that constrains its successor (scope 1) which verifies its ancestry (scope 2) forms a state machine whose tape is the transaction chain itself.
  Loops that cannot exist inside a script reappear *across* spends: each transaction executes one iteration, and the chain records the loop unrolled.

Whether this earns the phrase "Turing complete" is a debate mostly about definitions (the unbounded tape requires an external party willing to keep building transactions).
The practical statement is cleaner: **any state machine can be run as a transaction chain, with every step validated by consensus and every step's history permanently auditable.**
Computation advances only when someone pays to advance it — the halting problem dissolved not by mathematics but by economics.

### Intuition pump: film frames

Each script execution is one frame of a film: static, complete, verifiable in isolation.
The movie — the running program — exists only in the projection, and the projector is whoever constructs the next transaction (a wallet, qart, an automated advancer).
The chain is the reel: you can always replay the movie, frame by frame, and every frame proves it followed from the last.
Bitblocks, in this metaphor, is the studio archive that indexes reels and can seek to any frame instantly.

## 8. Capability summary

| You want to... | Mechanism | Scope | Where it runs |
|---|---|---|---|
| Gate a spend on arbitrary predicates | plain script (stack machine) | one input | consensus |
| Read the spending tx's fields, own code, own value | OP_PUSH_TX preimage | within tx | consensus |
| Constrain successor outputs (state machines) | preimage `hashOutputs` assertion | within tx → future | consensus |
| Verify facts about the tx that created you, or deeper lineage | push parent tx bytes, hash-match outpoint; induct | existing txs (ancestors only) | consensus |
| Reference unrelated existing txs | signed oracle attestation or merkle proof against a committed root | anywhere | consensus checks, off-chain supplies |
| Observe pending/racing transactions | indexer, SSE streams | mempool | off-chain (bitblocks) |
| Iterate state before settling | non-final tx replacement (`nSequence`) | mempool | node policy + counterparties |
| Run unbounded computation | covenant state threads, one step per spend | chain-as-tape | consensus per step, liveness off-chain |

## 9. Open threads

Questions this doc deliberately leaves open, as forks for further dialogue:

- **The macro layer**: sCrypt is to script what a Lisp macro system is to assembly — how much of the meta-programming story should be understood at the sCrypt level vs. raw opcodes?
- **Inductive token deep-dive**: walk one real BSV-21 lineage proof opcode-by-opcode (would pair with `BSV20_TOKENS.md`).
- **Mempool game theory**: non-final replacement as a negotiation protocol — mechanism design, griefing, and what an indexer should surface about in-flight negotiations.
- **Decidability as product**: scripts are total, so fees are exact and DoS-by-computation is impossible — how to present "no gas" as a differentiator (`ADOPTION_SPECTRUM.md`).

## 10. Pointers

- `OP_PUSH_TX.md` — the reflection technique in full: verification trick, preimage fields, covenant loop, UX consequences.
- `COMPOSABLE_PRIMITIVES.md` — where these capabilities sit in the primitive-composition map.
- `ACCOUNT_MODEL.md` — state threads as accounts; the indexer as process registry.
- `VALIDATION_ORACLES.md` — importing off-chain facts past the runtime's blindness.
- `PAYMENT_CHANNELS.md` — mempool-scope iteration in practice.
- `MERKLE_PROOFS.md` — authenticated references to committed data.
- External: sCrypt docs (`scrypt.io/docs`) — *ScriptContext*, *Stateful Contracts*, `Backtrace`; the BSV Genesis upgrade spec for the exact restored-opcode list.
