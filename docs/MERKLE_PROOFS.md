# Merkle Proofs

A Merkle proof answers a simple question: *"Can I show, in a compact way, that this exact transaction appears in a particular block?"*
Bitblocks exposes Merkle data (via `GET /api/v1/txs/:txid/proof`) so lightweight instances or end users can validate inclusion without downloading the entire block.

The proof is verified in-app by `Bitblocks.Chain.MerkleVerifier`, which rebuilds the Merkle root from the txid list (handling Bitcoin's odd-node duplication and little-endian byte order).

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

## Part 2 — Worked example: verify a proof on BSV testnet

This walkthrough shows how to generate and verify a Merkle proof for the transaction
`cad259eb2812b6d581c9d815227a501c616d0965c1c3bf9caf4aedfd1b1eb619` on the Bitcoin SV **test** network.
The same flow works whether you run a local testnet node or rely on a public API such as [WhatsOnChain](https://whatsonchain.com/).

> **Note:** the commands below assume `curl` and (optionally) `jq`. If you are offline, run them elsewhere and paste the outputs into Bitblocks.

### 1. Discover the containing block

```sh
curl https://test.whatsonchain.com/api/v1/bsv/test/tx/cad259eb2812b6d581c9d815227a501c616d0965c1c3bf9caf4aedfd1b1eb619
```

Among the JSON fields you will see `blockhash` and `blockheight`. Keep the `blockhash` — you'll use it to fetch the proof and the block header.

### 2. Request the Merkle proof

```sh
curl https://test.whatsonchain.com/api/v1/bsv/test/tx/cad259eb2812b6d581c9d815227a501c616d0965c1c3bf9caf4aedfd1b1eb619/proof
```

The response contains the sibling hashes (ordered leaf → root) and the transaction's position in the block's Merkle tree:

```json
{
  "merkle": ["<SIBLING_HASH_0>", "<SIBLING_HASH_1>", "..."],
  "block": "<BLOCK_HASH>",
  "pos": <TRANSACTION_INDEX>
}
```

If you operate a local node, `gettxoutproof` returns the same structure:

```sh
bitcoin-cli -testnet gettxoutproof \
  '["cad259eb2812b6d581c9d815227a501c616d0965c1c3bf9caf4aedfd1b1eb619"]' <BLOCK_HASH>
```

### 3. Fetch the block header for the Merkle root

```sh
curl https://test.whatsonchain.com/api/v1/bsv/test/block/hash/<BLOCK_HASH>
```

Extract the `merkleroot` field — that's the value the recomputed proof must match.

### 4. Verify the proof (Elixir)

Bitblocks ships `Bitblocks.Chain.MerkleVerifier` for this. The shape of the computation is:

```elixir
def verify?(txid, merkle_root, proof, index) do
  {final_hash, _idx} =
    Enum.reduce(proof, {hex_to_bin(txid), index}, fn sibling_hex, {acc_hash, idx} ->
      sibling = hex_to_bin(sibling_hex)
      combined = if rem(idx, 2) == 0, do: acc_hash <> sibling, else: sibling <> acc_hash
      {sha256d(combined), div(idx, 2)}
    end)

  Base.encode16(final_hash, case: :lower) == String.downcase(merkle_root)
end

# Hashes arrive big-endian from the APIs; reverse to little-endian before hashing.
defp hex_to_bin(hex), do: hex |> Base.decode16!(case: :lower) |> :binary.reverse()
defp sha256d(bytes), do: bytes |> :crypto.hash(:sha256) |> :crypto.hash(:sha256)
```

**Why the byte reversal?** Bitcoin stores hashes internally in little-endian byte order, while most APIs return big-endian hex.
Converting to little-endian before hashing makes the double-SHA256 rounds match the consensus implementation.

### 5. Visualise inside Bitblocks

With the proof verified, render it in LiveView: highlight the **leaf** (the txid), list each **sibling** with its left/right orientation, and show the **root** with a green check once the computed value matches.
Because the proof is environment-agnostic, lightweight deployments consume the same JSON a full node serves — keeping the UX consistent across tiers.
