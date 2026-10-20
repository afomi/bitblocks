# Analytics

What Bitblocks measures, what it doesn't, and what would close the feedback loop.

---

## What's instrumented now

### Operational (Prometheus + Telemetry)

Available at `/metrics` (admin-protected).

| Metric | What it measures |
|--------|-----------------|
| HTTP request counts + duration | Traffic volume and latency by route |
| Oban queue depth + job latency | Sync worker health |
| DB pool checkouts + wait times | Database pressure |
| ETS cache hit/miss (StatsCache) | Cache effectiveness |
| SSE slot usage (SseLimiter) | Concurrent stream connections |
| Rate limiter hits per IP | Abuse signals |

### Request logging (RequestLogger plug)

Structured log lines for every request: IP, user agent, path, status, duration.
Suspicious patterns flagged (path traversal, injection probes, 404 storms).

---

## What's not measured (business analytics gap)

The operational layer tells us the system is healthy.
It doesn't tell us whether it's useful.

| Question | Signal needed | Persona |
|----------|--------------|---------|
| Which API endpoints are actually used? | Request counts by endpoint + response shape | Developer |
| Which protocols do Explorers look at most? | Page views on `/transactions/:id` by detected protocol | Explorer |
| How often does a Developer follow a BCat head to its chunks? | Click-through from BCat head panel to chunk txids | Developer |
| Is the Metanet explorer used after initial load? | Node traversal events (parent/child navigation) | Explorer |
| Which order book tokens have the most viewer interest? | Page views on `/order-book` by token_id filter | Explorer |
| Do Explorers arrive via txid deep-link or browse from blocks? | Referrer + entry path | Explorer |

---

## Recommended first instrumentation

Pick the highest-value, lowest-effort signal: **protocol distribution on transaction views.**

When an Explorer views a transaction at `/transactions/:id`, log a structured event:

```
%{
  event: "tx_viewed",
  txid: txid,
  protocols: transaction.protocols,    # e.g. ["BCat", "MAP"]
  has_op_return: boolean,
  block_height: integer,
  persona_hint: "explorer" | "developer"  # inferred from user-agent / referrer
}
```

This answers: *Which protocols drive the most Explorer traffic?*
That directly informs which protocol parsers and UI panels to invest in next.

---

## How analytics should flow back to the cycle

```
Analytics signal → update Personas (are our assumptions right?)
                → generate new Stories (what do users actually need?)
                → reprioritize Backlog (which features get traction?)
```

Example: if `tx_viewed` shows 80% of views are on OP_RETURN transactions with no protocol match
(unrecognized protocols), that's a signal to prioritize protocol registration tooling for the Protocol Author persona — a persona the data model already anticipates but that has no stories yet.
