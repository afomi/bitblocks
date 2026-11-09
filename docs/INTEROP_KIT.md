# Interoperability kit

The thing that's great if we all build it is a payment that travels with its own proof.
Any wallet can send it, any app can accept it, and anyone can check it without asking a company.
The specs exist: BEEF ([BRC-62](https://github.com/bsv-blockchain/BRCs/blob/master/transactions/0062.md), [BRC-96](https://github.com/bsv-blockchain/BRCs/blob/master/transactions/0096.md)), Atomic BEEF ([BRC-95](https://github.com/bsv-blockchain/BRCs/blob/master/transactions/0095.md)), BUMP ([BRC-74](https://github.com/bsv-blockchain/BRCs/blob/master/transactions/0074.md)) and the wallet interface ([BRC-100](https://github.com/bsv-blockchain/BRCs/blob/master/wallet/0100.md)).
What's missing is proof that they work together, and this kit is a first step towards it.

Status: first version, draft, built 2026-11-05.

## What's in the kit

- **Vectors:** [`GET /interop/vectors/v1.json`](https://bitblocks.app/interop/vectors/v1.json), open to anyone with no key, and served from memory with no database.
- **A check page:** `/start/interop`, admin only until published ([DEMOS_CAMPAIGN.md](DEMOS_CAMPAIGN.md)): paste hex or upload a file, and see each transaction's status.
- **This pattern:** what a sender and a receiver each do, also on the page.

## What it claims

Bitblocks verifies inclusion in a block against its headers.
It does not check scripts, double spends or payment terms.
Signatures, input amounts and token validity are outside it too.
`Bitblocks.Chain.BeefVerifier` makes the judgement, and every answer lists these under `not_checked`.

## What has been tried

Interop has been tried against one SDK, `@bsv/sdk` 2.4.0, in a one-off run, and against no live wallet.
Nothing here says any wallet or project conforms to this kit or endorses it, and we keep no list of passing projects.
In that run, on 2026-11-05, the SDK read every vector marked valid and agreed on which proofs hold.
It differs where vectors are marked `hardening`, and it reads `refused-out-of-order` rather than refusing it.
That is one run of one version, and it isn't a conformance result.
Results from other implementations are welcome, in the implementer's own words.

## The vectors

The file is `priv/data/interop/vectors_v1.json`, built by `scripts/interop_vectors_v1.exs` with its expected outcomes written by hand.
`test/bitblocks/interop/vectors_test.exs` runs every vector through `Beef.Reader` and `BeefVerifier`, and through the database path where the headers are real, so the file can't drift from the code.
The same test checks that the script still builds the published file.

To rebuild it after changing the script:

```sh
MIX_ENV=test mix run --no-start scripts/interop_vectors_v1.exs --write
```

Each vector gives `id`, `kind` (`beef` or `bump`), `valid`, `basis`, `sources`, `hex`, `headers_held` and `expected`.
`expected.outcome` is the result to match, and `expected.reason` is the name Bitblocks uses, so another reader's may differ.
`headers_held` lists the heights to treat as held, looked up in the file's own `headers`.

`basis` names the BRC whose rule the vector exercises, or says `hardening`.
Hardening is a stricter reading we apply where a spec is silent or leaves room, so a reader can differ there and still follow the spec.

Within v1, a vector's id, bytes and expected outcome stay as they are, except to correct a mistake, which the version number will show.
New vectors raise the minor version.
A change to what outcomes mean gets a new file.

### Where each set came from

| Source | Vectors | How we got them | Licence or terms |
| --- | --- | --- | --- |
| BRC-62's example | `brc62-example`, and the base of others | Copied byte for byte; checked against the BRC's text on 2026-11-05 | The BRC states it is licensed under the Open BSV license, with no version named |
| BRC-74's example | `brc74-example` | Copied byte for byte; checked against the BRC's text on 2026-11-05 | The same statement in BRC-74 |
| `@bsv/sdk` 2.4.0 | `brc62-atomic-sdk`, `brc62-v2-txid-only-sdk`, `two-input-v2-sdk`, `two-input-atomic-sdk` | Output of `Beef.toBinaryAtomic` and `Beef.toBinary`, run once | Package ships under the Open BSV License Version 6, © BSV Association |
| `@bsv/sdk` 2.8.11 | `two-input-v1-sdk` | A test vector shared with us, whose note says this version generated it; we did not regenerate it | The same licence, and the same text in that package |
| WhatsOnChain | `mainnet-bump`, and the base of the `mainnet-*` vectors | Fetched 2026-10-28 from `/tx/<txid>/hex` and `/tx/<txid>/proof/bump` | Public chain data; WhatsOnChain is named as the source and hasn't reviewed this kit |
| Bitblocks | The rest, composed or crafted by the script | The script says exactly how | MIT, as this repository |

The two-input vectors use a test merkle root at height 912117.
The real block at that height has a different root (checked against WhatsOnChain on 2026-11-05), so these read `failed` against real headers.
The file marks that header `synthetic`, and the kit uses it in place of the real one.
Crafted vectors sit at heights above the chain, for the same reason, and they run through `evaluate/3` because a made-up root has no header to store.

These notes record provenance, and they aren't legal advice.

## What a conforming sender does

- Sends the payment as Atomic BEEF, with the payment as the subject.
- Includes every unconfirmed ancestor, back to transactions with a BUMP.
- Puts parents ahead of children, and ends with the payment.
- Leaves out anything outside the subject's ancestry.
- Writes each VarInt in its shortest form, with nothing after the end.

## What a conforming receiver does

- Reads the bytes strictly, and refuses anything that doesn't parse.
- Checks every BUMP's root against headers it trusts, by its own choice of source.
- Treats unknown as not yet, and failed as no.
- Runs the payment's scripts against the outputs it spends, and adds up the amounts.
- Confirms the outputs pay what was agreed, to whom it was agreed.
- Sends the payment to the network, and keeps the BEEF with its record.

## One payment, end to end

1. The receiver states the terms: the amount, the script to pay, and a random salt.
2. The wallet builds the payment and produces Atomic BEEF without sending it.
   A BRC-100 wallet returns this as `tx` from `createAction`, and needs `options.noSend`, because by default it sends the payment itself.
3. The wallet hands the bytes straight to the receiver, with no third party in between.
4. The receiver verifies against headers.
   The payment reads `anchored`, and each parent reads `proven` or `anchored`.
5. The receiver checks scripts, amounts and terms, then sends the payment to the network.
   If the network reports a conflict, the receiver stops here and issues nothing.
6. The receiver makes a payment evidence statement (BRC-237), and signs it with BRC-77 if it will travel.
   If it takes the payment, it adds a signed acceptance record naming the outputs it accepted.
7. Once the payment is mined, the receiver fetches its BUMP, checks again, and the payment reads `proven`.
   That produces a new statement, and the acceptance record stays exactly as it was signed.

Keep the BEEF as received.
A later BEEF carries the BUMP and has different bytes, so each statement describes the evidence it was made from.

## A receipt is two things

BRC-237 defines the evidence half, and this kit follows it.
It's new, and by its own account it hasn't been run on a live chain.
Bitblocks makes statements distance only (`Bitblocks.Chain.PaymentEvidence.make/3`, #64): the walk, anchors with conditions (a) to (e), distances, status, conflicts as observed, and the canonical bytes, with none of section 2.3's checks run, so `validated` is empty and `lowestFeeRate` null.
It reads a BEEF, V1 or V2, bare or Atomic, or our own records with BRC-74 or Electrum-form paths.
Every statement and maker refusal in BRC-237's test vectors runs in `test/bitblocks/chain/payment_evidence_test.exs` from a fixture extracted from the spec, each material checked against the length and SHA-256 the spec gives.
The eight vectors whose maker validated nothing match byte for byte; the other eight match once their validated lists are those of a maker that ran no check.
Not yet: an endpoint or page that offers statements, and BRC-77 signing.
No published format covers acceptance, so the acceptance record is our candidate, `interop-kit/payment-acceptance/v0`, until a second implementation reads it.

Evidence says what was checked.
Acceptance says what the receiver took as payment.
Neither says the payment will be mined.
Bitblocks can verify a payment, and only the receiver can accept one.

The acceptance record is RFC 8785 canonical JSON, signed with BRC-77 for anyone to verify, with the signature carried beside the exact bytes:

| Field | Type | Meaning |
|---|---|---|
| `version` | string | `interop-kit/payment-acceptance/v0` |
| `acceptedBy` | string | The receiver's identity key, compressed hex, and the BRC-77 signer |
| `network` | string | CAIP-2: `bsv:mainnet` or `bsv:testnet` |
| `outputs` | array | `{"txid", "vout", "satoshis"}` for each output accepted as this payment, sorted by `txid` then `vout` |
| `termsHash` | string or null | SHA-256 of the exact terms bytes from step 1 |
| `evidenceHash` | string or null | SHA-256 of the exact bytes of the BRC-237 statement it relied on |
| `acceptedAt` | integer | Unix seconds, the receiver's own word |

The signed `outputs` are what say who was paid: a BRC-29 output can't show that from the chain alone.
The salt in the terms stops anyone guessing what the hash covers.
There is no payer, order id or status here.
The first two stay private, and a status would be out of date the moment it was signed.
We left out a hash of the BEEF, because those bytes change once the BUMP arrives, and the txid already commits to the payment.

Anyone holding the record, its terms and the BEEF can check the signature, match the outputs to the transaction, and hash the terms, then make their own statement from their own headers.
A payment that a mined conflict has spent reads as void from that conflict's proof, whatever the record says.
The record stays true as a statement of what was accepted.

## Our statuses and BRC-237

| Ours | BRC-237 |
|---|---|
| `proven` | The payment is in `anchors`, and `status.event` is `mined` |
| `anchored` | `fullyAnchored` is true, and the payment is in `unconfirmed` |
| `unknown` | Usually `fullyAnchored` false with `unresolved` listed, though a BUMP at a height we don't hold is walked past there |
| `failed` | No statement: BRC-237 refuses rather than records a failure |

The words differ: a BRC-237 anchor is a transaction with a checked path, which we call `proven`.

## Anchored and proven

A fresh payment isn't in a block yet, so `anchored` is the best it can read, and that's the normal result.
It means the payment's inputs name transactions that, inside this BEEF, lead back to transactions in blocks.

Anchored doesn't mean accepted.
The scripts may not pass, an input may already be spent, and the network hasn't said anything yet.
It's the start of a receiver's work, and how much risk to take before `proven` is the receiver's call.

`proven` means the payment itself sits in a block under a header you rely on.
That is the strongest thing this check can say, and it still covers inclusion alone.

`unknown` is never a pass.
`failed` means the evidence doesn't hold against these headers.
That usually means it's wrong, and after a reorg a good payment's old path reads `failed` until the path is replaced.

## Known gaps

- Scripts, signatures, amounts and double spends aren't checked here, so an anchored transaction may still be invalid.
- `anchored` follows parents by txid, and doesn't look at the output index an input names.
- Headers come from one node, and we trust it for which chain is longest and what `bits` should be.
- A block's transaction count isn't in its header, so the check on a proof's shape rests on our node's word.
  The file gives `tx_count` where we hold one, and block 973110's is left out.
- BRC-95 doesn't say which byte order the subject txid takes, so the vectors follow the SDK's internal order, which BRC-237 section 2.1 also states.
- A BRC-237 statement here is distance only: no script, amount or lock time is checked, so it never validates a transaction or refuses one for failing a check.
- BRC-237 reads BRC-95 as permitting ancestors beyond a BUMP, while `Beef.Reader` refuses them, and neither has a vector settling it; the statement maker refuses them `MALFORMED`, as it does a VarInt not in its shortest form and a tx with no BUMP ahead of its parent.
- No acceptance record vectors exist yet.
- BRC-96 treats a txid-only entry as agreed between two parties, and a third-party check has no such agreement, so we answer `unknown`.
- The size and count limits in `Beef.Reader` have no vectors, because a limit is a reader's own choice.
- No live wallet has been tried, and one SDK run is a start rather than a result.
- The page's limits are per LiveView: a size limit and one check a second.
  Before it's published, note that a socket frame has no size limit of its own (`max_frame_size` is unset in the endpoint), and that a visitor can open several sockets.

## Further experiments

These aren't built.

- **BEEF-paid API calls:** a caller pays per request with Atomic BEEF, which fits consumption pricing, and the receiver's half is this kit's pattern.
- **A working-patterns list:** patterns that work today, each with a live example someone can open and check.
