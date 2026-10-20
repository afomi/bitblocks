# Concept Inventory

Domain vocabulary for Bitblocks.
Each concept maps to its source (personas or stories in PLAN.md) and its data model entity.

| Concept | Description | Related Personas | PLAN.md Features | Data Entity |
|---------|-------------|-----------------|-----------------|-------------|
| **Block** | A group of transactions confirmed together, identified by height and hash. | Explorer, Developer, Operator | 1, 13, 14 | `blocks` |
| **Transaction** | A signed transfer of value, containing inputs and outputs. Identified by txid. | Explorer, Developer, Operator | 1, 6, 9, 13 | `transactions` |
| **Input** | A reference to a previous output (UTXO) being spent, plus an unlocking script. | Explorer, Developer | 13 | `transactions.inputs[]` |
| **Output** | A new UTXO created by a transaction: a satoshi amount + locking script. | Explorer, Developer | 1, 13 | `transactions.outputs[]` |
| **UTXO** | An unspent transaction output — value available to be claimed. | Explorer, Developer | 1, 13 | `spend_index` (absence = unspent) |
| **Outpoint** | A pointer to a specific output: `(txid, vout)`. The canonical UTXO identifier. | Developer, Operator | 13, 15 | `spend_index.(txid, vout)` |
| **Spend** | The act of consuming a UTXO: records which outpoint was consumed by which input. | Developer, Operator | 13 | `spend_index` |
| **Coinbase** | The first transaction in a block, minting new BSV. Has no input outpoint. | Explorer, Developer | 13 | `transactions.coinbase` |
| **Locking Script** | (ScriptPubKey) Encodes the conditions under which an output can be spent. | Explorer, Developer | 13 | `transactions.outputs[].script` |
| **Unlocking Script** | (ScriptSig) Satisfies the locking script to authorize spending a UTXO. | Developer | 13 | `transactions.inputs[].script` |
| **Script Type** | Classification of a locking script: P2PKH, P2SH, OP_RETURN, etc. | Developer | 13 | `transactions.output_types` |
| **OP_RETURN** | A script type that embeds arbitrary data on-chain without creating a spendable UTXO. | Developer, Protocol Author | 6, 11, 12, 15, 18 | `transactions.output_types["op_return"]` |
| **Protocol** | A registered on-chain data format, identified by a Bitcom address (e.g. `15DHFx...`). Not a transaction instance — the format definition. | Developer, Protocol Author | 11, 12, 15, 18 | `protocols` |
| **Protocol Instance** | A specific transaction that conforms to a registered Protocol. Carries parsed data. | Developer | 11, 12, 15 | `protocol_instances` |
| **Protocol Detection** | The process of scanning a transaction's OP_RETURN for known protocol prefixes. | Developer, Operator | 11, 12, 15, 18 | `TransactionParser` |
| **Metanet Node** | A transaction that participates in the Metanet DAG: links to a parent tx and carries a name/content. | Explorer, Developer | 12 | `protocol_instances` (protocol=Metanet) |
| **MURL** | Metanet URL — a human-readable path derived from the ancestor chain of Metanet nodes. | Explorer, Developer | 12 | derived at query time |
| **BCat Head** | A BCat protocol transaction that lists chunk txids and file metadata (MIME type, filename). | Explorer, Developer | 18 | `protocol_instances` (protocol=BCat) |
| **BCat Chunk** | A BCat protocol transaction carrying a raw data segment identified by a `"c"` discriminator. | Developer | 18 | `protocol_instances` (protocol=BCat) |
| **Listing** | An OrderBook Protocol Instance representing a sell offer for a token UTXO. Carries pre-signed offer fields. | Explorer, Developer | 15 | `protocol_instances` (protocol=OrderBook) |
| **Token** | A BSV-20 Ordinal token identified by `token_id`. Multiple listings can exist for the same token. | Explorer, Developer | 15 | `protocol_instances.parsed_data.token_id` |
| **Settlement** | Implicit fill: when a listing's token UTXO is spent, the listing is marked `filled` — no explicit OP_RETURN required. | Developer, Operator | 15 | `spend_index` → `OrderBook.settle_spent_token_utxos/1` |
| **Sync State** | The phase a block is in: `pending → header_only → header_synced → txs_queued → txs_syncing → completed / failed`. | Operator | 14 | `blocks.sync_state` |
| **Sync Job** | An Oban worker run tracking headers or transaction fetches for a block range. | Operator | 14 | `sync_jobs` |
| **Shape Layer** | A GeoJSON-backed NFT with computed bounds and center. | Explorer | 3 | `ShapeLayer` (in-memory, no DB table) |
| **DID** | A Decentralized Identifier generated from a vCard, usable for on-chain profile claiming. | Explorer | 7 | no DB table — derived |
| **TXBox Transaction** | A staged outbound transaction managed for broadcast. Carries channel, tags, and MAPI response tracking. | Developer, Operator | — | `txbox_txns` |
| **Filter** | Declarative predicate over a transaction (prefix, MAP `app=`, script template hash, address set, height range). What you filter for is the application's chain-facing identity. | Application Operator, Developer | USE_CASES | proposed tag table |
| **Map (transform)** | Function from a matching transaction to the record a consumer stores. Mechanical decode may run in Bitblocks; product folds stay in the app. | Application Operator, Developer | USE_CASES | definition document |
| **Application** | A named product that uses one or more filters (and an optional map). Distinct from a Protocol (wire format). Keyed by content hash of the definition. | Application Operator, Protocol Author, App User | USE_CASES | proposed `apps` registry |
| **Hydration cursor** | Resume token `(height, txid)` plus snapshot height and definition hash. First-time hydrate, catch-up, and follow all advance it. | Application Operator | USE_CASES | consumer-side; Bitblocks serves pages |
| **Identity (key-scoped)** | A key, address, paymail, AIP signature, or DID. Cross-app sameness is "this key signed", not a Bitblocks account. | App User, Explorer | USE_CASES, ACCOUNT_MODEL | derived; no user table |

