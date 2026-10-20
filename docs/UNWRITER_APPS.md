# _unwriter apps ↔ Bitblocks

Status: design & vision (mapping).
Source: the unofficial timeline at [unwriter.net](https://unwriter.net/) (data in [`index.js`](https://unwriter.net/index.js), maintained by [@mohrt](https://github.com/mohrt/unwriter.net)).
Order matches the site: reverse chronological.

_unwriter names are prior art, not standards in this repo.
Our column uses Bitblocks language from `USE_CASES.md`: **filter**, **map**, **hydrate**, **follow**, **cursor**, **application**, **protocol**, **identity**.
A **Bitblock** (`BITBLOCK.md`) is a materialized filter — same software, subset database.

Related: `UNWRITER_SYNTHESIS.md` (what to steal), `USE_CASES.md` (product framing), `BITBLOCK.md` (Planaria → Bitblock table).

---

## Timeline table

| App | Description | Our approach / terminology | Notes |
|---|---|---|---|
| Bitfeed (Sep 2020) | RSS, but for Bitcoin transactions. | **Follow** a filter; SSE / poll with a **cursor**. | Closest existing surface: `/api/v1/stream/*`. A feed is a named follow, not a new product. |
| PowPress (Sep 2020) | "Push Web" engine: publish by broadcasting, clients pull from the chain. | **TX_CDN** as origin; **hydrate** then **follow**. | Write side is qart (or any wallet). Bitblocks is the index those clients hydrate from. |
| PowPing (Jul 2020) | A social Bitcoin network. | An **application** (filter on a social protocol / MAP `app=`). | Example of a consumer app, not something Bitblocks should reimplement. Identity across apps is US-28. |
| Bitsim (Jun 2020) | Bitcoin simulator. | Out of scope. | Educational / mempool toy. Not an indexer concern. |
| TXT (Jun 2020) | Semantic Bitcoin storage. | **Data dictionary** + protocol instances + script decode. | "Semantic" here means labeled, queryable payloads — the dictionary is derivative of pack definitions. |
| C.TXT (May 2020) | Find files on Bitcoin. | **Filter** on C:// / B:// / BCat; **TX_CDN** for bytes. | Search over content-addressed payloads. BCat detection exists; reassembly is deferred (`BCAT-REASSEMBLE`). |
| BitPic TXT (May 2020) | BitPic search engine and transaction explorer. | Domain **explorer** over a Bitpic **protocol** filter. | Same pattern as `/tokens` or `/order-book`: one protocol, a dedicated UI. |
| Bob and Neon Genesis Bitbus (Apr 2020) | BOB-shaped endpoint on the Bitbus crawler. | Canonical **transaction shape** + **hydrate** API. | `UNWRITER_SYNTHESIS.md` Gap 1: we still store vin/vout as opaque JSON strings. BOB is the shape a hydrate page should speak. |
| Minercraft (Apr 2020) | Interact with Bitcoin miner APIs. | **MiningProxy** / `/api/v1/mining/*`. | Implemented (`MINING_PROXY.md`). Template + submit, not a third-party miner SDK. |
| Toychain (Apr 2020) | Distributed version control for Bitcoin. | **Bitblock** as sparse checkout; portable **filter + map**. | Git analogy is already in `BITBLOCK.md`. We do not need a second VCS product. |
| Bitbus 2.0 (Mar 2020) | Bitcoin crawler API for everyone. | **Hydrate**: paged historical pull of a filter up to a snapshot. | This is US-25. Bitbus is "give me matching txs without running a node." |
| BitFS (Feb 2020) | Bitcoin file system. | **TX_CDN** + B:// / BCat as paths. | Files are transactions. HTTP GET by txid/scripthash is the FS. |
| Bitsocket 2.0 (Jan 2020) | Production-grade global Bitcoin push API. | **Follow** (SSE, later webhook). | `/api/v1/stream/*` exists (blocks, order-book, tokens). Per-filter follow is the gap. Streams stay public; capped by `SseLimiter`. |
| Localchain (Dec 2019) | Dead-simple off-chain Bitcoin transaction ledger. | Local draft / payment-channel log — not the explorer index. | Off-chain until broadcast. Adjacent to `PAYMENT_CHANNELS.md` and Overpool. Bitblocks indexes confirmed (and optionally mempool) txs. |
| Neon Bitpic (Dec 2019) | Deploy your own Bitpic node. | **Bitblock** mode: same app, Bitpic **filter**. | "Anyone can run one" applied to a single application. |
| Bitkey (Nov 2019) | Paymail / pubkey mapping on-chain. | **Identity** (paymail → key), key-scoped. | Feeds US-27 / US-28. Bitblocks indexes the mapping; it does not issue paymails. |
| su (Oct 2019) | Simple authentication protocol for Bitcoin apps. | Wallet **session**, not a Bitblocks account. | `USE_CASES.md` § B: no SSO. `su` is an app-layer auth convention; we do not host it. |
| Overpool (Sep 2019) | Decentralized Turing-complete ledger of off-chain txs. | Mempool / pre-broadcast event log. | Confirmed-chain follow is Bitsocket; Overpool is the unconfirmed sibling. We have no Overpool equivalent. |
| GridPlanaria (Sep 2019) | Distributed Bitcoin data grid. | **Bitblock** mesh: subset hydrates from a superset peer. | `BITBLOCK.md` "Future: Mesh / P2P". Day one everyone hydrates from this full-chain index. |
| MOM (Aug 2019) | Metanet Object Model. | Metanet **protocol** + DAG projection. | `/metanet` and `/api/v1/metanet/*` exist. MOM is the object layer on top of Metanet nodes. |
| BOB (Aug 2019) | Bitcoin OP_RETURN Bytecode (nested tape of script chunks). | Persist a normalized tx / script-chunk shape. | Highest-leverage missing primitive (`UNWRITER_SYNTHESIS.md` Gap 1). Parser already walks chunks at request time; it does not persist them. |
| Eventchain (Jul 2019) | Append-only log of filtered Bitcoin events. | Tagged index + **follow**; consumer DB is a fold of the log. | Hydration's historical pages *are* the event log for one definition hash. |
| Metagraph (Jun 2019) | Metanet graph explorer. | `/metanet` LiveView + API. | Built. Graph of parent/child Metanet nodes and MURLs. |
| Neon Planaria (Jun 2019) | Bitcoin as a backend (filter + fold → state machine + HTTP/SSE). | **Application** definition (filter + optional map) hosted as a **Bitblock**, or a consumer that **hydrates** from Bitblocks. | Planaria-the-framework is the Application Operator job (`USE_CASES.md`). Bitblocks is the full-chain source, not every app's process. |
| Bitbus (Jun 2019) | "Bitcoinless Bitcoin computing" — sync a subset without a node. | **Hydrate** from Bitblocks instead of RPC. | Same as Bitbus 2.0; first version. Completeness and cursors are the contract. |
| Bterm (Apr 2019) | Global terminal for Bitcoin application protocols. | Protocol feeds / `/api/v1/protocols/:addr/feed`. | A REPL over protocol tags. We expose HTTP, not a shell. |
| Bit:// (Apr 2019) | A protocol for addressing protocols (and files) on Bitcoin. | Content / protocol addressing; **TX_CDN** URLs. | `bit://` as a URI scheme. Routes (`$ route enable/add`) are indexed and shown on `/bitcom/:address` (`BITCOM.md`); the resolver is #22. |
| Bottle (Mar 2019) | A Bitcoin browser. | This explorer's UI: fetch, decode, render on-chain content. | Bitblocks *is* a Bitcoin browser for the full chain. Bottle was a dedicated client for b:// pages. |
| C:// (Mar 2019) | Universal content-addressable file system over Bitcoin. | **TX_CDN**; checksum as the key. | Hash-addressed payloads (vs B:// txid-addressed). `USE_CASES.md` map example: "store the checksum." |
| Bitgraph (Mar 2019) | Bitcoin graph explorer. | `spend_index` + `/tx-graph` / `/block-graph`. | Spend edges exist. A general address/tx graph UI is partial. |
| Planaria File Server API (Feb 2019) | Autonomous HTTP file server over Bitcoin. | **TX_CDN** HTTP origin. | GET bytes by locator; cache forever because the chain does not change. |
| Bitstagram (Feb 2019) | Bitcoin-native photo app. | Long-tail **application** over B:// (or similar). | Consumer app. Bitblocks tags and serves; qart (or similar) writes. |
| BASCIIAT (Feb 2019) | Store images as ASCII art on Bitcoin. | Niche **application** / content **map**. | Example of a transform (image → ASCII) before store. Canonical index should keep the chain bytes; the map belongs on a derived view. |
| Euler (Feb 2019) | Planaria machine indexing the entire chain as a graph. | Full-chain Bitblocks + `spend_index`. | Euler is "Bitblocks as graph." We have the edge table; not a graph query language. |
| B:// (Jan 2019) | Simple storage and URI protocol. | **Protocol** `B://` (Bitcom prefix `19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut`). | Detected today (`TransactionParser` / content detector). Prefix-only via `RegistryCache` if needed. |
| Bitcom (Jan 2019) | Bitcoin application protocol computer (address = namespace). | **Live Bitcom registry** at `/bitcom` (`BITCOM.md`). | All commands (useradd, echo, cat, route) indexed into a command log; proven / self-described / listed tiers; JSON export. Epic #18. |
| Alice in Bitcoinland (Jan 2019) | Serverless website in a single Bitcoin transaction. | B:// HTML payload rendered from the index. | Demo of TX_CDN + Bottle. Not a separate Bitblocks feature. |
| Bitchat terminal edition (Jan 2019) | Bitchat in a terminal. | Same **application**, different UI. | Follow the Bitchat filter; render in a TTY. |
| Bitpipe (Jan 2019) | Bitcoin transaction broadcast microservice (pay-for-someone-else's-tx). | **TXBox** / outbound broadcast; fee sponsorship. | Write/broadcast path. Bitblocks has Txbox for staged outbound txs. Fee-pays-for-other is qart/wallet territory. |
| Bitchat (Jan 2019) | Massively multiplayer realtime chat over Bitcoin. | **Application** + **follow**. | Canonical "Bitcoin as event bus" example (`USE_CASES.md` § 12). |
| Bitsocket (Jan 2019) | Programmable Bitcoin push API. | **Follow**. | Original Bitsocket. Same mapping as Bitsocket 2.0. Query-shaped subscriptions are Gap 3 (no Bitquery DSL yet). |
| BitDB Meta (Jan 2019) | BitDB for querying block metadata. | Header-only sync + **CHAIN_LENS** time↔height. | We already keep headers cheap (`getblockheader`) and expose `at_time` / `time_map`. |
| Chronos (Jan 2019) | Ephemeral BitDB for dealing with time (sliding window). | Prunable **consumer** DB; chain remains archival. | `USE_CASES.md` § 5. Retention is the application's map, not Bitblocks'. |
| Datapay (Jan 2019) | Simplest JS lib to write data to BSV. | Write side: **qart** / wallet / `createAction`. | Bitblocks is read/index. We do not ship a Datapay equivalent. |

---

## Not on unwriter.net (core stack)

The unofficial timeline skips some of the pieces `UNWRITER_SYNTHESIS.md` treats as the actual Unix stack.
Listed here so the mapping is complete; these are **not** rows on the site.

| App | Description | Our approach / terminology | Notes |
|---|---|---|---|
| Planaria | Programmable Bitcoin node: filter + fold → DB + HTTP/SSE. | **Bitblock** / **application** definition. | "The gene is the identity." Mapped in `BITBLOCK.md`. |
| Planarium | Hosted Planaria / public API farm. | This Bitblocks instance as full-chain **utility**. | `USE_CASES.md` § 2. |
| Bitquery | The query *is* the API (`{ q, r }`). | Transportable filter / Ecto DSL (not built). | Gap 3. Hydration should carry a definition hash, not a thousand endpoints. |
| TXO / BPU | Flat JSON tx shape; script processor that emits BOB. | Normalized persisted tx / script chunks. | Gap 1. Feeds BOB, Bitquery, and hydrate. |
| Bitcache | Content-addressed HTTP cache of tx payloads. | **TX_CDN**. | Polyglot by HTTP. |
| Genesis | Append-only node storing entire transaction objects. | Full-chain Bitblocks (unfiltered). | Superset of every filtered app. |
| Babel | Append-only node storing OP_RETURN subset. | A **filter** (OP_RETURN / data-carrier only). | Babel ⊂ Genesis. Same as "Bitblock: data txs." |
| MAP | Key-value OP_RETURN protocol (`app=`, `type=`, …). | **Protocol** handler (Twetch/MAP detection exists). | De facto **application** identifier is MAP `app=`. |
| AIP | Author Identity Protocol (sign a payload). | **Identity** chip (AIP / unlocking key). | US-27. Not _unwriter's: AIP is by Attila Aros (attilaaf); listed for completeness of the stack. |
| Sticker | On-chain protocol directory / discovery. | `/protocols` + proposed `/apps`. | Unmatched-template report is the discovery signal (US-24). |

---

## How to read the mapping

Four clusters, not 44 unique products:

1. **Shape** — TXO / BPU / BOB / TXT: how a transaction is represented.
2. **Select** — Bitquery / Bitbus / Eventchain / Chronos / Genesis / Babel: filter, hydrate, prune.
3. **Push** — Bitsocket / Bitfeed / PowPress: follow.
4. **Name** — Bitcom / Bit:// / B:// / C:// / MAP / AIP / Bitkey: protocols and identity.

Bitblocks already does a full-chain **Genesis**, header **BitDB Meta**, some **MAP/B://** detection, Metanet (**MOM/Metagraph**), mining (**Minercraft**), and coarse SSE (**Bitsocket**).
The work in `USE_CASES.md` is to make (2)–(4) first-class: register a filter, tag at ingest, hydrate with a cursor, follow, and show identity across applications.

## Revival (2026-10-20)

Direction changed: revive _unwriter's demonstrated pieces as working instances, sprint by sprint (#25), starting with Bitcom (#18).
Rebrand rule: keep on-chain protocol names (B://, C://, bit://, MAP, Bitcom) because those are the standard; rename hosted products (Bitbus, Bitsocket, Planaria…) so nothing implies they are _unwriter's originals.
