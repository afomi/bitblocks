# Merkle Proofs for Designers

These notes translate the “Merkle proof” idea into product language so teams can
craft UI that feels trustworthy. A proof answers a simple question: *“Can I
show, in a compact way, that this exact transaction appears in a particular
block?”* Bitblocks exposes Merkle data so lightweight instances (or end users)
can validate information without downloading the entire block.

## Why designers should care

- **Trust at a glance** – Visualising a proof lets someone see the difference
  between “Bitblocks says so” and “the blockchain says so.”
- **Progressive disclosure** – Proofs compress 1000s of transactions into a
  handful of hashes. Good UI hints at that compression without overwhelming
  users.
- **Consistency across tiers** – Full-node operators and lightweight
  subscribers share the same proof format. Consistent UI keeps cross-team
  collaboration smooth.

## Core ingredients

| Term | Plain-language summary | UI hint |
| ---- | ---------------------- | ------- |
| Transaction hash | Fingerprint of the user’s action (payment, note, etc.). | Treat as the “file” being verified. |
| Merkle tree | Binary tree of hashes that summarises every transaction in the block. | Imagine a tournament bracket that ends at the block header. |
| Merkle root | The single hash recorded in the block header. | Design as a “certified stamp” that users can recognise. |
| Proof path | Ordered list of sibling hashes needed to climb from the transaction up to the root. | Display as a stacked list; each step combines with the running hash. |

## Reading a proof flow

1. **Start with the transaction hash** – Highlight the item the user cares
   about (e.g., `txid`).
2. **Iterate through siblings** – For each hash in the proof path, combine it
   with the running hash (left or right matters) and re-hash. A simple diagram
   helps: current hash on the left, sibling on the right, new hash above.
3. **Compare with the Merkle root** – The final hash must match the block’s
   root. If it does, you’ve proven inclusion.

Design tip: animate or animate-like transitions across the three steps so
people feel the “climbing the tree” motion.

## Bitblocks-specific cues

- **Block context** – Always show the block height and header hash next to the
  root. Lightweight clients can cache headers; this reinforces that the proof
  ties back to persistent chain data.
- **Proof size indicator** – The proof length tells users how much of the tree
  they traversed. Consider a small badge like “8 hops” to communicate depth.
- **Human mode vs. export mode** – Designers can offer a toggle: one view for
  humans (diagram, checkmarks), another that reveals the raw JSON an engineer
  can paste into tooling.
- **Error states** – If a proof fails, copy Git’s conflict tone: highlight the
  offending step, suggest re-syncing headers, and surface the mismatched hash.

## Visual metaphors that work

- **Folder trail** – Each level in the tree looks like drilling deeper into a
  nested folder, reinforcing the “part-of-a-whole” concept.
- **Blueprint stamp** – Treat the Merkle root like an architect’s stamp of
  approval placed on the block header.
- **Progress bar** – A vertical progress indicator that fills as the proof is
  evaluated reinforces completion.

## Quick terminology cheat sheet

- **Merkle tree** – A “summary tree” where each parent hash covers both
  children.
- **Merkle root** – The top hash stored in the block header; changes if any
  transaction changes.
- **Sibling hash** – The partner hash combined with the current hash during
  verification.
- **Proof** – The ordered siblings and metadata needed to recompute the root.

## Next design opportunities

- Build a reusable component that consumes Bitblocks’ proof JSON and renders
  the flow outlined above.
- Add a LiveView “verify” mode so designers can test variants against real
  data from the Event Playground.
- Create onboarding slides for lightweight subscribers explaining why a proof
  is sufficient even when they don’t run a full node.
