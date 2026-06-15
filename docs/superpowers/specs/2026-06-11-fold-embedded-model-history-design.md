# Fold embedded tracked models into the parent's change history

## Problem

When a tracked model is also a property of another tracked model (e.g.
`ScreenModel.counter` where both call `simToolTracked()`), one state
change produces two entries in the State tab's change history: `state.filling`
on `CounterModel#0` and `counter.state.filling` on `ScreenModel#0`.
The standalone child entry is pure noise.

## Decision

Hide the child's standalone history entries while a live tracked parent embeds
it. The child keeps its own card in the current-state model list (collapsible,
useful for id filtering). If the parent deallocates, the child's history
entries surface again.

Detection is exact, not heuristic (path-suffix/value matching breaks with two
children of the same type):

1. **StateLogger** — `SimToolStateTrackedRegistry` (internal, `@MainActor`)
   maps `ObjectIdentifier → modelId` for instances currently tracked by
   `SimToolState`; entries are added in `track`, pruned in `onStop`
   (deallocation) and `reset`. When `SimToolStateSerializer` expands a nested
   expandable **class** that is in the registry, it stamps the resulting
   object with `"$modelId": "<modelId>"`. A model's own root snapshot never
   passes through `serialize`, so it never marks itself.
2. **WebViewer** — `embeddedModelIds()` rebuilds a `childId → parentId` map on
   every render from the latest non-deallocated snapshots. The history loop
   skips events whose `modelId` is embedded. The `$modelId` key is filtered
   out of snapshot trees and diffs (`MODEL_ID_KEY`), so the marker itself
   never renders and never produces diff noise when it first appears.

## Consequences

- Wire format gains a reserved `"$modelId"` key inside nested tracked models;
  the viewer hides it everywhere.
- Events from the child keep flowing (seq advances, card stays live); folding
  is purely presentational, so the rule can change without touching the app.
- If the child is tracked after the parent's last emit, the marker appears
  only on the parent's next change — until then the child shows separately.
  In practice both registrations happen at init, before any changes.
