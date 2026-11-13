# Big blocks, big transactions

*Bitblocks, 2026-11-12.
What one stuck block taught us about reading Bitcoin SV at its real size.*

Bitcoin SV lets blocks and transactions be large.
Since the Genesis upgrade in 2020, miners set the block size themselves, and a single transaction may be up to 1 GB by consensus (the node's default policy is 10 MB, which miners raise).
Most blockchain software was written for a world of 1 MB blocks and transactions of a few hundred bytes.
This week a single block showed us where Bitblocks still carried that assumption, and how to read the chain as it really is.

## Two blocks, the same size

Bitblocks counts gifts to its donation address, and to show them soon after they confirm, it reads the newest blocks itself, ahead of the sync.
Most blocks near the tip are small, but some are not, so we built a streaming reader: it reads a block from our node as the bytes arrive, parses each transaction as soon as it is complete, and checks the merkle root at the end.
Its memory stays at about 2 MB whether the block is 40 MB or 160 MB, because it never holds more than the transaction it is assembling and one partial hash per level of the merkle tree.

The first large block it met was 971,506: 143.7 MB, holding 616,080 transactions.
It streamed without trouble.

Nineteen blocks later came 971,525: 145.9 MB, nearly the same size, but holding only 367 transactions.
Four of them were 29 to 43 MB each, 98% of the block between them.
It failed every time we tried: 50 times over 26 hours, each with the connection closed before a single byte arrived.

## Following the wrong lead

A connection closed before any bytes looks like the server's doing, so we suspected the node: an HTTP timeout while it prepared a large response, or a limit on response size.
We wrote to the team that runs the node, asking for the block's size, its log and its settings.

Then we did what we should have done first, and made the failure describe itself.
Every streamed failure now reports how many bytes arrived and how long it took, because a stale connection, a server timeout and a size limit each leave a different mark.
The next failure carried neither number.
The streaming reader hadn't failed at all: the block had never reached it.

## The real cause: counting transactions to guess size

Before streaming a block, Bitblocks asks whether it is small enough to fetch whole, under a 32 MB cap.
A block's header doesn't carry its size, so when the size is unknown, the check fell back to counting transactions: 20,000 or fewer meant small.

That rule held for years of ordinary blocks.
It failed on 971,525, whose 367 transactions made a 145.9 MB block.

So we fetched it whole.
The node's REST interface stopped at our 32 MB cap, as designed.
Then a fallback written for nodes with REST switched off asked for the same block over RPC, as hex: twice the size, with no cap.
The node dropped that response, and each attempt risked hundreds of megabytes in our own memory.

Block 971,506 had escaped this only because its 616,080 transactions tripped the count rule and sent it to the streaming reader.

## What we changed

- **A block over the cap is never fetched again as hex.**
  The RPC fallback now runs only when REST is unavailable, never because a block is too large; "too large" is its own answer, and the block streams.
- **Size is known from bytes, not inferred from a count.**
  When a header carries no size, the capped fetch finds out, and anything over the cap goes to the streaming reader.
- **Failures say how far they got.**
  Bytes and seconds at the moment of failure, kept with the block, shown in the figures that depend on it.
- **Retries back off.**
  A block that keeps failing is tried after 1, 2, 4 … minutes, up to an hour, so a reader that can't succeed doesn't keep asking a node to load 146 MB.
- **Nothing counts until it's verified.**
  A streamed block's transactions are only used once its txids rebuild the header's merkle root; an interrupted read leaves no trace and is read again.

## The second miss: a mock that was too tidy

Our first fix didn't take on production.
It matched the error `:body_too_large`, which is what our test double returned for a block over the cap.
The real client wraps it as `{:connection_error, :body_too_large}`, so on production the old fallback still ran.
The tests passed because the mock was cleaner than the thing it stood in for.

The second fix matches the real shape, and the mock now returns exactly what the real client does.
We checked that the new tests fail without the fix before shipping it.
A test double is only as good as its fidelity to the real thing, and the error shapes matter most, because errors are where the fallbacks run.

## Two kinds of big

The lesson we're keeping is that a big block comes in two shapes, and each breaks different code.

**Many small transactions** stress counting: a list of 616,080 txids, a row per transaction, a merkle tree with hundreds of thousands of leaves.
These call for streaming merkle roots, batched writes and per-row costs kept small.

**A few huge transactions** stress size: a single 43 MB transaction has to fit in memory whole, as raw bytes and never doubled into hex or JSON, and it takes time to move, so timeouts belong to chunks rather than to the whole request.
These call for a per-transaction maximum stated plainly (ours is 256 MB, and a larger one fails the block loudly rather than being skipped), and for never guessing size from anything but bytes.

Large transactions have been rare on BSV until recently, so code that assumed otherwise could run for years before meeting one.
They are part of the chain now: files, data sets and applications carried in a single transaction.
An explorer that reads the chain as it is has to be ready for both kinds of big, and has to say plainly how far it has read when it isn't.

## Where it stands

The second fix deployed at 00:44 UTC on November 13.
At the next scheduled try, 01:12 UTC, block 971,525 went to the streaming reader and was read, its merkle root verified.
The scan then caught up on the 374 blocks queued behind it, through 971,899, in about fifteen minutes, and it keeps pace with the tip.
Our sponsor figures now count gifts in those blocks, and say how far they reach.

The streaming reader is the first half of https://github.com/afomi/bitblocks/issues/66; the sync will use it for its own large blocks next.
