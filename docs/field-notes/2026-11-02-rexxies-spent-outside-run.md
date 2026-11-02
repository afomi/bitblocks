# Thirty Rexxies spent outside Run

2026-11-02 · Status: `observed` for the spends, `inferred` for the cause.

## Finding

At least 30 of the 2,222 Rexxies were spent in 11 transactions that carry no Run payload.
In Run, a jig has to move through a Run transaction, so these 30 no longer exist as jigs.
One transaction, on 2025-08-19, took 14 of them at once.

A further 5 carry the same label and are not settled (see below).

## What happened

Rexxies were minted from 2022-12-21 (Rexxie #1, height 771,246).
The 30 were spent between 2024-12-19 and 2026-10-21.

| Spend | Date | Inputs | Rexxies | Total output (BSV) |
|---|---|---|---|---|
| `8dc8d16a673b` | 2025-08-19 | 209 | 14 | 169.55 |
| `5f5a85984600` | 2025-02-15 | 100 | 4 | 50.00 |
| `3a2758cc521d` | 2025-07-22 | 731 | 3 | 0.12 |
| `aac2c6582e80` | 2025-07-10 | 31 | 2 | 0.06 |

The full list is in [the data file](data/rexxies-spent-outside-run-2026-11-02.json).

Each of the 30 sat in a 273-satoshi output, and 28 of them went into spends with one or two outputs, the shape of a wallet gathering many small coins.
That is what makes the likely cause a consolidation: software that saw 273 satoshis and not a Rexxie.

## Why it matters

The chain records the spend exactly, and records nothing about what was lost.
A plain explorer shows a routine consolidation.
Seeing the loss takes an index that knows what the coin was.

## Method

1. List items with `GET /api/v1/collections/rexxies/items` and keep `trace_reason` values beginning "spent outside Run".
2. Read each spending transaction, and confirm no output carries a Run payload (`OP_RETURN` with the `run` prefix).
3. Read the spent output's value from the transaction before it.

## What this doesn't show

- **Intent.** A consolidation may be deliberate, and someone may have wanted rid of these.
- **Who.** None of the spends returned funds to the holder's own address, which fits a wallet using fresh addresses and also fits a change of owner.
- **Value.** Nothing here says what any item was worth.

## Open: five more

Rexxies #128, #316, #351, #551 and #611 are labelled the same way, but each sat in a 1-satoshi output.
Several of their spends have many outputs, or few inputs, and don't look like consolidations.
For four of them the transaction before has its Run payload at output 1, not output 0.
Our trace may have followed the wrong output, so these are not counted as destroyed.
See #46.
