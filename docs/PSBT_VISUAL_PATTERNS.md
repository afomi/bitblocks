# PSBT Visual Patterns & Trust Affordances

Designing PSBT (Partially Signed Bitcoin Transaction) workflows feels a lot like crafting a collaborative envelope system. These notes capture visual ideas and trust cues we can lean on while keeping verification tools within reach.

## Envelope metaphors

- **Progress lane** – Render each PSBT as a card sliding across a Draft ➝ Funded ➝ Signed ➝ Finalized rail. Each lane section hosts signer avatars with progress rings; empty rings show remaining signatures.
- **Layered envelope** – The face of the card shows headline data (amounts, recipients). Swiping or expanding reveals the “inside” (inputs/outputs, scripts), reinforcing that collaborators add inserts instead of rewriting the whole document.
- **Seal stack** – Treat signatures as wax seals on the envelope flap. Seals include signer fingerprints + timestamps; translucent placeholders mark pending signers. Hover/tap reveals SIGHASH summary and device info.
- **Literal wrapper** – Reference the “HTTP wrapper ⟶ bitcoin transaction ⟶ wallet signature” visual (see `bitcoin-envelope.png`) when introducing PSBTs so designers internalise the nested-envelope mental model we want to evoke in UI.
- **Tracked changes pane** – Every revision returns with a diff: green additions, red removals, footnotes for fee updates. A “review before signing” interstitial ensures “trust but verify” stays muscle memory.
- **Integrity badge** – A checksum chip or fingerprint icon sits near the primary action. Clicking shows the PSBT hash and raw data download—easy access for auditors without derailing casual users.

## SIGHASH badges (plain language)

| Flag combo | Friendly label | Notes for UX |
| ---------- | --------------- | ------------ |
| `SIGHASH_ALL` | “Full commit” | Default; signer binds every input/output. |
| `SIGHASH_ALL | ANYONECANPAY` | “Add funds / outputs locked” | Allows others to add inputs; outputs fixed. |
| `SIGHASH_NONE` | “Inputs only” | Outputs can still change—warn users clearly. |
| `SIGHASH_SINGLE` | “Pair commit” | The input’s matching output is locked; others may change. |
| `ANYONECANPAY` variants | “Collaborative funding” | Highlight that only this signer’s inputs are committed. |

Badge placement: near each signature seal, with tooltip that expands to raw flag details (`ALL|ANYONECANPAY`) for power users.

## Trust-but-verify touchpoints

1. **Automatic checks** – After each edit, run fee sanity, address whitelist, and total matching tests. Surface results inline before the “Add signature” button.
2. **Review hash button** – One tap copies the PSBT fingerprint and SIGHASH summary; encourage storing it in TXT tape or comparing with counterparty output.
3. **Download artifacts** – Offer raw PSBT, change log, and final txid at every stage. Keep previous versions accessible for disputes.
4. **Activity sidebar** – Immutable timeline listing who touched the envelope, what changed, SIGHASH used, and device fingerprint (if available).

By pairing clear metaphors (envelope, seals, tracked changes) with SIGHASH-aware language, designers can keep PSBT collaboration intuitive while giving every participant the reassurance—and tools—to verify each step.***
