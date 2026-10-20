# Mining BSV with an Existing Node

Notes on leveraging a fully synced BSV node for mining — without owning ASICs.

## How Bitcoin Mining Works

Mining is two separate jobs:

1. **Block template generation** — assembling a candidate block from mempool transactions, computing the merkle root, setting the target difficulty. This is CPU work and requires a synced node with mempool data.

2. **Hashing** — iterating nonces over the block header until the hash meets the difficulty target. This is the brute-force work that requires ASICs (SHA-256d at ~600+ EH/s network-wide for BSV).

These two jobs can run on different machines.

## Your Node's Role

A fully synced BSV node can:

- Generate block templates via `getblocktemplate` RPC
- Validate blocks and transactions
- Relay transactions to peers (if configured to accept them)
- Serve as the "brain" that decides what goes in a block

What it **cannot** do:
- Hash fast enough to compete. CPU mining on SHA-256 is not viable against ASICs. Not even close — the difference is roughly 10^12x (a trillion times slower).

## The Split Architecture

```
┌──────────────────────┐         ┌──────────────────────┐
│  Your BSV Node       │         │  Remote ASIC Farm     │
│                      │         │                       │
│  getblocktemplate    │────────▶│  Hash candidates      │
│  validateblock       │◀────────│  Return solutions     │
│  submitblock         │         │                       │
└──────────────────────┘         └──────────────────────┘
       Stratum proxy bridges the two
```

### Stratum Protocol

Stratum is the standard protocol between mining software and pools/nodes.
A **stratum proxy** sits between your node and the hashers:

1. Your node generates a block template (`getblocktemplate`)
2. The stratum proxy converts it into work units
3. Work units are sent to remote ASICs/GPUs
4. When a solution is found, the proxy submits it back to your node (`submitblock`)

### Implementations

- **ckpool** — lightweight stratum pool/proxy. Can run solo mining against your own node.
- **Stratum v1** — the standard protocol most ASIC firmware speaks.
- **Mining pools** — you can point remote ASICs at a pool, but then the pool builds the template, not your node.

## Can You Use Remote ASICs?

Yes, in theory:

1. **Rent hashpower** — services like NiceHash sell SHA-256 hashrate by the hour. You point rented hashers at your stratum proxy. They hash your block templates.

2. **Co-locate ASICs** — buy ASICs, host them in a data center with cheap power. They connect back to your node via stratum.

3. **Pool with your own templates** — some pools (or pool software like ckpool) let you provide your own block templates while leveraging pooled hashrate.

## Feasibility Assessment

### Solo Mining

BSV network hashrate fluctuates but is typically 400-800 PH/s.
A single Antminer S19 does ~110 TH/s.
Expected time to find a block solo: **months to years** with one ASIC.
With rented hashpower: possible but likely unprofitable after rental costs.

### Why You'd Do It Anyway

- **Transaction selection** — you choose what goes in the block. Relevant for applications that need specific transactions confirmed.
- **Learning** — understanding mining mechanics deeply.
- **Network health** — more independent miners = more decentralized.
- **Mempool access** — a mining node sees unconfirmed transactions, which your current sync-only node does not.

### Why You Probably Wouldn't

- **Economics** — BSV block reward is 3.125 BSV (post-2024 halving). At current prices, the reward doesn't cover ASIC rental costs unless you have very cheap power.
- **Difficulty** — the network adjusts difficulty so blocks come every ~10 minutes regardless of total hashrate. More hashrate = higher difficulty = no advantage.

## Minimum Viable Mining Setup

If you wanted to try it:

1. **Configure your node to accept transactions**
   ```
   # bitcoin.conf
   maxmempool=300  # MB, default
   blockmaxsize=4000000000  # 4GB, BSV default
   ```

2. **Install ckpool** (or equivalent stratum proxy)
   ```bash
   git clone https://bitbucket.org/ckolivas/ckpool.git
   cd ckpool && ./configure && make
   ```

3. **Configure ckpool to use your node**
   ```json
   {
     "btcd": [{"url": "localhost:8332", "auth": "user", "pass": "password"}],
     "btcaddress": "your-bsv-address",
     "btcsig": "mined by bitblocks"
   }
   ```

4. **Point hashers at your stratum proxy**
   - Rented: configure NiceHash order to point at `stratum+tcp://your-ip:3333`
   - Owned: configure ASIC firmware to the same endpoint

5. **Wait**

## What Your Node Needs for Mining

Your current node setup (sync-only) would need:

- **Peer connections** — needs to be connected to the network to receive transactions and propagate found blocks quickly.
- **Mempool enabled** — currently your node has no mempool (it only syncs blocks). Mining requires accepting unconfirmed transactions.
- **Low latency** — found blocks need to propagate fast to avoid orphans. Closer to other miners = better.

## How Transactions Are Gathered

The lifecycle of a transaction from creation to block inclusion:

```
User/App creates tx
        │
        ▼
   Broadcast to network (sendrawtransaction)
        │
        ▼
   Peer nodes receive and validate
        │
        ▼
   Valid txs enter the MEMPOOL
   (in-memory pool of unconfirmed transactions)
        │
        ▼
   Miner calls getblocktemplate
        │
        ▼
   Node assembles candidate block:
     1. Coinbase tx (block reward → miner's address)
     2. Mempool txs sorted by fee rate (satoshis/byte)
     3. Merkle root computed from all included txids
     4. Block header assembled (prev hash, merkle root, timestamp, bits, nonce=0)
        │
        ▼
   Template sent to hashers
```

