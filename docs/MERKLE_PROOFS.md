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
This is not a BEEF body; that is #17.

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
