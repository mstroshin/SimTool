# Network Logs: Include/Exclude Filter Chips

**Date:** 2026-06-11
**Status:** Approved

## Goal

Let users hide noisy requests (polling, health checks) and focus on specific endpoints in the
Network tab of the SimTool web viewer, via persistent include/exclude filter chips and a
right-click context menu on request rows.

## Scope

All inspector tabs. Chips (Enter / `-term` / Backspace / ✕ / persistence) work on Network, Logs,
State, and AX, matching against each tab's existing filter fields. The right-click context menu
exists on the Network tab only. All changes live in `Sources/SimToolWeb/WebViewer.swift`
(inline HTML/CSS/JS).

**Update 2026-06-11:** originally Network-only; extended to all tabs at user request. Chip state
is per-tab (`filterChipsByTab`), persisted under `simtool.filterChips` (JSON object keyed by tab
name). The filter row sits below the tab buttons, full width. Chip matching per tab: Network —
request summary/status/protocol/host; Logs — message/subsystem/category/process/level; State —
model id; AX — id/label/value/title/role/roleDescription/type.

## UI

### Filter field with chips

The existing `#inspectorFilter` input is wrapped in a field-styled container that renders chips
to the left of the text input:

```
Filter: [ (api ✕)(−health ✕)  live text…  ] (?)
```

- **Include chip** — green, created by typing text and pressing Enter, or via context menu
  "Include".
- **Exclude chip** — red, label prefixed with "−", created by typing `-text` and pressing Enter,
  or via context menu "Exclude".
- Each chip has a ✕ button that removes it.
- Backspace in an empty input removes the last chip.
- Chips and the help button are shown only when the Network tab is active.

### Help button

A small `?` button after the filter field opens a popover explaining usage:

- Live typing filters by substring (method, URL, status, protocol, host).
- Enter turns the text into an include chip.
- `-text` + Enter creates an exclude chip.
- Right-click a request row to quickly Include/Exclude its path.

The popover closes on outside click or Escape.

### Context menu

Right-clicking a `.network-row` opens a context menu (reusing the `axMenu` pattern: fixed
positioning, boundary clamping, hide on outside click/scroll) with two items:

- `Exclude '<path>'`
- `Include '<path>'`

`<path>` is the request's URL path without host and query (for gRPC: `service/method`),
obtained from the existing `requestPath()` helper.

## Filtering semantics

Applied in `filteredNetworkEvents()`; chip matching uses the same case-insensitive substring
test over the same fields as the current filter (request summary, status, protocol, host):

1. An event is **hidden** if it matches any exclude chip (exclude wins over include).
2. If include chips exist, an event is **shown only if it matches at least one** include chip (OR).
3. Live input text is an additional substring filter applied on top of chips (current behavior).

## Chip management rules

- No duplicate chips (same kind + same term, case-insensitive).
- Adding an exclude chip removes an identical include chip and vice versa.

## Persistence

Network chips are saved to `localStorage` under `simtool.networkFilterChips` (JSON array of
`{kind: "include"|"exclude", term: string}`) and restored on page load. Live input text is not
persisted. Malformed stored data is ignored and reset.

## Implementation notes

- **HTML** (~line 52): wrap `#inspectorFilter` in a chip container; add `?` button, help
  popover element, and network context menu element.
- **CSS**: chip styles (green/red variants), field-look wrapper, popover, context menu (reuse
  `.ax-menu` styling approach).
- **JS**: `networkChips` state array; Enter/Backspace handling in the filter input (Network tab
  only); chip render function; `filteredNetworkEvents()` extension; `contextmenu` handler on
  network rows; localStorage load/save.

## Testing

No JS test infrastructure exists in the project. Verify manually: run `simtool run`, open the
web viewer, generate traffic, and check chip creation (Enter, `-term`, context menu), removal,
exclude-over-include precedence, OR semantics for includes, persistence across reload, and that
other tabs are unaffected.
