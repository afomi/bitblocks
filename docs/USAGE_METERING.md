# Usage metering

What each caller costs us, measured before any rate is set (https://github.com/afomi/bitblocks/issues/61).
It charges nobody.
The code is authoritative: `Bitblocks.Usage`, `BitblocksWeb.Plugs.Meter`, `Bitblocks.Usage.Flusher`.

## What is counted

For every HTTP request through the endpoint, by caller and endpoint class, per UTC hour:

| Column | What it is |
| --- | --- |
| `requests` | Requests answered, refusals (429, 402, 401) included |
| `status_4xx`, `status_5xx` | Of those, client and server errors |
| `response_bytes` | Body bytes sent, each chunk of a stream included |
| `duration_us` | Time from the meter to the response's first byte |
| `db_us`, `db_queries` | Ecto's `total_time` (queue, query, decode) and the count, for queries the request's process ran |
| `node_calls`, `woc_calls`, `coingecko_calls`, `other_calls` | Outbound HTTP calls the request made, by upstream: our node's RPC and REST, WhatsOnChain, CoinGecko, anything else (S3, GorillaPool) |
| `upstream_us` | Time spent in those calls |

A cache hit makes no upstream call, so it costs none here.

## Callers

| `caller_kind` | `caller_id` | Who |
| --- | --- | --- |
| `key` | the `api_keys` id | A request with a valid API key |
| `user` | the `users` id | A signed-in session, admin or not |
| `crawler` | the family (`gptbot`, …) | An AI crawler without a key |
| `anonymous` | `""` | Everyone else, in one row |

The caller is what `BitblocksWeb.Plugs.RateLimiter` decided, so metering adds no query.
An IP address is never stored.

## Endpoint classes

| Class | Paths |
| --- | --- |
| `read` | Any other `/api/*`, and `/bitcom.json` |
| `raw_export` | `/api/v1/txs/:txid/raw`, `/api/v1/woc/tx/:txid/hex`, `/content/*`, `/b/:txid`, `/api/v1/types/export(.csv)`, `/api/v1/bitcom/snapshots/:version`, a projection's `/txs` and `/commands` pages |
| `stream` | `/api/v1/stream/*` and a projection's `/follow` |
| `proof` | `/api/v1/txs/:txid/proof`, `/api/v1/txs/:txid/beef`, `POST /api/v1/beef/verify` |
| `ops` | `/api/v1/ops/*` |
| `page` | Everything else: HTML pages and a LiveView's first render |

`Bitblocks.Usage.endpoint_class/1` is the one place a class is decided.

## How it is collected

1. `BitblocksWeb.Plugs.Meter`, ahead of the rate limiter, opens an accumulator in the request process's dictionary and registers a `before_send` callback.
2. Telemetry handlers add to it from the same process: Ecto's `[:bitblocks, :repo, :query]` and Finch's `[:finch, :request, :stop]`, classed by host.
   Every other process pays one dictionary read per event and moves on.
3. At `before_send` the totals go into one ETS row per hour, caller and class, by `:ets.update_counter/4`.
   A stream keeps counting after its headers: each chunk's bytes (`StreamController`'s `chunk/2`) and each query it runs go straight to its row.
4. A controller that raises before sending is counted as a 5xx, from `[:phoenix, :router_dispatch, :exception]`.
5. `Bitblocks.Usage.Flusher` moves the ETS rows into `usage_rollups` every minute (`:usage_flush_ms`), and once more on shutdown.
   The write is an additive upsert, so every node, readers too, adds to the same row.
   A failed write puts the counts back for the next flush.

There is no row per request.
`usage_rollups` has one index, the upsert's unique `(hour, caller_kind, caller_id, endpoint_class)`, whose leading `hour` serves every read: a bounded window of hours.

Metering never blocks or fails a request: each step rescues and gives up quietly.
`config :bitblocks, :usage_metering, false` turns it off.

## What it doesn't see

- Work a request hands to another process (a `Task`, a GenServer call such as a cache refresh) is not attributed to it.
- LiveView events over an open socket are not HTTP requests, so they aren't counted, as the rate limits don't count them.
- A stream's open time is not measured; its bytes and DB time are.
- Each node's last minute is in ETS until its next flush.

## Reading it

```bash
# The last day, by class and by the top 20 callers, with per-request means
bin/bitblocks rpc 'Bitblocks.Release.usage_report()'
# A week, or 30 days with 50 callers
bin/bitblocks rpc 'Bitblocks.Release.usage_report(168)'
bin/bitblocks rpc 'Bitblocks.Release.usage_report(hours: 720, limit: 50)'
```

`/usage` (admin) shows the same over the last day, week or 30 days.

A key holder, or a signed-in user, reads their own at `GET /api/v1/usage?hours=24` (1 to 720): totals and each class, with per-request means, flushed rollups plus this node's last minute.
A signed-in user also sees theirs on `/pricing#usage` ("What am I using?"): requests and data sent by class over the last 24 hours, as themselves and through their key, labelled measured and not billed.

## From here to a rate

The pricing box on https://github.com/afomi/bitblocks/issues/61 prices a million ordinary reads, a typical raw export and a month of filtered streaming.
Each comes from this table: `read`'s per-request bytes, DB time and upstream calls, `raw_export`'s, and a stream's bytes and DB time per hour.
