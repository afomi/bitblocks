# Data Model

Derived from `/priv/repo/migrations/`.
Each entity corresponds to a concept in `CONCEPT_INVENTORY.md`.

```mermaid
erDiagram
    blocks {
        bigint height PK
        string hash UK
        string prevblockhash
        string nextblockhash
        string merkleroot
        bigint num_tx
        bigint size
        integer version
        integer nonce
        string bits
        float difficulty
        string chainwork
        integer time
        integer mediantime
        string[] tx
        string sync_state
        timestamp tx_sync_started_at
        timestamp tx_sync_completed_at
        string tx_sync_error
        integer tx_sync_attempts
    }

    transactions {
        string txid PK
        string raw
        integer version
        string block_hash FK
        bigint block_height FK
        jsonb[] inputs
        jsonb[] outputs
        bigint total_input_satoshis
        bigint total_output_satoshis
        integer input_count
        integer output_count
        jsonb output_types
        string[] protocols
        boolean coinbase
        integer script_analysis_version
        string[] input_txids
        string[] output_addresses
    }

    spend_index {
        string txid PK
        integer vout PK
        string spending_txid
        integer spending_vin
    }

    protocols {
        string address PK
        string version PK
        string name
        string description
        string category
        string verification_status
        string author
        string documentation_url
        string source_url
        string example_txid
        jsonb schema
        string covenant_hash
        string scrypt_source
        string[] requires
        string[] conflicts_with
    }

    protocol_instances {
        bigint id PK
        string txid FK
        integer vout
        bigint block_height FK
        jsonb parsed_data
        string state
        boolean spent
        string spent_txid
    }

    protocol_stats {
        bigint id PK
        string protocol_address FK
        string period
        integer instance_count
        integer transaction_count
        integer unique_addresses
        bigint total_satoshis
    }

    protocol_audits {
        bigint id PK
        string protocol_address FK
        string auditor
        string audit_type
        string result
        string notes
        string report_url
    }

    sync_jobs {
        bigint id PK
        string scope
        bigint start_block
        bigint end_block
        string status
        bigint blocks_synced
        bigint total_blocks
        timestamp started_at
        timestamp completed_at
        integer errors_count
    }

    txbox_txns {
        uuid guid PK
        string txid UK
        text rawtx
        string channel
        string[] tags
        jsonb meta
        jsonb data
        string state
        bigint block_height
        tsvector search_vector
    }

    txbox_mapi_responses {
        bigint id PK
        uuid tx_guid FK
        string type
        jsonb payload
        string public_key
        string signature
        boolean verified
    }

    blocks ||--o{ transactions : "contains"
    transactions ||--o{ spend_index : "outputs tracked in"
    transactions ||--o{ protocol_instances : "hosts"
    protocols ||--o{ protocol_instances : "defines format for"
    protocols ||--o{ protocol_stats : "aggregated in"
    protocols ||--o{ protocol_audits : "reviewed in"
    txbox_txns ||--o{ txbox_mapi_responses : "receives"
```

---

## Entity notes

**blocks / transactions** — core ledger.
`blocks.tx[]` is populated only for blocks with ≤10k transactions (memory optimization).
`blocks.sync_state` drives the state machine; see `CONCEPT_INVENTORY.md` for state values.

**spend_index** — absence of a row means the output is unspent (UTXO).
The composite PK `(txid, vout)` is the canonical Outpoint identifier.
`settle_spent_token_utxos/1` joins this table against `protocol_instances` to auto-fill OrderBook listings.

**protocols / protocol_instances** — see *Terminology notes* in `CONCEPT_INVENTORY.md`.
`protocol_instances` doubles as the OrderBook listing store: `parsed_data` carries the listing fields,
`state` tracks `active / filled / cancelled`, and `spent / spent_txid` record settlement.

**txbox_txns** — staged outbound transactions.
Not a blockchain record; used for broadcast management.
`search_vector` is auto-updated by a DB trigger for full-text search over `meta` and `data`.

## Concepts with no DB entity

| Concept | Reason |
|---------|--------|
| Shape Layer | In-memory NFT generation; not persisted |
| DID | Derived from vCard fields at request time |
| MURL | Computed by traversing `protocol_instances` parent chain |
| Spend Depth | Planned (Phase 3); will require a computed column or materialized view |
