# The 495 Tardinians were transfers

2026-11-02 · Status: `observed`.

## Finding

There are 999 Grand Tardinians, not 1,494.
The extra 495 in our earlier count were later locations of the same items, counted as if they were mints.
There is no second set of Tardinians, test or otherwise, in this search.

## How it happened

Issue #30 recorded "1,494 items in 1,453 mint txs, blocks 839,715 to 972,034; 496 items have moved".
Those figures came from GorillaPool's inscription search, which returns one row per outpoint.
A row is written each time an inscription moves, so a search on a collection grows as its items trade.

Asked again on 2026-11-02, the search returned 1,496 rows:

| Rows | Count | Check |
|---|---|---|
| Origin equals outpoint: a mint | 999 | The same 999 origins we prove on the mint chain |
| Origin differs: a later location | 497 | Every one is on a trail we traced ourselves |

The later rows belong to 222 items, and one item has 10 of them.
So 496 was a count of moves, not of items that moved.
The total went from 1,494 to 1,496 because two more moves happened, which is the behaviour you'd expect from transfers.

## The real collection

- 999 items, numbered 1 to 999, with no gaps or duplicates.
- 999 mint transactions, one item each, from 2024-04-11 to 2024-04-13 (blocks 839,715 to 840,020).
- Every item is an SVG that stacks exactly 6 trait inscriptions.
- Minting stopped at item 999, whose transaction has no contract output to carry the chain on.

## Method

1. Query `https://ordinals.gorillapool.io/api/inscriptions/search` with the MAP `subTypeData.collectionId`, paging at 300.
2. Split rows on `origin.outpoint == outpoint`.
3. Compare the origins with `GET /api/v1/collections/grand-tardinians/items`, and the later txids with each item's `trail`.

## What this doesn't show

- **Fringe testing.** Mints that never named this collection id wouldn't appear in this search, so a test run under another id isn't ruled out.
- **Full agreement on movement.** We trace 239 items as moved, and the search shows 222.
  All 222 are in our set; the other 17 were not examined.
