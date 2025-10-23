# Event-Driven, Object-Oriented Bitcoin

This document sketches a repeatable way to represent CRUD-flavoured actions as
immutable Bitcoin events, combining Bitcom namespaces, AIP signatures, and
schema-driven payloads. It is intentionally opinionated and geared toward
portability: the same events can be produced from Elixir (via `BitcomPort`) and
consumed by services using TXT, Planaria, or bespoke projections.

## Core ideas

- **Immutable events, mutable projections** – Every create/update/delete occurs
  as a new on-chain event. Off-chain services project those events into whatever
  stateful view or query layer they need.
- **Explicit object identifiers** – Each event references the logical object ID
  (UUID, paymail, etc.) so projections can group related events.
- **Versioned schemas** – Payloads are encoded using a known schema version to
  keep producers/consumers in lockstep.
- **AIP signatures** – The actor issuing the event signs the payload to prove
  authorship and provide non-repudiation.
- **Bitcom routing** – Namespaces map to aggregates (object types) and define
  an extensible path for future command/event families.

## Suggested naming conventions

| CRUD intent | Event type                 | Bitcom path example                          |
| ----------- | -------------------------- | -------------------------------------------- |
| Create      | `<Aggregate>Created`       | `bit://com.yourapp/<aggregate>/<id>/created` |
| Update      | `<Aggregate>Updated`       | `bit://com.yourapp/<aggregate>/<id>/updated` |
| Delete      | `<Aggregate>Deleted`       | `bit://com.yourapp/<aggregate>/<id>/deleted` |
| Restore     | `<Aggregate>Restored`      | Optional extension                            |
| Snapshot    | `<Aggregate>SnapshotTaken` | Used for large aggregates                     |

For small systems a simpler layout works fine:

```
["1YourBitcomPrefix", "note", object_id, event_type, schema_version, payload...]
```

## Object lifecycle contract

1. **Create** event introduces `object_id` and the initial state.
2. **Update** events mutate specific fields; consumers apply them in order.
3. **Delete** event marks the object as removed (hard or soft). Downstream
   projections can either purge or set `deleted_at`.
4. Optional **restore** events reverse deletion if business rules allow it.

Every event includes:

- `object_id`
- `event_type`
- `schema_version`
- `payload` (fields relevant to that change)
- `metadata` (optional correlation ID, causation ID, timestamps)

## Encoding toolbox

- **Schema** – Use Bitcoin Schema or a bespoke JSON schema. Example identifier:
  `com.yourapp.note/v1`.
- **Serialization** – Encode payload to JSON (for human readability) or a binary
  format with predictable offsets.
- **Signature** – Use AIP (`15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva`) to sign the
  serialized payload.
- **Bitcom** – Organise payload with `["bitcom", namespace, aggregate, ...]`.

## Example: Note aggregate

### Create

Script elements (pre OP_RETURN encoding):

```
[
  "1D1ZrZNe3JUo7ZqDKZ6x8j8V1g8jc6r6zc", # App namespace
  "note",
  "note/9b7d9c2e",                      # object_id
  "NoteCreated",
  "com.yourapp.note/v1",
  "{\"title\":\"Hello\",\"body\":\"World\"}",
  "|",
  "15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva", # AIP
  "application/json",
  "<public_key_base64>",
  "<signature_base64>"
]
```

### Update (rename title)

```
[
  "1D1Z...",
  "note",
  "note/9b7d9c2e",
  "NoteTitleUpdated",
  "com.yourapp.note/v1",
  "{\"title\":\"New title\"}",
  "|",
  ...AIP signature...
]
```

### Delete

```
[
  "1D1Z...",
  "note",
  "note/9b7d9c2e",
  "NoteDeleted",
  "com.yourapp.note/v1",
  "{}",
  "|",
  ...AIP signature...
]
```

Use `BitcomPort.Script.op_return/1` (see `docs/aip_bitcom_integration.md`) to
encode each list into an `OP_FALSE OP_RETURN` script before broadcasting.

## Event sourcing checklist

1. **Idempotency** – Include transaction ID or custom event ID so projections can
   avoid double-application.
2. **Ordering** – Miners determine final ordering. If strict sequencing matters,
   embed a monotonically increasing `event_number` in the payload.
3. **Correlations** – Use metadata to link commands to resulting events.
4. **Authorization** – Store whitelisted public keys per aggregate type and
   reject events signed by unknown actors.
