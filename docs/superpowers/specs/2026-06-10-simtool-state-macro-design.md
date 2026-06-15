# SimTool State Logger — `@SimToolDebugState` macro

**Date:** 2026-06-10
**Status:** Approved design

## Goal

Let an app under test annotate its `@Observable` models with a macro so that, in
debug builds, every state change is streamed to SimTool and shown in the web UI:
both the **live current state** of each model (expandable tree) and a
**history of changes** (diffs between consecutive snapshots).

Inspired by pointfreeco's `swift-debug-snapshots`, but implemented fully in this
repo with no third-party dependency, and observation-driven instead of
method-wrapping: changes are detected via the Observation framework, so
mutations from methods, SwiftUI bindings, and async tasks are all captured.
Trade-off accepted: no attribution of *which method* caused a change (possible
v2 via optional method wrapping).

## App-side usage

```swift
@Observable
@SimToolDebugState
final class AppModel {
    var count = 0
    var user: User?
}

SimToolState.track(model, name: "AppModel")   // once, e.g. at app setup
```

Activation requires all of:
- `#if DEBUG` build,
- `SIMTOOL_STATE_LOGGER=1` and `SIMTOOL_SERVER_URL` environment variables
  (same convention as `SimToolNetworkLogger`).

Otherwise the runtime is inert and the generated code compiles out
(release builds) or no-ops (debug without SimTool).

## Architecture

### 1. New SwiftPM package `StateLogger/` (mirrors `NetworkLogger/` layout)

- **`SimToolStateLogger`** (library the app links):
  - `SimToolStateReportable` protocol (`func _simToolSnapshot() -> SimToolStateValue`),
  - `SimToolState` tracker — per-instance `withObservationTracking` re-arm loop,
  - Mirror-based JSON serializer (`SimToolStateValue`),
  - batching HTTP transport (same shape as the network logger's).
- **`SimToolStateLoggerMacros`** (macro target):
  - `@SimToolDebugState` — attached member + extension macro.

### 2. The macro

Applied alongside `@Observable`, generates:

- `extension Model: SimToolStateReportable {}`,
- a `_simToolSnapshot()` member that reads **every stored property through its
  accessor** — reads inside `withObservationTracking` register access, which is
  what makes change detection work. Computed properties are skipped (macros see
  the source as written, before `@Observable` rewrites storage). Body wrapped in
  `#if DEBUG`.

Compile-time diagnostic with fix-it if the type lacks `@Observable`.
`@ObservationIgnored` properties are included in the snapshot but their changes
do not trigger events (documented limitation).

### 3. Server (`Sources/SimToolServer/StreamServer.swift`)

- `POST /api/v1/state/events` — app pushes event batches,
- `GET /api/v1/state/events?since=<cursor>` — UI polls incrementally,
- `StateEventStore` — capacity-bounded buffer (~200 events per model,
  ~50 models), cursor semantics like the log capture buffer, events tagged with
  the app launch (same as network events).

### 4. Web UI (`Sources/SimToolWeb/WebViewer.swift`)

New **"State"** inspector tab:
- list of tracked models (latest snapshot per `modelId`),
- current state as a collapsible JSON tree,
- history feed; diffs between consecutive snapshots computed in JS, rendered as
  `- old` / `+ new` lines like the Logs tab,
- deallocated models greyed out.

## Data flow

1. `SimToolState.track(model, name:)` stores a weak reference and starts:

   ```swift
   withObservationTracking {
       snapshot = model._simToolSnapshot()
   } onChange: {
       // Observation fires willSet — re-read on the next runloop tick,
       // then re-arm.
   }
   ```

2. **Debounce ~100 ms**: a burst of mutations produces one event with the final
   state.
3. Serialization: primitives as-is; nested `SimToolStateReportable` values
   recurse (and become tracked for free — their reads happen inside the same
   tracking closure); `Encodable` values via `JSONEncoder`; fallback
   `String(describing:)`. Cycle protection via `ObjectIdentifier` set; payload
   cap ~256 KB with a truncation marker.
4. Events batch and POST to `/api/v1/state/events`.
5. On deallocation of a tracked model: final event with `"deallocated": true`,
   loop stops.

### Event payload

```json
{
  "modelId": "AppModel#1",
  "name": "AppModel",
  "seq": 42,
  "timestamp": 1718000000.123,
  "snapshot": { "count": 1, "user": { "name": "Blob" } }
}
```

- `modelId` — name + per-name instance counter, stable for the instance's
  lifetime.
- `seq` — per-instance monotonic sequence number.
- Full snapshots only; no diffs over the wire (UI computes them).

## Error handling

Rule: **never break the host app.**

- Transport failure (SimTool not running): drop events silently after one
  `os_log` warning per session. No unbounded retry queue; next change sends
  fresh state.
- Serialization failure for a property → `"<unserializable: TypeName>"` instead
  of failing the snapshot.
- Re-entrancy guard: the send path must not read tracked properties outside the
  tracking closure (no observation feedback loops).
- Macro misuse (no `@Observable`) → compile-time diagnostic with fix-it.
- `#if DEBUG` gating at both macro-expansion and runtime levels.

## Testing

- **Macro** (`assertMacroExpansion`): stored vs computed, `@ObservationIgnored`,
  missing-`@Observable` diagnostic, access levels.
- **Serializer**: primitives, optionals, collections, nested models, cycles,
  fallback, payload cap.
- **Tracker**: `@Observable` fixture mutated via method / direct write / async →
  debounced events with correct `seq` and final values; deallocation event.
- **Server**: POST ingestion, cursor reads, capacity eviction, launch tagging —
  alongside existing network event tests.
- **Web UI**: manual verification (no JS test infra in this repo, by design).

## Out of scope (v2 candidates)

- Method-name attribution via body-wrapping macro (`.logMethods` option).
- Structs / TCA state support.
- Time-travel / snapshot export.
