# Adoption Spectrum

A framework for thinking about use cases on a scalable public ledger, from simplest to most structurally significant.

## The spectrum

### 1. Pay (P2PKH)

One party sends value to another.
The ledger records the transfer.
This is how most people think about blockchain — digital cash.

At this level, a block explorer is a commodity.
Every chain has one.

### 2. Note (single-party record)

One party writes data to the ledger as their own record.
No counterparty needed.
The ledger is a timestamped, immutable notebook.

An OP_RETURN with a hash, a document reference, a status update.
The value isn't in the transfer — it's in the fact that the entry exists and can't be altered after the fact.

At this level, a block explorer becomes a **verification tool**.
Someone writes a record; anyone can confirm it exists, when it was written, and that it hasn't changed.

### 3. Prove (triple-entry accounting)

Two parties transact, and the ledger itself is the third entry that both can independently verify.
Neither party's books are the canonical record; the chain is.
Disputes reduce to "show me the transaction."

Invoices, receipts, contracts, and settlements become auditable without trusting either party's database.

At this level, a block explorer becomes **shared infrastructure**.
Two parties point at the same transaction as proof of their agreement.
The explorer isn't just a viewer — it's the neutral reference both sides use.

## What shifts along the spectrum

| | Pay | Note | Prove |
|---|---|---|---|
| **Who uses it** | Individuals | One organization | Two+ parties |
| **What matters** | Speed, fees | Immutability, timestamps | Verification, Merkle proofs |
| **Explorer role** | Viewer | Receipt checker | Neutral third book |
| **Product language** | "Explore the blockchain" | "Verify your records" | "Your auditable third book" |
| **API importance** | Low | Medium | High |

## Implications for product

Most adoption friction comes from people thinking blockchain is only column one.
Column two is dramatically simpler to adopt — you don't even need a counterparty.
Column three is where the real structural value lives for organizations.

A block explorer that only serves column one competes on features with every other explorer.
One that serves columns two and three becomes infrastructure that businesses depend on.

## Where this applies

This framing should inform positioning and communications across several projects, not just Bitblocks.
Any project that reads from or writes to the ledger sits somewhere on this spectrum.
The spectrum clarifies what each project's value proposition actually is.
