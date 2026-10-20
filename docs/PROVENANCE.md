# Provenance, Attribution, and AI Training Data

*Design & vision doc — 2026-07-13.*
*Captures a line of thinking from conversations about AI, economics, legality, and blockchain: how individuals get credit (and eventually compensation) for contributions used in AI training, and what role the chain plays.*

## The Opportunity

AI training consumes human contributions at scale with no provenance trail and no attribution mechanism.
If contributions carried verifiable authorship and training runs carried verifiable manifests, credit — and payment — could flow back to contributors.
This requires that contributions not be anonymous.
Pseudonymity is the workable middle ground: attribution accrues to a key, and the key's holder chooses if and when to bind it to a real identity.

This decomposes into three questions, treated in order:

1. What data goes on chain, and what should stay off?
2. How is attribution expressed — hash, real ID, or pseudonymous ID?
3. How does a training pipeline ingest this so attribution can actually be calculated?

## 1. What Goes On Chain

### The hash-only baseline

The minimum viable on-chain record is a commitment: `sha256(body)` plus a signature and a timestamp.
This proves three things forever: the content existed at this time, in exactly this form, and this key vouched for it.
It proves nothing about availability — if the body disappears, the claim becomes unverifiable and attribution dies with it.
A hash without a retrievable body is a receipt for a package that may never arrive.

So every hash-only anchor needs a paired **availability story**: where does the body live, who replicates it, and what happens when the original host is gone?

### The spectrum

