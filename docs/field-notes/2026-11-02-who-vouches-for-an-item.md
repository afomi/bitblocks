# Who vouches for an item?

2026-11-02 · Status: `observed` for the two indexed collections, `open` for Zoide.

## Finding

"Verified" is not one claim.
An NFT is at least four claims, and each can have a different witness.
Within a single collection, some are enforced by miners and some rest on a file.

| Claim | Grand Tardinians (1Sat) | Rexxies (Run) | Zoide (1Sat, not indexed) |
|---|---|---|---|
| It belongs to the collection | Mint chain | Class chain | Open |
| What it is called and its traits | The inscription | A catalog file | The inscription |
| What it looks like | On-chain layers | A catalog file | The inscription |
| Who holds it now | Traced by sat position | Traced by Run payload | Not traced |

## Grand Tardinians: the contract chain

Each mint spends the previous mint's output 0 and carries the chain on, starting from the collection outpoint `f099182e…da04_0`.
For example, Grand Tardinians 998's mint carries a 45,293-byte contract at output 0, which the next mint spent.
Miners only accept that spend if the contract's script is satisfied, so a look-alike can name the collection and still not join the chain.
The MAP `collectionId` is the inscription's claim, and the spend is the proof.

The picture is on chain too, as 6 inscribed layers.

We have not read the contract's script, so we can't yet say what it requires beyond being spent.

## Rexxies: a split witness

Membership is as strong as Tardinians': each mint spends the class jig, from `12d8ca4b…0cc5_2`, in a Run transaction that calls `mint`.

The rest is weaker.
RelayX mints carry empty metadata and an encrypted image.
So a Rexxie's number, traits and picture come from a catalog exported from RelayX's own `content.js`.
That makes RelayX the witness for what a Rexxie is, and the chain the witness that it exists.
Bitblocks tags these traits `"source": "catalog"` so a reader can tell.

## Zoide: a claim, with a possible signature

We sampled 3 Zoide collections and 18 mints.
None of the 18 spends a chain link, so the Tardinian rule would reject them all.
The sampled inscriptions do name their collection, in MAP data after the inscription.
The bytes also contain the text `SIGMA` and a `BSM` address, and 4 of 5 collection roots show the same address.
No signature has been verified, so whether Zoide relies on this is unknown.

## Everything rests on Bitblocks at the end

Bitblocks publishes who verified each list, on what basis, and a `list_hash` a reader can pin:

| Collection | Items | Verified through height |
|---|---|---|
| Grand Tardinians | 999 | 840,020 |
| Rexxies | 2,222 | 771,256 |

Ownership also leans on WhatsOnChain today, because spends are looked up there and not from our own index.
A failed lookup is reported as unknown.

## What this doesn't show

- That the proof has stopped a real fake here: the Tardinians check found no impostors (see [the 495 note](2026-11-02-the-495-tardinians.md)).
- Anything about the many other collections on Zoide, Twetch, Rare Candy, or RelayX.

## Open question

Should a page show these four witnesses, in place of one "verified" label?
