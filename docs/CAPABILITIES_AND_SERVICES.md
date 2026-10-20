# Capabilities, Services, and Architecture

Design notes on emerging primitives for on-chain data services.
Anchored in git mechanics and Unix philosophy.

## The Convergence

Git gives you content-addressable storage, merkle trees, diffing, branching, and signed commits.
Bitcoin uses the same primitives but for value instead of files.
The chain *is* a git repo where every commit is a transaction and every block is a merge.

Unix philosophy says: small tools, text streams, composable pipelines.
The web lost this when apps became monoliths that own your data.
On-chain data is inherently public, text-oriented, and pipeable — closer to Unix than anything the web has produced since RSS.

## Storage Stack

```
Layer 0: Chain (append-only log, signed, timestamped)
Layer 1: Local-first DB (SQLite/IndexedDB/OPFS — the user's copy)
Layer 2: Derived views (materialized from chain data, like git worktrees)
Layer 3: UI (single-page, offline-capable, reads from local DB)
```

This maps to git:
- Chain = bare repo (canonical, shared)
- Local DB = working tree (your view of the data)
- Sync = fetch/pull (not push — chain writes are transactions)
- Derived views = branches/tags (filtered perspectives on the same data)

## Local-First Primitives

**OPFS (Origin Private File System)** — real filesystem in the browser.
You can run SQLite on it via `sql.js` or `wa-sqlite`.
The user's browser becomes the database server.

**CRDTs** — conflict-free replicated data types.
On-chain data doesn't need CRDTs because the chain *is* the conflict resolution mechanism.
You only need CRDTs for off-chain drafts (the "working tree" before you commit/broadcast).

**Service Workers** — your sync daemon.
Fetches chain data, populates the local DB, serves the app offline.
This is the `cron` of the browser.

---

## Capabilities

### What W3C Capabilities Solve

The traditional model: you go to a server, prove who you are (login), and the server decides what you can do.
The capability model: you *carry* what you can do.
The difference is where authority lives.

A capability is an unforgeable token that says "the bearer can do X."
A Bitcoin private key is already a capability — "the bearer can spend these coins."
That's the most battle-tested capability system ever deployed.

### Extending Beyond Spending

On BSV, `OP_RETURN` data is already a capability-granting mechanism — you just need conventions for reading it:

- **Attestation**: a public agency signs a transaction that says "business license #4521 is valid through 2027-03-15."
  The txid *is* the credential.
  Anyone can verify it by checking the chain — no API call, no session, no intermediary.
- **Delegation**: Alice signs a transaction granting Bob the ability to act on her behalf for property at parcel #12345.
  The chain records the grant, the scope, and the timestamp.
  Revocation is another transaction.
- **Access keys**: encrypt data off-chain, publish the decryption key on-chain locked to a specific address.
  Only the key holder can read it.
  The chain handles key distribution without a key server.

### Three Capability Patterns

**1. Bearer capabilities** — whoever has the key can act.
This is Bitcoin's native model.
Use for: payments, simple authorizations, API keys.

**2. Attested capabilities** — a known issuer signs a statement about a subject.
This is the Verifiable Credential model.
Use for: licenses, certifications, identity claims, compliance proofs.
The chain anchors the attestation.
The credential itself can be a JSON document stored locally.

**3. Delegated capabilities** — a capability holder grants a subset of their authority to another party.
This is the UCAN model.
Use for: "my accountant can view my transaction history but not spend."
"This app can read my public profile but not sign transactions."
Each delegation is scoped, time-bounded, and revocable.

### What This Means for Bitblocks

Bitblocks already indexes transactions.
Adding capability awareness means parsing `OP_RETURN` data for known protocols and exposing:
- "Is this credential still valid?" (check if revoked)
- "What capabilities does this address hold?" (scan history)
- "Who granted this?" (trace the delegation chain)

The chain is the source of truth.
Bitblocks is the *legibility layer* — making that truth queryable.

---

## Services

### Derived From What We Already Have

Every service below is a *view* over chain data that bitblocks already indexes.
No new data collection needed — just new lenses.