| Tier | On chain | Availability | Use when |
|------|----------|--------------|----------|
| Hash anchor | 32-byte commitment + signature | External (URL, IPFS, archive) | Private or large content; minimum footprint |
| Hash + pointer | Commitment + URI + content-type | External but discoverable | Public content you host |
| Encrypted body | Ciphertext on chain, keys off chain | Permanent (ciphertext), revocable (keys) | Content needing erasure semantics — destroying the key is "crypto-shredding" |
| Full body | Entire content on chain (B:// style) | Permanent, guaranteed | Public contributions meant to outlive their author's hosting |

BSV's large-block capacity makes the full-body tier actually viable, which most chains cannot offer.
This is the same argument as [TX_CDN.md](TX_CDN.md): the chain as immutable, content-addressed origin.

### What should stay off chain

- **Personal data.**
  Immutability collides with erasure rights (GDPR and successors).
  Note that even a *hash* of low-entropy personal data (email, phone, name+DOB) is brute-forceable and legally still personal data.
  Commitments over PII should be salted (HMAC with a discardable key) so the commitment is only meaningful to someone who holds the salt.
- **Content you lack rights to publish.**
  Anchoring a hash of a copyrighted work is fine (you're publishing 32 bytes you computed); publishing the body is redistribution.
- **Anything you might need to retract.**
  The encrypted-body tier exists precisely for content whose *existence proof* should be permanent but whose *readability* should be revocable.

### The rule of thumb

Put **claims** on chain and keep **content** wherever its legal and privacy profile demands — but make the claim's verification path explicit.
A claim is: this hash, signed by this key, at this time, under these license terms, retrievable here.

## 2. Attribution Identity

### Three options, one primitive

All three attribution modes reduce to the same primitive: a signature over the content hash.
What differs is what the verifying public key is bound to.

- **Real ID**: key is bound to a legal identity via an attestation (an identity certificate signed by an issuer).
  Maximum credit portability into the legal/economic world; maximum exposure.
- **Pseudonymous ID**: a persistent keypair with no binding.
  Reputation and attribution accrue to the key across many contributions.
  This is Satoshi's own model — the strongest existence proof that pseudonymous attribution works at civilizational scale.
- **Hash ID**: a one-time key or bare commitment per work.
  Unlinkable even across the author's own works; attribution exists but reputation cannot compound.

### Pseudonymity is the right default because it's upgradeable

The critical property: a pseudonym can be bound to a real identity *later*, without rewriting history.
The author (or an attestation service) publishes a signed statement linking key → identity, and every prior contribution retroactively gains real-world attribution.
The reverse direction — anonymizing a real-ID trail — is impossible.
So the conservative choice at publication time is pseudonymous, with identity as a deferred, optional, one-way upgrade.

This also creates a natural market structure: pseudonyms with long contribution histories are *valuable*, which incentivizes key hygiene and consistent use — the same dynamic that makes brands behave.

### Existing rails

The BSV ecosystem already has the pieces: Bitcom namespacing, AIP (Author Identity Protocol) for signing content with an identity key, paymail for human-readable key discovery.
[EVENT_DRIVEN_OBJECT_ORIENTED_BITCOIN.md](EVENT_DRIVEN_OBJECT_ORIENTED_BITCOIN.md) already sketches Bitcom + AIP envelopes; an attribution record is the same envelope with a license field.
For bitblocks this is one more parser in the existing `ProtocolRegistry` pipeline — the read side is largely built.

### A contribution record, concretely

```
OP_RETURN
  <protocol prefix>          # e.g. a Bitcom namespace for attribution
  <sha256 of canonical body> # the commitment
  <content-type>             # text/markdown, image/png, ...
  <uri>                      # where the body lives (or empty if body is on-chain)
  <license>                  # e.g. "train-with-attribution", SPDX-style
  <author pubkey>
  <signature over the above>
```

The license field is what makes this *training-relevant* rather than just timestamping: it's a machine-readable grant, stated by the keyholder, at publication time, immutably.
Today's training-data disputes are precisely about the absence of this record.

## 3. Ingestion and Training Attribution

This is the hardest part, and the honest framing is three separate layers that are often conflated:

### Layer 1 — Provenance: *was this contribution in the training set?*

Solvable today with boring, robust machinery.

The training pipeline:

1. Reads contribution records from the chain (bitblocks' role: index and serve them, exactly as it serves protocol feeds now).
2. Fetches each body from its URI (or the chain itself).
3. **Verifies the hash matches** — rejects anything that doesn't.
   This step is the entire integrity guarantee, and it's cheap.
4. Filters by license field — only contributions granting training rights enter the corpus.
5. At training time, builds a **manifest**: the sorted list of included content hashes, rolled into a Merkle root.
6. Publishes the manifest root on chain as its own signed transaction: "model M, training run R, trained on exactly this set."

Now any contributor can obtain a Merkle proof of inclusion (or verify exclusion) against the published root.
bitblocks already implements exactly this math for transactions (`MERKLE_PROOFS.md`, `MerkleVerifier`); a training-manifest proof is the same verifier pointed at a different tree.

**The canonicalization trap** (this will bite anyone who builds this): training pipelines normalize — strip whitespace, re-encode, deduplicate, chunk.
Every transform changes the bytes and breaks the hash.
The fix is the git model: hash the *canonical source* form, and record transforms as a lineage DAG (`derived_hash → transform_id → source_hash`), so attribution survives the pipeline.
This is the same content-addressed-plus-lineage idea as [REUSABLE_SCRIPTS.md](REUSABLE_SCRIPTS.md), applied to documents instead of scripts.

### Layer 2 — Influence: *how much did this contribution shape the model?*

The research frontier, advancing on its own trajectory (as assumed) — the chain design should stay agnostic to it.

Current approaches, roughly in order of tractability:

- **Inclusion counting**: flat or size-weighted credit for being in the manifest.
  Trivial, gameable by spam, but a workable v1 combined with curation.
- **Influence functions / TRAK-style estimators**: approximate, per-example, "how much did this training example move the model's behavior on this output."
  Active research (Anthropic among others has published here); costs are falling but per-example attribution across billion-document corpora remains expensive and approximate.
- **Data Shapley values**: the theoretically principled answer (marginal contribution over all subsets), computationally prohibitive at scale; approximations exist.
- **Inference-time attribution (retrieval)**: sidestep training-time influence entirely — a RAG system *cites the exact documents it retrieved* for each response.
  Attribution is exact, per-use, and cheap.

The pragmatic bet: **inference-time citation is where per-use compensation becomes real first**, because it's exact rather than estimated, and it maps naturally onto micropayments — a satoshi-denominated royalty per retrieval fits BSV's economics and connects directly to [PAYMENT_CHANNELS.md](PAYMENT_CHANNELS.md).
Training-time influence estimation matures in parallel and can be layered on later without changing the on-chain records, because the records only claim provenance, not influence.

### Layer 3 — Compensation policy: *what do you pay for?*

A policy choice sitting on top of the other two layers, not a technical property:

- pay per **inclusion** (flat, from a training-run royalty pool, split by manifest)
- pay per **use** (per retrieval/citation at inference time)
- pay per **influence** (weighted by Layer-2 estimates, as they mature)

The design principle: keep the on-chain record *policy-free*.
It states authorship, integrity, timestamp, and license — facts.
Compensation formulas will change with the research; the facts they compute over should not.

## Where bitblocks and qart Sit

Per the established boundary: **qart writes, bitblocks reads**.

- qart: compose and sign contribution records (author-side), and eventually the royalty payout transactions.
- bitblocks: parse and index contribution records (a `ProtocolRegistry` parser), serve attribution queries (`who signed this hash`, `all contributions by this key`, `manifest for training run R`), and serve Merkle inclusion proofs against published manifests.

Nothing in this doc requires new infrastructure categories — it's the existing envelope-parsing, content-addressing, and merkle-proof machinery pointed at a new protocol.

## Open Questions

- Spam and sybil pressure: pseudonymous keys are free; what makes a contribution *worth* crediting — curation layers, stake, reputation-weighted inclusion?
- Plagiarism inversion: signing a hash proves you *had* the content at time T, not that you *authored* it; earliest-timestamp-wins helps but doesn't fully solve it.
- Canonicalization standard: which normal form gets hashed, per content type? Needs a spec (candidate for [DATA_DICTIONARY_SPEC.md](DATA_DICTIONARY_SPEC.md) treatment).
- License vocabulary: SPDX-style identifiers for training grants don't quite exist yet; who defines `train-with-attribution` v1?
- Erasure vs. manifest immutability: if a contributor revokes (crypto-shredding), the manifest still proves past inclusion — is that acceptable, and to which regulators?
