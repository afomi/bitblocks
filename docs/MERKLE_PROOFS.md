# Merkle Proofs

A Merkle proof answers a simple question: *"Can I show, in a compact way, that this exact transaction appears in a particular block?"*
Bitblocks exposes Merkle data (via `GET /api/v1/txs/:txid/proof`) so lightweight instances or end users can validate inclusion without downloading the entire block.

Each proof is checked before it is returned: `Bitblocks.Chain.MerkleVerifier` rebuilds the Merkle root from the block's txid list, and `Bitblocks.Chain.MerkleProof` climbs the siblings back to the header's root (handling Bitcoin's odd-node duplication and little-endian byte order).
Part 2 documents the response.

---

## Part 1 — For designers: making proofs feel trustworthy

These notes translate the Merkle-proof idea into product language so teams can craft UI that feels trustworthy.

### Why designers should care

- **Trust at a glance** – Visualising a proof lets someone see the difference between "Bitblocks says so" and "the blockchain says so."
- **Progressive disclosure** – Proofs compress 1000s of transactions into a handful of hashes. Good UI hints at that compression without overwhelming users.
- **Consistency across tiers** – Full-node operators and lightweight subscribers share the same proof format. Consistent UI keeps cross-team collaboration smooth.

### Core ingredients

| Term | Plain-language summary | UI hint |
| ---- | ---------------------- | ------- |
| Transaction hash | Fingerprint of the user's action (payment, note, etc.). | Treat as the "file" being verified. |
| Merkle tree | Binary tree of hashes that summarises every transaction in the block. | Imagine a tournament bracket that ends at the block header. |
| Merkle root | The single hash recorded in the block header. | Design as a "certified stamp" that users can recognise. |
| Proof path | Ordered list of sibling hashes needed to climb from the transaction up to the root. | Display as a stacked list; each step combines with the running hash. |

### Reading a proof flow

1. **Start with the transaction hash** – Highlight the item the user cares about (e.g., `txid`).
2. **Iterate through siblings** – For each hash in the proof path, combine it with the running hash (left or right matters) and re-hash.
A simple diagram helps: current hash on the left, sibling on the right, new hash above.
3. **Compare with the Merkle root** – The final hash must match the block's root. If it does, you've proven inclusion.

Design tip: animate the transitions across the three steps so people feel the "climbing the tree" motion.

### Bitblocks-specific cues

- **Block context** – Always show the block height and header hash next to the root.
Lightweight clients can cache headers; this reinforces that the proof ties back to persistent chain data.
- **Proof size indicator** – The proof length tells users how much of the tree they traversed. Consider a small badge like "8 hops" to communicate depth.
- **Human mode vs. export mode** – Offer a toggle: one view for humans (diagram, checkmarks), another that reveals the raw JSON an engineer can paste into tooling.
- **Error states** – If a proof fails, copy Git's conflict tone: highlight the offending step, suggest re-syncing headers, and surface the mismatched hash.

### Visual metaphors that work

- **Folder trail** – Each level in the tree looks like drilling deeper into a nested folder, reinforcing the "part-of-a-whole" concept.
- **Blueprint stamp** – Treat the Merkle root like an architect's stamp of approval placed on the block header.
- **Progress bar** – A vertical progress indicator that fills as the proof is evaluated reinforces completion.

---

## Part 2 — The endpoint: `GET /api/v1/txs/:txid/proof`

The response gives you everything you need to check inclusion yourself: the transaction's position in its block (`index`), the sibling hashes from leaf to root (`siblings`), and the root they must reach (`merkleroot`), which is the one in the block header.
Built by `Bitblocks.Chain.MerkleProof` (#43).
For the standard binary evidence, see Part 3.

### Example: the first spend, block 170

Block 170 holds two transactions: the coinbase, and Satoshi's 10 coins to Hal Finney at index 1.

```sh
curl https://bitblocks.example/api/v1/txs/f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16/proof
```

```json
{
  "data": {
    "txid": "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16",
    "index": 1,
    "siblings": [
      "b1fea52486ce0c62bb442b530a3f0132b826c74e473d1f2c220bfa78111c5082"
    ],
    "merkleroot": "7dac2c5666815c17a3b36427de37bb9d2e2c5ccec3f8633eb91a4205cb4c10ff",
    "block_hash": "00000000d1145790a8694403d4063f323d499e655c83426834d4ce2f8dd4a2ee",
    "block_height": 170,
    "confirmations": 1,
    "source": "block_txids",
    "trust": {
      "header": "merkleroot is from a block header bitblocks stored only after checking it hashes to block_hash, meets the proof-of-work target in its bits, and chains onto its parent.",
      "proof": "siblings and index were climbed back to merkleroot before this response was sent; …",
      "canonical": "the block is the one this index holds at block_height, and the next stored block builds on it."
    }
  }
}
```

`test/bitblocks_web/controllers/api/proof_controller_test.exs` checks this index, sibling and root against the real block 170, and that this example uses the field names the endpoint returns.

| Field | Meaning |
| ----- | ------- |
| `txid` | The transaction, big-endian display hex. |
| `index` | Its position in the block, 0 for the coinbase. |
| `siblings` | One hash per tree level, leaf to root, display hex. Where a level has an odd count, the last node pairs with itself, so its sibling is its own hash. A single-tx block has none. |
| `merkleroot` | The root in the block header. The climb must end here. |
| `block_hash`, `block_height` | The block whose header commits to `merkleroot`. |
| `confirmations` | Our highest stored header minus `block_height`, plus 1. |
| `source` | `block_txids` when the siblings come from the block's stored, root-checked txid list; `gettxoutproof` when the list is not kept (blocks over 10,000 txs) and the node's merkleblock was parsed and checked instead. |
| `trust` | What the answer rests on, in words. |

### What the answer rests on

The header is trusted because tip sync stored it only after `Bitblocks.Chain.HeaderVerifier` checked that its fields hash to `block_hash`, that the hash meets the proof-of-work target in its `bits`, and that it chains onto its stored parent.
The proof shows inclusion under that header.
If you keep your own header chain, compare `block_hash` and `merkleroot` with it and you need not trust bitblocks at all.

Before it answers, bitblocks climbs the siblings itself.
A txid list (or node merkleblock) that does not rebuild the header's root is never returned as a proof.

### When there is no proof

| Status | Why |
| ------ | --- |
| 404 | We don't store this transaction. |
| 409 | Its block is not canonical in this index: a reorg orphaned it (tip sync deletes orphaned block rows; the tx row keeps the old hash until `Reorgs.Reconcile` moves it), its height no longer matches, or the next stored block doesn't build on it. |
| 500 | The block's transactions did not rebuild the header's root, or the verified list doesn't contain the tx. |
| 503 | The block's txid list isn't stored and the node gave no proof. Try again later. |

### Check a proof (Elixir)

```elixir
def verify?(%{"txid" => txid, "index" => index, "siblings" => siblings, "merkleroot" => merkleroot}) do
  {root, _index} =
    Enum.reduce(siblings, {internal(txid), index}, fn sibling_hex, {acc, i} ->
      sibling = internal(sibling_hex)
      pair = if rem(i, 2) == 0, do: acc <> sibling, else: sibling <> acc
      {sha256d(pair), div(i, 2)}
    end)

  root |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin() |> Base.encode16(case: :lower) ==
    String.downcase(merkleroot)
end

# Hashes are displayed big-endian; the tree hashes them in internal (little-endian) order.
defp internal(hex), do: hex |> Base.decode16!(case: :mixed) |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin()
defp sha256d(bytes), do: :crypto.hash(:sha256, :crypto.hash(:sha256, bytes))
```

`Bitblocks.Chain.MerkleProof.climb/3` is the same computation.

**Why the byte reversal?** Bitcoin stores hashes internally in little-endian byte order, while APIs return big-endian hex.
Reversing before hashing makes the double-SHA256 rounds match consensus.

---

## Part 3 — The same check against WhatsOnChain

WhatsOnChain gives the same two ingredients under other names, so you can cross-check a bitblocks answer against a second source.

```sh
curl https://api.whatsonchain.com/v1/bsv/main/tx/f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16/proof/tsc
curl https://api.whatsonchain.com/v1/bsv/main/block/hash/00000000d1145790a8694403d4063f323d499e655c83426834d4ce2f8dd4a2ee
```

The TSC proof's `index` is our `index` and its `nodes` are our `siblings`, with `*` standing for "pair with yourself" where we repeat the hash.
The block's `merkleroot` must equal ours.

A node's `gettxoutproof` is a different thing: a hex-serialized merkleblock (the 80-byte header, the tx count, and a partial merkle tree of hashes and flag bits).
Bitblocks parses and checks it for large blocks, as above, but does not pass it through.

### Visualise inside Bitblocks

With the proof verified, render it in LiveView: highlight the **leaf** (the txid), list each **sibling** with its left/right orientation (even index: sibling on the right), and show the **root** with a green check once the computed value matches.

---

## Part 3 — BEEF: `GET /api/v1/txs/:txid/beef`

`data.beef` is the transaction as BEEF ([BRC-62](https://github.com/bitcoin-sv/BRCs/blob/master/transactions/0062.md)) in hex, with merkle paths as BUMPs ([BRC-74](https://github.com/bitcoin-sv/BRCs/blob/master/transactions/0074.md)), so an app can store the evidence with its record rather than a pointer.
Built by `Bitblocks.Chain.Beef`, on the same proofs as Part 2, so the same statuses apply.

- The transaction comes last and carries its own BUMP, so the BEEF is valid on its own.
- Its parents come first, each with a BUMP, up to 25 distinct parents.
- Proofs from one block share one BUMP.
- `parents_missing` names any parent left out (not stored, no proof available, or past the 25), and `complete` is false when there are any.
- The bytes are parsed back before they are sent: each transaction must hash to its txid, and each BUMP must climb to the root in the stored header.

The roots rest on our stored headers, so check them against your own header source.
The tests pin the encoder to the BRC-62 and BRC-74 example vectors, and to the real 106-transaction block 814435.

`?format=atomic` gives Atomic BEEF ([BRC-95](https://github.com/bitcoin-sv/BRCs/blob/master/transactions/0095.md)): the prefix `01010101`, the subject txid, then a BEEF holding the transaction and its BUMP alone, with `format` in the answer saying which it is.
Atomic BEEF's ancestry stops at the first transaction with a proof, and ours always has one, so its parents would count as unrelated data, which the reference SDK refuses.
The subject is written in internal byte order, as that SDK writes it; BRC-95 itself doesn't say.

---

## Part 4 — BEEF from anyone: `POST /api/v1/beef/verify`

Send a BEEF and hear what it shows against the headers we hold.
The body is raw bytes as `application/octet-stream`, or `{"beef": "<hex>"}` as `application/json`, up to 4 MB.
It takes BEEF V1, BEEF V2 ([BRC-96](https://github.com/bitcoin-sv/BRCs/blob/master/transactions/0096.md)) and Atomic BEEF around either.
It takes a key or a signed-in session, like the rest of `/api/v1`.

**The claim is inclusion in a block, and no more.**
It says a transaction's bytes sit under a merkle root in a header.
It doesn't say the transaction's scripts pass, its inputs were unspent, a token in it is genuine or a payment was made.
No script runs here, and the answer lists all of that under `not_checked`.

Each transaction gets a status, and `data.status` is the subject's:

| Status | Means |
| --- | --- |
| `proven` | Its bytes hash to its txid, its BUMP climbs to a root, and that root is the one in a verified, canonical header at that height. |
| `anchored` | It has no BUMP, and every input leads, within this BEEF, to proven transactions. It is not itself shown to be in a block, so `in_block` is false. |
| `unknown` | We can't say: no header at that height, or that header didn't pass or isn't canonical, or the BEEF lacks what it needs. Never read this as a pass. |
| `failed` | The evidence is wrong: the root isn't the one we hold at that height, the BUMP reaches no root or can't be that block's, or an ancestor failed. |

The answer names the subject (`subject_txid`), lists what is `proven`, and gives each transaction its `block_height`, `merkleroot`, `index`, `confirmations`, `reason` and `detail`.
A verifier's answer is a 200 whatever the evidence shows.
A 400 is a body we can't take, a 413 is over the limit, a 415 is another content type, and a 422 is bytes that aren't a BEEF, with `reason` saying why.

The check adds two things to the climb.
A 64-byte transaction is refused, because 64 bytes is also the preimage of an inner merkle node, so one could pose as a leaf.
When the block's `num_tx` is known, the BUMP's tree height must be that block's and the offset inside it.
`num_tx` doesn't come from the header, so we hold it on our node's word.

The parser is `Bitblocks.Chain.Beef.Reader`: no database, no atoms from input, sizes and counts bounded, with truncation and trailing bytes refused.
It is built to move to bsv-ex.

### What to accept

These are the defaults Bitblocks stands behind, chosen on 2026-11-06 (#60).

- **`proven` is enough to say a transaction is in a block.** That is all it says.
- **`anchored` isn't enough to accept a payment on its own.** Accept it only when your own wallet has also checked the scripts, signatures and amounts, and has seen no double spend. For a large amount, wait for `proven`.
- **`unknown` and `failed` are never a pass.**

The verifier stays behind a key or a signed-in session, because each call takes up to 4 MB of work, so anyone can get a trial key from `/start`.
The 4 MB limit stays, and the API and `/start/interop` share it, so they agree on every input.

The same reader and verifier stand behind the open test vectors at `GET /interop/vectors/v1.json` and the check page at `/start/interop` ([INTEROP_KIT.md](INTEROP_KIT.md)).

### The size limit

`Plug.Parsers` in the endpoint passes `application/octet-stream` through unread, so `BeefController` reads that body itself, after the key-or-session gate, up to `:beef_verify_max_bytes` (4 MB).
A JSON body is read by `Plug.Parsers` ahead of the router, so that one is read before the gate, as on every JSON route, up to the parser's 8 MB default.
Its hex is then held to the same 4 MB.

---

## Part 5 — Headers: `GET /api/v1/headers`

These routes need no key, and any site's browser can read them, under the logged-out rate limit: a header is public data, and a light client needs it to check a merkle root.

`GET /api/v1/headers/:height` gives one header, and `GET /api/v1/headers?from=<height>&limit=<n>` gives up to 2,000 in height order (100 by default).
Each has the raw 80-byte `header` as hex, with `hash`, `height`, `merkleroot`, `prevblockhash`, `version`, `time`, `bits`, `nonce`, `num_tx` and two flags.

- `verified`: the row's fields rebuild an 80-byte header that hashes to its `hash` and meets the proof of work in its own `bits`, checked as it is read. When this fails, `header` is null.
- `canonical`: this is the block we hold at that height, and the stored block above it, if any, names it as `prevblockhash`, the rule `/proof` uses. The highest block has nothing above it yet.

Rely on a header only when both are true.
The check is made on every read, so the answer rests on the header's own bytes rather than on how the row got there.

These cover the headers this index holds, from one node, up to `meta.tip_height`.
`meta.missing` names heights in the range below the tip that we don't hold, and `meta.next_from` is where to carry on.
Proof of work takes `bits` from the header itself and doesn't work out what `bits` should be at that height, so we trust our node for that and for which fork is longest.
Reads go by the unique height index and select the header's columns only, never `tx`.