---

## Token (BSV-20 / BSV-21)

A *Token* is a fungible asset defined by a 1Sat Ordinal inscription (`application/bsv-20`), stored as a `protocol_instance` under the `BSV20` protocol.
A **BSV-21** token is identified by `token_id = "<txid>_<vout>"` of its `deploy+mint` output — the same identifier the Open Order Book carries, so a listing resolves to a token.
A **BSV-20 classic** token is identified by a 4-char `tick` (ticker); these are detected and stored but not supply-reconciled in v1.

*Token* (the asset) is distinct from a *Token Transfer* (an on-chain movement of a balance) and from an *Order Book Listing* (an offer to sell a token).
Holder balances are derived from token transfers, not stored as a separate ledger.

## Terminology notes

**Protocol vs Protocol Instance** — these are distinct concepts that are often conflated in conversation.
A *Protocol* is the format definition (e.g. "BCat is a large-file protocol at address `15DHFx...`").
A *Protocol Instance* is a specific on-chain transaction that conforms to that format.
The schema separates them (`protocols` vs `protocol_instances`); UIs and docs should use both terms precisely.

**Application vs Protocol** — an *Application* is a product (qart, votesmash) that uses one or more protocols.
A protocol is a wire format; an application is a named filter (and optional transform) over the chain.
Draft: `docs/USE_CASES.md`.

**UTXO vs Output** — every Output becomes a UTXO the moment it's created.
It ceases to be a UTXO the moment it's spent.
Bitblocks uses *Output* when describing transaction structure and *UTXO* when describing spendability state.

**Spend Depth** — a planned concept (Phase 3 of Progressive TX Metadata) measuring hops from coinbase to a UTXO.
Not yet implemented; included here as it has a story in PLAN.md.
