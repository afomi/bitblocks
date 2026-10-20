# Reusable Scripts — Content-Addressed Functions on Bitcoin

The problem: putting the same validation script in 100M UTXOs is duplicative.
The goal: store it once, reference it by hash, verify it at spend time.

## The Unix Parallel

```
Unix:      ld.so loads libc.so.6 at runtime — one copy, many processes
Bitcoin:   every UTXO carries its own script — no shared libraries
```

Bitcoin today is statically linked. Every "binary" (UTXO) contains all its code.
We want dynamic linking — a UTXO that says "load validation function abc123."

## What Exists Today on BSV

### Hash-verified script injection

The locking script stores only the hash.
The spender provides the full script at spend time.
The script verifies the hash before "executing" the logic.

```
Locking script (32 bytes + overhead):
  OP_DUP OP_HASH256 <expected-hash-32-bytes> OP_EQUALVERIFY
  [consume the verified script's output]

Unlocking script (provided by spender):
  <full-validation-function>
```

The function is:
- Content-addressable (identified by SHA256)
- Immutable (hash pins it)
- Reusable (100M UTXOs × 32 bytes, not 100M × 500 bytes)
- Verifiable (anyone checks function matches hash)

Limitation: Bitcoin script can't "eval" arbitrary code from the stack.
The injected script is data, not executable code.
You use it with OP_IF branches or as input to fixed verification patterns.

### sCrypt compile-time libraries

```typescript
class ValidationLib extends SmartContractLib {
    @method()
    static validate(data: ByteString): boolean { ... }
}

class CardCovenant extends SmartContract {
    @method()
    public update(data: ByteString) {
        assert(ValidationLib.validate(data))  // inlined at compile time
    }
}
```

Developer experience is "call a library function."
On-chain reality is "the function is inlined into every UTXO."
Convenience without deduplication.

### Content-addressed scripts as data (OP_RETURN)

Publish the validation function as an OP_RETURN transaction:

```
TX: publish-schema-v1
  OP_RETURN | PCRD_SCHEMA_ADDR | <json-schema-bytes>
  txid: abc123...
```

Now `abc123...` is the permanent, verifiable identifier for that schema.
Any validator fetches it by txid.
Any indexer verifies data against it.
Not enforced by script — enforced by convention + oracle attestation.

This is the pragmatic path. The schema lives on-chain once.
The oracle validates against it. The covenant checks the oracle's signature.
Total on-chain overhead per card UTXO: ~50 bytes (sig check + schema hash).

## What Doesn't Exist Yet

### OP_EVALFROMUTXO (hypothetical)

```
OP_EVALFROMUTXO <txid> <vout>
```

"Load the script from this UTXO and execute it."
True dynamic linking — the script lives on-chain once, called by reference.
BSV has reserved opcodes (OP_NOP1-10) that could be repurposed.
This is a protocol-level change, not something we can build today.

### OP_DATASIGVERIFY + published function

A weaker but useful version:

```
Published at txid abc123: the validation function (as data)
UTXO script: 
  verify that the spending tx includes a signature 
  over (data_hash + function_hash) from a known oracle key
```

This is the validation oracle pattern — the "function" is data on-chain,
the "execution" happens off-chain, the "result" is a signature.
Close to dynamic linking in spirit, without protocol changes.

## Cost Comparison

| Approach | Per-UTXO script size | Per-UTXO cost at 0.05 sat/byte | 100M UTXOs |
|----------|---------------------|-------------------------------|-----------|
| Full inline (today) | ~500 bytes | 25 sats (~$0.000013) | $1,300 |
| Hash reference + oracle | ~50 bytes | 2.5 sats (~$0.0000013) | $130 |
| OP_EVALFROMUTXO (future) | ~40 bytes | 2 sats (~$0.000001) | $100 |

The savings are 10x, but the absolute numbers are small.
At BSV's fee rates, even the "wasteful" approach costs $1,300 for 100M transactions.
The motivation for deduplication is cleanliness, not cost.

## Relationship to Blockchains as Unix

```
/var/log     = the chain (append-only events)
/proc        = UTXO set / state trie (derived, disposable)
libc.so      = published validation script (stored once, referenced by hash)
dlopen()     = OP_EVALFROMUTXO (load at runtime — future)
ld.so        = oracle (loads the function, runs it, attests result — today)
stdin/stdout = inputs/outputs
pipe         = script execution
```

The chain is an append-only log. State is derived. Functions are content-addressed.
Execution can be local (script) or delegated (oracle).
The Unix philosophy applies: small tools, text streams, composable.

The missing piece is `dlopen()` — loading code by reference at runtime.
Until that exists at the protocol level, oracles are the dynamic linker.