5. **Conflict resolution** – Decide how projections behave when out-of-order or
   conflicting events arrive (last-write-wins, CRDT merge, etc.).

## Building projections

1. Subscribe to a transaction feed (e.g., Bitbus, Planaria, Whatsonchain).
2. Filter for your Bitcom namespace.
3. Parse the OP_RETURN stack using Shapeshifter or BSV tooling.
4. Verify the AIP signature.
5. Apply the event to your projection store (SQL, KV, TXT tape, etc.).

Example projection pseudocode:

```elixir
case event_type do
  "NoteCreated" ->
    upsert(notes, object_id, payload |> Map.put("deleted_at", nil))

  "NoteTitleUpdated" ->
    update(notes, object_id, %{title: payload["title"]})

  "NoteDeleted" ->
    update(notes, object_id, %{deleted_at: payload["timestamp"] || DateTime.utc_now()})
end
```

## Replay to rebuild state

Replaying events is the safest way to reconstruct an object's state at any point
in time. Collect every event for the target `object_id`, sort by your preferred
ordering (timestamp, `event_number`, or block height), then fold them into an
aggregate structure.

```elixir
defmodule NoteProjector do
  def apply(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      case event.type do
        "NoteCreated" ->
          Map.merge(acc, event.payload) |> Map.put(:deleted_at, nil)

        "NoteTitleUpdated" ->
          Map.put(acc, :title, event.payload["title"])

        "NoteBodyUpdated" ->
          Map.put(acc, :body, event.payload["body"])

        "NoteDeleted" ->
          Map.put(acc, :deleted_at, event.payload["timestamp"] || DateTime.utc_now())

        _ ->
          acc
      end
    end)
  end
end
```

Given the same ordered event stream, any consumer can deterministically rebuild
state—whether there are 1 or 1,000 events. Snapshots can be added as optional
optimisations; the replay contract stays the same.

### Developer experience with LiveView

LiveView processes can subscribe to a projection topic keyed by the actor’s
Bitcoin address. When a new event that verifies against that address lands on
the bus, the supervising process replays or incrementally applies it via
`NoteProjector.apply/1` and pushes the resulting assign into the socket. A
typical flow looks like:

1. Resolve the address to a known `public_key` so incoming events can be
   verified with AIP.
2. Start a projector process per address (or aggregate) that keeps the latest
   materialised state and the supporting transaction IDs.
3. Stream blockchain notifications into that process (`handle_info/2`), append
   the event to the in-memory list, and call `apply/1` to derive the new note
   snapshot.
4. Broadcast both the state change and the backing transaction metadata to
   interested LiveView components so they render updates in near real time.

Because projections remain pure functions, LiveView developers can run
`NoteProjector.apply/1` in tests with fabricated event streams, ensuring the
socket assigns will behave the same way once wired to actual blockchain feeds.
The address-centric supervisor strategy keeps the developer experience fluid:
any component that knows the user’s address (and holds the signing key) can
spin up a projector, dispatch commands, and watch the resulting transactions
settle without manual wiring.

### Git-style mental model

Thinking about an address like a Git repository helps frame the ergonomics:

- Each transaction is a commit signed by the address owner, containing an
  append-only diff to the aggregate state.
- `object_id` values behave like file paths, letting projections focus on a
  single “directory” (aggregate) inside the wider repo.
- Block height or a local `event_number` serves as the commit sequence, so you
  can “checkout” any historical revision by replaying up to that point.
- Snapshots act like Git tags—immutable anchors that make cloning large repos
  cheaper without changing the underlying history.

Under this lens, LiveView components are simply watchers on a repo remote:
they receive commits as they land, merge them into a working tree via the
projector, and rerender whenever the working copy changes.

## Searching and sharing

TXT (`tmp/txt.network/README.md`) excels at curating and sharing these events:

- Save the raw transaction once it broadcasts.
- Tag events with `aggregate`, `object_id`, `event_type`.
- Build public explorers that render history per object.

## Questions for further refinement

- Should schema identifiers live in a dedicated cell for easier indexing?
- How to represent binary payloads (images, files) while keeping events small?
- Can we define a JSON-LD context so payloads stay self-describing?
- Do we need conventions for compensating events / sagas?

This is a starting baseline. As you experiment, add concrete schema examples,
OpenAPI docs for projections, or even a Hex package so others can adopt the
same event vocabulary.
