# Sitemap

All routes in bitblocks, grouped by access level and function.
Search engines get the public subset at `/sitemap.xml` (`BitblocksWeb.SitemapController`), referenced from `robots.txt`.

## Public Pages

| Path | Description |
|------|-------------|
| `/` | Homepage — search, chain status, navigation |
| `/about` | About Bitblocks, BSV, Bitcoin Script |
| `/search` | Search by block height, hash, or txid |
| `/status` | Node and chain status overview |
| `/reorgs` | Reorganizations this index has seen, as annotations at a height |
| `/protocols` | Moved to `/types#protocols` (301) |
| `/guide` | Getting started guide |
| `/did` | Decentralized identity explorer |
| `/apps` | Applications directory |
| `/resources` | External resources and links |
| `/collections` | BSV NFT collections index, with sources |
| `/collections/:id` | One collection's items, traits, and holders, by slug or origin outpoint |
| `/wall` | Block wall visualization |
| `/reward_wall` | Mining reward visualization |

## Admin / Dev Pages

For admins: a GitHub user marked admin; the gate runs in every env and is off only in the test config.

| Path | Description |
|------|-------------|
| `/blocks` | Block list (paginated) |
| `/blocks/:id` | Block detail by height or hash |
| `/transactions` | Transaction list (paginated) |
| `/transactions/:id` | Transaction detail by txid |
| `/start` | Builder onboarding, admin only until published ([DEMOS_CAMPAIGN.md](DEMOS_CAMPAIGN.md)) |
| `/start/api` | API reference, admin only until published |
| `/start/guidance` | Our dated views on building on Bitcoin, admin only until published |
| `/start/interop` | Check a BEEF by hand, and the interop pattern, admin only until published ([INTEROP_KIT.md](INTEROP_KIT.md)) |
| `/config` | Application configuration viewer |
| `/debug` | Debug info |
| `/graph` | Transaction graph visualization |
| `/block-graph` | Block graph with playback controls |
| `/tx-graph` | Transaction flow graph |
| `/forks` | Fork detection graph |
| `/highlights` | Notable transactions and blocks |
| `/reporting` | Reporting dashboard |
| `/ecosystem` | BSV ecosystem map |
| `/pulse` | Network pulse / activity monitor |
| `/peers` | Peer map visualization |
| `/shape-layers` | Geographic shape layer viewer |
| `/chain-scrubber` | Scrub the chain from genesis to tip in three.js; tiles at `/chain-scrubber/tiles/manifest` and `/chain-scrubber/tiles/:level/:idx` |
| `/rpc_admin` | Direct RPC command interface |
| `/address_repo` | Address event playground (event sourcing) |
| `/dev/dashboard` | Phoenix LiveDashboard |
| `/metrics` | Prometheus metrics endpoint |

## API — `/api/v1`

JSON endpoints.
All `GET` unless noted.

### Blocks

| Endpoint | Description |
|----------|-------------|
| `/api/v1/blocks` | Paginated block list. `?page=&per_page=` |
| `/api/v1/blocks/latest` | Most recent block |
| `/api/v1/blocks/:id` | Block by height or hash |
| `/api/v1/blocks/at_time` | Height at UTC datetime. `?t=2024-01-01T00:00:00Z` |
| `/api/v1/blocks/at_height` | UTC datetime at height. `?h=823000` |
| `/api/v1/blocks/time_map` | Sampled height↔time pairs. `?from=0&to=900000&step=10000` |

### Transactions

| Endpoint | Description |
|----------|-------------|
| `/api/v1/txs` | Paginated transactions. `?page=&per_page=&block_hash=&txid=` |
| `/api/v1/txs/:txid` | Transaction by txid |
| `/api/v1/txs/:txid/proof` | Merkle proof for a transaction |

### Addresses

| Endpoint | Description |
|----------|-------------|
| `/api/v1/addresses/:address/utxos` | Unspent outputs (proxied from WhatsOnChain) |
| `/api/v1/addresses/:address/balance` | Balance (proxied from WhatsOnChain) |

### Protocols

| Endpoint | Description |
|----------|-------------|
| `/api/v1/protocols` | List registered protocols. `?category=&verification_status=&search=` |
| `/api/v1/protocols/stats` | Protocol statistics overview |
| `/api/v1/protocols/search` | Search protocols |
| `/api/v1/protocols/:address` | Protocol by Bitcom address |
| `POST /api/v1/protocols/identify` | Identify protocol from script data |

### Streaming

| Endpoint | Description |
|----------|-------------|
| `/api/v1/stream/blocks` | SSE stream — `block_updated` (height, hash, sync_state; a new header and every state change) and `reorg` events |

## Data Endpoints (non-API)

Used by visualization pages.

| Path | Description |
|------|-------------|
| `/wall/blocks_data` | JSON block data for wall visualization |
| `/reward_wall/reward_data` | JSON reward data for reward wall |
| `/reward_wall/address_data` | JSON address data for reward wall |
