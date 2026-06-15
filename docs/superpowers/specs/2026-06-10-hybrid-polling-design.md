# Hybrid tracking: `poll:` parameter, plain classes, and structs

**Date:** 2026-06-10
**Status:** Approved design
**Amends:** `2026-06-10-simtool-state-macro-design.md` (tracking modes, macro applicability)
and `2026-06-10-scalar-only-snapshots-design.md` (expansion protocol).

## Motivation

`@SimToolDebugState` currently requires `@Observable` classes because change
detection is observation-only. That excludes plain classes (no signal at all) and
structs (cannot be `@Observable`), and pins the tracker to iOS 17+. A polling mode
covers what observation cannot reach, while observation stays the default where it
is strictly better (per-transition diffs, zero idle cost).

## API

```swift
@MainActor
public enum SimToolState {
    public static func track(
        _ model: some SimToolStateReportable,   // AnyObject — tracker holds it weakly
        name: String? = nil,                    // defaults to String(describing: type(of: model))
        poll: Duration? = nil
    )
}

extension SimToolStateReportable {
    /// Chainable registration: `CounterModel(codeLength: 6).simToolTracked()`.
    /// Nonisolated so it can be called from any context (e.g. Factory DI
    /// closures); hops to the main actor internally to register.
    @discardableResult
    public func simToolTracked(_ name: String? = nil, poll: Duration? = nil) -> Self
}
```

`track` is **idempotent per instance**: a second call for an already-tracked
object (by `ObjectIdentifier`) is ignored, so chaining `.simToolTracked()` in a
cached/singleton DI factory or calling it twice can never create duplicate
observers. The tracked-identifier set is pruned opportunistically (entries for
deallocated models are removed when their observers stop).

Mode selection at `track` time:

1. `poll` non-nil → **polling mode** at that interval (works for `@Observable`
   models too — an escape hatch).
2. `poll == nil` and the model conforms to `Observation.Observable` (runtime
   check `model is any Observable`, availability-guarded) → **observation mode**,
   identical to today's behavior.
3. `poll == nil`, plain class → **auto-fallback to polling at 1 s**, plus a
   one-time `os_log` info line per session:
   "`<name>` is not Observable — polling every 1 s; pass `poll:` to tune".

Top-level tracking remains classes-only. Structs participate as nested values.

## Polling observer

A second observer type beside `StateModelObserver` (shared emit/seq/pid/sink
plumbing; extract shared pieces only as far as the implementation naturally
allows — duplication of a few lines is acceptable over a forced abstraction):

- Main-actor `Task` loop: sleep `interval` → if weak model is nil → emit final
  `deallocated: true` event, stop. Otherwise re-snapshot.
- Emit only when the new `SimToolStateValue` differs from the last emitted one
  (`Equatable`). The tick itself is the coalescing — no debounce.
- Initial snapshot still emitted immediately at `track` time (both modes).
- `stop()` / `SimToolState.reset()` cancel the loop.

## Protocol split

```swift
public protocol SimToolStateExpandable {
    @MainActor
    func _simToolSnapshot(visited: inout Set<ObjectIdentifier>) -> SimToolStateValue
}

public protocol SimToolStateReportable: SimToolStateExpandable, AnyObject {}
```

The no-arg `_simToolSnapshot()` convenience moves to `SimToolStateExpandable`.

## Macro changes

- Accepts **classes and structs**. Enums (and anything else) are rejected with
  the diagnostic: "'@SimToolDebugState' can only be applied to a class or a
  struct".
- The `@Observable` requirement and its diagnostic + fix-it are **deleted**
  (mode selection is a runtime concern now).
- Class expansion: conformance to `SimToolStateReportable`; generated method
  keeps `visited.insert(ObjectIdentifier(self))`.
- Struct expansion: conformance to `SimToolStateExpandable`; generated method
  omits the `visited.insert` line (value types cannot self-reference).
- Generated member shape otherwise unchanged (`#if DEBUG`, stored properties
  only, `serialize(self.x as Any, visited: &visited)`).

## Serializer changes

- The expansion check becomes `value as? any SimToolStateExpandable`.
- The pre-recursion cycle check applies only to class instances
  (`type(of: value) is AnyClass`); struct expansion needs no guard.
- All other scalar-only rules unchanged.

## Semantics notes

- Nested struct mutation reassigns the parent's stored property, so it is caught
  by the parent's observation (or the parent's poll tick) — no extra machinery.
- Nested plain-class internals still do NOT trigger the parent; their current
  state appears whenever the parent re-snapshots. Documented limitation.
- Polling misses transitions shorter than the interval; observation remains the
  default for `@Observable` models for that reason.

## Testing

- Tracker: polling emits on change within ~2 ticks; no events while unchanged;
  `deallocated` emitted on tick after release; auto-fallback engages for a plain
  class with `poll: nil`; explicit `poll:` forces polling for an `@Observable`
  model; default name derives from the dynamic type; `track` twice on the same
  instance creates one observer; `.simToolTracked()` returns the instance and
  registers it (from a nonisolated context).
- Macro: struct expansion (conformance + no `visited.insert`); plain class
  accepted without diagnostics; enum still rejected with the updated message.
- Serializer: an annotated struct expands; un-annotated stays a placeholder.
- Integration fixture: add a `@SimToolDebugState` struct property to
  `FixtureModel`, assert it expands; existing tests keep passing.
- README: document `poll:`, plain-class auto-fallback, struct annotation, the
  chainable `.simToolTracked()` helper, and a DI-integration note (e.g. Factory:
  `Factory(self) { Model().simToolTracked() }` or a debug-only `.decorator`).

## Out of scope

- Polling for *parts* of a tree (per-property intervals).
- Backporting the tracker below iOS 17 (polling makes it possible; not done now).