**Address profile**
Given an address, return its full history: transactions, timestamps, protocols used, tokens held, data published.
This is a bank statement that the user doesn't request — it's public, self-service, always current.
For individuals: "my financial activity, portable."
For agencies: "every dollar we spent, auditable."

**Credential verification**
Given a txid, confirm: the transaction exists, it was mined at block height N at time T, the outputs contain specific data.
Returns a structured response a third party can rely on.
Use case: a bank verifying a business license, a landlord verifying identity, an employer verifying a certification.
No API key needed — the data is public.

**Protocol feeds**
Parse known `OP_RETURN` protocols (B://, MAP, Bitcom, Run, 1Sat Ordinals) and expose typed feeds.
Each protocol becomes a namespace.
Subscribe to "all MAP posts from address X" or "all token transfers for token Y."
Delivered as SSE, webhooks, or Atom/RSS — the user chooses the pipe.

**Proof service**
Given a transaction, return a merkle proof anchored to a block header.
The consumer can verify locally without trusting bitblocks.
This is the trust-minimized primitive — bitblocks provides convenience, not authority.

**Capability resolution**
Given an address and a capability type, return the current state.
"Does this address hold a valid business license?" — walk the chain, find the issuing tx, check for revocation.
"Can this address act on behalf of address Y?" — find the delegation tx, check scope and expiry.

### Service Design Principle

Every service should be:
- **Derivable** — computable from chain data alone, no proprietary state
- **Verifiable** — the consumer can check the answer independently
- **Cacheable** — immutable chain data means aggressive caching
- **Replaceable** — if bitblocks goes down, someone else can compute the same answers from the same chain

This is the Unix philosophy applied to services: don't hoard state, process streams.

### Revenue Model

Free tier: everything above, rate-limited.
Paid tier: higher limits, webhooks, priority indexing of specific addresses/protocols.
Enterprise: dedicated indexing, SLAs, custom protocol parsing.

The data is always public.
The service is convenience and reliability.

### User Spectrum

**Enterprises/agencies first** — they already have structured data, compliance requirements, and motivation to publish.
Land records, business registrations, permit status, budget transparency.
They don't need to learn "web3" — they need an export format and a publish button.

**Individuals later** — people used to hand-write HTML, then stopped because platforms were easier.
The unlock is making the WRITE side as easy as the READ side:
- Templates (like RSS had feed formats)
- Local-first authoring (draft in your browser, broadcast when ready)
- Identity that *you* control (keys, not accounts)

The qart boundary: qart handles POS/wallets/tx (the write side), bitblocks stays on explorer/data (the read side).

---

## Technical Architecture

### The Stack

```
┌─────────────────────────────────────────────┐
│  Browser (single-page, offline-capable)     │
│  ┌─────────────┐  ┌──────────────────────┐  │
│  │ SQLite/OPFS │  │ Service Worker       │  │
│  │ (user's DB) │  │ (sync daemon)        │  │
│  └──────┬──────┘  └──────────┬───────────┘  │
│         │ query              │ fetch/sync    │
│         ▼                    ▼               │
│  ┌─────────────────────────────────────────┐ │
│  │ App shell (LiveView or static SPA)      │ │
│  └─────────────────────────────────────────┘ │
└──────────────────────┬──────────────────────┘
                       │ SSE / REST / WebSocket
                       ▼
┌─────────────────────────────────────────────┐
│  Bitblocks API                              │
│  ┌──────────┐ ┌──────────┐ ┌────────────┐  │
│  │ Addresses│ │ Proofs   │ │ Protocols  │  │
│  │ Profiles │ │ Verifier │ │ Feeds      │  │
│  └──────────┘ └──────────┘ └────────────┘  │
│                    │                        │
│           ┌───────┴────────┐                │
│           │ Chain Index    │                │
│           │ (PostgreSQL)   │                │
│           └───────┬────────┘                │
└───────────────────┼─────────────────────────┘
                    │ RPC
                    ▼
            ┌──────────────┐
            │ BSV Node     │
            │ (Docker)     │
            └──────────────┘
```

### Local-First Storage

The browser holds a SQLite database via OPFS.
On first visit, the service worker fetches the user's address history from bitblocks and populates the local DB.
After that, it syncs incrementally — "give me everything after block height N."
All reads are local.
Zero latency, works offline.

This maps to git:
- `git clone` = first visit, full sync
- `git pull` = incremental sync
- `git log` = local query
- Working tree = what you see in the UI

### Sync Protocol

```
GET /api/v1/addresses/:address/history?since_height=925000
```

Returns a compact format — NDJSON or MessagePack.
Each line is a transaction touching that address.
The service worker appends to the local DB.
Idempotent — replaying the same data is a no-op (keyed by txid).

For real-time: SSE stream of new blocks/transactions.
The service worker subscribes and writes to the local DB as events arrive.
The UI reactively updates from the local DB — it never talks to the network directly.

### The Write Path

Reading is local-first.
Writing is network-first — you can't write to the chain offline.

But you *can* draft offline:
1. Compose a transaction locally (build the inputs/outputs)
2. Sign it with a local key
3. Queue it for broadcast when online
4. Service worker picks it up and submits via bitblocks API or directly to the node

This is `git commit` (local) vs `git push` (remote).

### API Design (Unix-Style)

Small endpoints, composable, text-friendly:

```
# Get raw address history (the pipe source)
GET /api/v1/addresses/:address/txs

# Filter by protocol
GET /api/v1/addresses/:address/txs?protocol=map

# Get a merkle proof (verify independently)
GET /api/v1/txs/:txid/proof

# Verify a credential
GET /api/v1/capabilities/:txid/status

# Subscribe to new activity
GET /api/v1/addresses/:address/stream  (SSE)
```

Each endpoint returns one thing.
Compose by chaining requests or subscribing to streams.
No GraphQL, no mega-queries — small tools.

---

## Developer Experience

### For App Developers Building on Bitblocks

**Client library**: a small JS/TS package that wraps the sync protocol.

```javascript
import { BitblocksClient } from '@bitblocks/client'

const client = new BitblocksClient()

// Sync an address to local DB (runs in service worker)
await client.sync('1A1zP1...')

// Query locally — instant, offline-capable
const txs = await client.query(
  'SELECT * FROM txs WHERE address = ? ORDER BY height DESC',
  ['1A1zP1...']
)

// Subscribe to real-time updates
client.on('tx', (tx) => {
  // new transaction for synced addresses
})

// Broadcast a signed transaction
await client.broadcast(signedTxHex)
```

The developer never writes sync logic, IndexedDB code, or service worker registration.
They get a local SQL database that stays in sync with the chain.

**Elixir/Phoenix library**: for server-side consumers.

```elixir
# In another Phoenix app
{:ok, proof} = Bitblocks.verify_tx("f4184fc596403b9d...")
{:ok, history} = Bitblocks.address_history("1A1zP1...")
```

### For Data Publishers (Agencies, Enterprises)

**CLI tool**: pipe-friendly, Unix-style.

```bash
# Publish a credential
echo '{"type": "business_license", "id": "4521", "expires": "2027-03-15"}' \
  | bitblocks publish --sign-with key.pem

# Query the index
bitblocks query "SELECT * FROM txs WHERE height > 925000 AND protocol = 'map'"

# Stream activity
bitblocks stream 1A1zP1... | jq '.outputs[] | select(.protocol == "b")'
```

Feels like `git` + `curl` + `jq`.
Composable with existing Unix tools.

### For Individuals

People won't write JSON.
But they will:

- Fill out a form ("publish my business listing")
- Click a button ("certify this document")
- Scan a QR code ("verify this credential")

The authoring tools are templates — like blog themes but for on-chain data.
Pick a template, fill in the fields, sign, broadcast.
The underlying format is structured (JSON, CBOR), but the user never sees it.

The read side is bitblocks — search, browse, verify.
The write side is a wallet with templates — compose, sign, broadcast.

---

## Beer's Cyberfolk Connection

Beer's viable system model and cyberfolk concept map directly here.
Real-time feedback loops between citizens and governance, mediated by transparent data.
The chain provides the transparency layer.
Local-first provides autonomy.
Capabilities provide access control without centralization.

The Unix way: the chain is `stdout`, your local DB is a file, your app is `grep | awk | sort`.
Small tools, user-controlled, composable.
