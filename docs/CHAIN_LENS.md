# Chain Lens: Full Chain + Filter = Subset Chain

## The Problem

The BSV chain is 20+ TB and growing exponentially.
Viewing the whole thing will soon be physically impossible in any single UI.
But you don't *need* the whole chain — you need a *lens* over it.

## The Pattern

```
full chain → filter → subset chain
```

A **lens** is a set of parameters that defines a subset of the chain:

- **Date range**: "January 2024 to March 2024"
- **Block height range**: "823000 to 835000"
- **Address set**: "all activity for address 1A1zP1..."
- **Protocol filter**: "all MAP transactions with app=qart"
- **Combination**: "MAP SET transactions from address X between Jan-Mar 2024"

The subset chain behaves like the full chain — it has blocks, transactions, a timeline — but it's small enough to visualize, scrub through, and reason about.

## Time ↔ Height Translation

Users think in dates.
The chain thinks in block heights.
We need a bidirectional mapping:

```
UTC datetime  →  block height (closest block at or after that time)
block height  →  UTC datetime (when that block was mined)
```

### API

```
GET /api/v1/blocks/at_time?t=2024-01-01T00:00:00Z
→ {"data": {"height": 823000, "time": "2024-01-01T00:00:00Z"}}

GET /api/v1/blocks/at_height?h=823000
→ {"data": {"height": 823000, "time": "2024-01-01T00:12:31Z"}}
```

### Time Map (for scrubber UIs)

A sampled lookup table for building timeline controls:

```
GET /api/v1/blocks/time_map?from=0&to=900000&step=10000
→ {"data": [
    {"height": 0, "time": "2009-01-03T18:15:05Z"},
    {"height": 10000, "time": "2009-02-12T..."},
    ...
  ]}
```

The step parameter controls resolution.
Small step = more points = smoother scrubber.
Large step = fewer points = faster load.

The UI renders this as a timeline axis where dragging maps to block heights.

## Scrubber UI Concept

```
┌─────────────────────────────────────────────────┐
│ ◀ ▶  ⏸  │ Jan 2009 ──────●───── Apr 2026 │ ⚙  │
├─────────────────────────────────────────────────┤
│                                                 │
│              [visualization area]               │
│           blocks / txs / graph / etc            │
│                                                 │
├─────────────────────────────────────────────────┤
│ Height: 823,000    Time: 2024-01-01 00:12 UTC   │
│ Blocks in view: 12,000    Txs: 4.2M             │
└─────────────────────────────────────────────────┘
```

The scrubber is a timeline slider.
Dragging it translates to block height ranges via the time map.
The visualization updates to show the subset chain for the current window.

Controls:
- **Drag** the timeline to scrub through the chain
- **Pinch/scroll** to zoom in/out (changes the window size)
- **Play** to animate forward through time
- **Filter** to apply protocol/address/type lenses

## Filter Composition

Filters compose with AND semantics:

```
lens = %{
  from_height: 823_000,
  to_height: 835_000,
  protocol: "map",
  app: "qart",
  address: nil  # not set = all addresses
}
```

Each filter narrows the subset.
The UI shows active filters as removable chips.
Removing a filter widens the view.

## Scale Considerations

At 20+ TB, even querying block headers for the full range is heavy.
The time_map endpoint samples at intervals — it doesn't load every block.
As the chain grows:

- **Increase default step size** — fewer samples for the full range
- **Adaptive resolution** — coarse for the full chain, fine for the zoomed-in window
- **Materialized summaries** — pre-compute daily/weekly/monthly roll-ups
- **Separate service** — this is the natural split point from CLAUDE.md's protocol indexing concern

The design holds whether you're looking at 1000 blocks or 1M blocks.
The only thing that changes is the sampling resolution.

## Connection to CQRS / Event Scrubbing

The subset chain *is* the read model.
The full chain is the event log.
Applying a lens is projecting events into a view.

This maps directly to CQRS:
- **Write side**: the chain (append-only, immutable)
- **Read side**: the subset chain (derived, filtered, disposable)
- **Projection**: the lens parameters
- **Replay**: scrubbing backward reconstructs earlier state

The scrubber is a time-travel debugger for the blockchain.

## Implementation Priority

1. ✅ `height_at_time/1` and `time_at_height/1` — done
2. ✅ `height_time_samples/3` — done
3. ✅ API endpoints (`at_time`, `at_height`, `time_map`) — done
4. Scrubber UI component (LiveView, uses time_map for axis)
5. Filter composition (protocol, address, date range)
6. Adaptive resolution (coarse→fine on zoom)
7. Materialized summaries for scale
