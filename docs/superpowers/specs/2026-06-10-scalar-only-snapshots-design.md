# Scalar-only snapshots for `@SimToolDebugState`

**Date:** 2026-06-10
**Status:** Approved design
**Amends:** `2026-06-10-simtool-state-macro-design.md` (serialization rules)

## Motivation

Live testing in a real host app showed that deep Mirror/Encodable serialization
of un-annotated nested objects dumps entire DI/SDK object graphs into snapshots:
33 KB payloads, garbage diffs from lazy-storage churn, and sensitive values
(analytics API key, userId, deviceId) leaking into the web UI.

## Rule

`SimToolStateSerializer` emits **only scalars and collections of scalars**.
Nested structs and classes are reduced to a type placeholder — unless the nested
type is itself annotated with `@SimToolDebugState`, in which case it expands via
its own generated snapshot.

Resolution order (replaces the previous pipeline in `StateSerializer.swift`):

1. `SimToolStateValue` passthrough; Optional unwrap (nil → `null`) — unchanged.
2. **Scalars, full value:** `Bool`, `String`, all `Int`/`UInt` widths, `Double`,
   `Float`, `Date` (ISO8601 string), `URL` (absolute string).
3. **`SimToolStateReportable`** (i.e. `@SimToolDebugState` classes): recurse via
   `_simToolSnapshot(visited:)`, cycle-guarded — unchanged. Nested tracked models
   keep registering for observation through these reads.
4. **Collections** (Mirror `.collection` / `.set`): array of elements, each
   serialized by this same rule. `["a","b"]` stays full;
   `[User]` → `["<User>", "<User>"]` (element count stays diff-visible).
   **Dictionaries**: object with `String(describing:)` keys, values by the same
   rule.
5. **Enums**: no payload → case-name string (`"idle"`); with payload →
   `{"caseName": <payload serialized by the same rule>}` —
   `{"filling": 2}`, `{"failure": "<APIError>"}`.
6. **Everything else** (structs, classes, tuples, closures, `Data`, …):
   placeholder string `"<TypeName>"` via `String(describing: type(of: value))`.

## Deleted behavior

- The `Encodable` → `JSONEncoder` path (un-annotated Codable structs no longer
  expand).
- The Mirror expansion of struct/class/tuple children.
- The leading-underscore label stripping (only existed for Mirror'd `@Observable`
  storage).
- The generic-class cycle guard (the reportable-path guard remains; the
  macro-generated method still inserts `self` into `visited`).

Net effect: the serializer shrinks; placeholders are stable strings, so they
never produce diff noise.

## Unchanged

- Wire format (`SimToolStateValue`), payload models, store, server routes,
  client, web UI — no changes.
- Tracker, debounce, deallocation events, env activation, 256 KB cap (still a
  safety net, now rarely hit).
- Macro expansion shape (`_simToolSnapshot` reading stored properties through
  accessors).

## Testing

- Rewrite `StateSerializerTests` to the new rule: scalars unchanged; struct →
  `"<EncodableUser>"`; plain class → placeholder; mixed arrays; dictionary with
  struct values → placeholder values; enum payloads (scalar shown, nested →
  placeholder); reportable recursion + cycle guard unchanged.
- Extend `MacroIntegrationTests`: add a non-reportable struct property to the
  fixture, assert it renders as a placeholder while the `@SimToolDebugState`
  child still expands.
- README: update the usage notes (nested types need their own annotation to be
  visible).
