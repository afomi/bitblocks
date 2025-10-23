# PSBTs (Partially Signed Bitcoin Transactions) for Designers

Partially Signed Bitcoin Transactions (PSBTs) let multiple parties collaborate on a single payment or contract without handing over private keys. Think of them as structured envelopes that move a draft transaction through review, signing, and final broadcast. This guide frames PSBTs in product terms so designers can model the collaboration flow in Bitblocks or other Bitcoin interfaces.

## Plain-language core

- **Transaction skeleton** – Inputs, outputs, and metadata travel together; signatures can be missing or partial.
- **Stages instead of states** – A PSBT can be *proposed*, *funded*, *signed*, *finalised*. Any participant adds new data in-place.
- **Deterministic data blob** – The file is a standardised binary/JSON object; people pass it over chat, email, QR, or APIs without losing information.
- **Safety boundary** – Private keys never leave the signer. Each signer verifies the draft before adding their signature.

## Why designers should care

- **Multi-actor collaboration** – PSBTs are for situations where the payor, counterparty, and coordinator live in different apps. UX must show who still needs to sign.
- **Offline-friendly UX** – Since the object is portable, users can save, download, or scan PSBTs; your interface should make these transitions obvious.
- **Transparency in critical flows** – PSBTs expose script conditions, fees, and change outputs. Surfacing these details clearly builds trust for large-value or escrow flows.

## Anatomy cheat sheet

| Component | Meaning | Designer hint |
| --------- | ------- | ------------- |
| Inputs | UTXOs being spent; each carries scripts, pubkeys, and partial signatures. | Display origin (txid, value) and signature status per signer. |
| Outputs | Where funds go; includes locking scripts or addresses. | Highlight change vs. payment outputs; warn if amounts don’t match expectations. |
| Global section | Network, version, extended keys, proprietary fields. | Show network (main/test), descriptor fingerprints, or application metadata. |
| Signatures | Stored per input; multiple partial signatures can co-exist. | Progress indicator showing % of required signatures collected. |

## Can PSBTs be passed around?

Yes—passing PSBTs is the *intended* workflow. Key properties:

- **Portable** – Encode as Base64, QR, NFC, or attach as a `.psbt` file. Anyone can import into their wallet, add signatures, and export again.
- **Composable** – A coordinator can merge two PSBTs (e.g., buyer adds inputs, merchant adds outputs) as long as there are no conflicts.
- **Upgradable** – Additional metadata can be appended by subsequent participants without invalidating earlier signatures.

Design implication: treat PSBTs like shareable “tasks.” Provide clear affordances to export/import, track versions, and verify nothing was altered unexpectedly.

## Suggested user flow

1. **Draft** – User selects outputs and fee; the interface saves a PSBT draft and offers downloadable/QR share options.
2. **Fund** – Counterparty adds inputs or change outputs; the app flags new data and revalidates totals.
3. **Collect signatures** – Each signer loads the PSBT, reviews the summary (amounts, addresses, scripts), and approves. UI should log signer identity and timestamp.
4. **Finalise** – Once all required signatures exist, the wallet finalises the PSBT and broadcasts the full transaction. Archive both the final transaction ID and the last PSBT for audit.

## Visual cues

- **Signature timeline** – Ordered avatars or badges for each required signer with “pending/signed/final” states.
- **Diff view** – When a PSBT comes back from another party, show the delta (new inputs, updated fees) before the user consents.
- **Integrity badge** – Display the PSBT fingerprint (hash) so collaborators can confirm they’re reviewing the same document.

## Edge cases to represent

- *Expired inputs* – An input may become invalid if spent elsewhere; highlight with explicit warnings.
- *Fee adjustments* – Coordinators might bump fees; ensure the UI calls attention to net amount changes.
- *Script reveals* – Complex contracts may reveal redeem scripts during signing; surface those details for audit.

## Content strategy checklist

- Plain-language labels (“Needs Alice’s signature”) alongside the technical fingerprint.
- Allow copy/paste and download; don’t trap the user in a single modal.
- Provide a “View raw PSBT” toggle for engineers, but keep the main path visual and approachable.
- Encourage storing signed PSBTs in versioned history (TXT tape or similar) so disputes can be resolved.

## Designer takeaway

PSBTs are collaborative envelopes. Design for hand-offs, transparency, and auditability: make it easy to share, review, and complete these envelopes without exposing keys. When the experience feels as natural as reviewing a doc with tracked changes, teams will trust Bitblocks for their multi-party Bitcoin workflows.***