### Transaction Selection

The node selects transactions from the mempool based on:

- **Fee rate** — higher satoshis-per-byte transactions are included first.
- **Block size limit** — BSV allows blocks up to 4GB. The miner chooses how full to make the block.
- **Dependency ordering** — if tx B spends an output from tx A, A must come first.
- **Policy rules** — the node can reject non-standard transactions, dust outputs, etc. These are configurable.

A mining node with an empty mempool produces blocks with only the coinbase transaction.
This is what happens on a sync-only node — it has no transactions to include.

### The Mempool

The mempool is **per-node, in-memory, not on-chain**.
Each node maintains its own mempool independently.
Nodes share transactions via the P2P gossip protocol.

A sync-only node (like yours) doesn't participate in gossip for unconfirmed transactions — it only downloads completed blocks.
To have a mempool, the node must:

1. Be connected to peers (`addnode` or automatic peer discovery)
2. Accept incoming transactions (`maxmempool > 0`)
3. Not be behind a firewall that blocks P2P port (default 8333)

## Where the Hash Mining Process Lives

The hashing loop is simple but must be fast:

```
Receive block header template (80 bytes):
  - version (4 bytes)
  - prev block hash (32 bytes)
  - merkle root (32 bytes)
  - timestamp (4 bytes)
  - bits/target (4 bytes)
  - nonce (4 bytes)

Loop:
  1. Set nonce = 0
  2. SHA256d(header) → hash
  3. If hash < target → FOUND A BLOCK → submit
  4. nonce += 1
  5. If nonce overflows (2^32 attempts):
     - Increment extraNonce in coinbase tx
     - Recompute merkle root
     - Reset nonce = 0
  6. Go to 2
```

### The Relationship Between Incoming Txs and Hashing

This is the key nuance: **the mempool changes continuously, but the block template is a snapshot.**

```
Time ──────────────────────────────────────────────────▶

Mempool:  [tx1] [tx1,tx2] [tx1,tx2,tx3] [tx1,tx2,tx3,tx4] ...
              ↓                    ↓
Template v1:  {tx1,tx2}           Template v2: {tx1,tx2,tx3,tx4}
  merkle: abc123                    merkle: def456
  nonce: 0,1,2,3...                nonce: 0,1,2,3...
              ↓                           ↓
         hashing...                  hashing...
         (abandoned when v2 arrives)
```

1. The node builds a block template from the current mempool snapshot.
2. That template has a **fixed merkle root** (computed from the included txids).
3. The ASICs start iterating nonces against that fixed header.
4. Meanwhile, new transactions arrive in the mempool.
5. Periodically (every few seconds), the node builds a **new template** with the updated mempool — a new merkle root.
6. The new template is sent to the ASICs, which **abandon** the old template and start hashing the new one.

So yes — the template updates frequently as new txs arrive.
Each update changes the merkle root, which means all previous nonce work is discarded.
The ASICs don't mind — they're stateless and start fresh instantly.

The trade-off: update templates too often and you waste hashing cycles on abandoned work.
Update too rarely and you miss fee revenue from new transactions.
Pools typically update every 1-5 seconds.

### Where this runs

| Hardware | Hash rate | Viable? |
|----------|-----------|---------|
| CPU | ~10 MH/s | No. Would take mass of years per block. |
| GPU | ~500 MH/s | No. Still millions of times too slow. |
| FPGA | ~1 GH/s | No. Economically impractical. |
| ASIC (Antminer S19) | ~110 TH/s | Marginal. One unit = months per block solo. |
| ASIC farm (1000 units) | ~110 PH/s | Yes. Competitive with small pools. |
| Rented hashpower | Variable | Possible but usually unprofitable after costs. |

The hashing process is **stateless** — the ASIC receives an 80-byte header, iterates nonces, and reports any solution.
It doesn't need to know about transactions, the blockchain, or even what Bitcoin is.
It's a pure SHA-256 brute-force machine.

This is why the split architecture works:
- **Your node** (stateful): knows the chain, builds templates, validates blocks
- **ASICs** (stateless): receive headers, iterate nonces, return solutions

The two communicate via the stratum protocol over TCP.
The ASICs can be anywhere — same rack, same data center, across the ocean.
Latency matters only for block propagation after a solution is found, not during hashing.

## BSV Mining Pools (2026)

| Pool | Notes |
|------|-------|
| **GorillaPool** | BSV-native, most accessible for small operators |
| **TAAL** | Largest BSV mining operation, also provides tx processing services |
| **ViaBTC** | Multi-chain pool, mines BSV among others |
| **SBI Crypto** | Japanese-backed |

Joining a pool (e.g. GorillaPool) with even one ASIC is more rational than solo mining.
The pool builds templates and distributes work — you just provide hashrate and earn proportional rewards.

## Relation to Bitblocks

If you ran a mining node, Bitblocks would benefit from:

- **Mempool data** — the mempool component on the homepage would show real data.
- **Faster block awareness** — a mining node hears about new blocks before a sync-only node.
- **Transaction relay** — Bitblocks could accept transactions from users (via qart) and relay them directly to the network, rather than depending on third-party broadcast services.

This is the path from "block explorer" to "network participant."
