# Logs: Text Selection and Copy-Entry Context Menu

**Date:** 2026-06-11
**Status:** Approved

## Problem

Selecting text in a log row fires the row's click handler on mouseup, which opens the detail
view and destroys the selection. Users cannot select-and-copy fragments of a log line, and
there is no way to copy a full entry in one action.

## Scope

`Sources/SimToolWeb/WebViewer.swift` (inline HTML/JS). Logs tab, plus the same selection guard
on Network rows (identical drill-down pattern, identical problem).

## Design

### 1. Selection guard on row clicks

In the click handlers of `.logs-row` and `.network-row`: if `window.getSelection()` is
non-collapsed after mouseup, return without opening the detail view. A plain click (no
selection) behaves as before.

### 2. Logs context menu

A new `logsMenu` element reuses the `.ax-menu` / `.ax-menu-item` classes and the established
menu behavior (fixed positioning with viewport clamping, dismissal on outside click, Escape,
scroll, tab switch, and inspector close).

- Right-click on a `.logs-row` opens the menu with one item: **Copy entry**.
- If text is selected when right-clicking, our menu does NOT open — the native browser menu
  appears so the user can copy the selection.
- **Copy entry** copies the full entry via the existing `axWriteClipboard` helper in the format
  `<timestamp> <level> <subsystem>: <message>`, skipping absent fields. The message is the full
  `entry.message` from the data, not the rendered (possibly clipped) text.

### 3. Testing

Extend `SimToolWebTests` with string-presence anchors: `id="logsMenu"`, `id="logsMenuCopy"`,
`function showLogsMenu`, `function logEntryText`, and `getSelection` (the click guard).
Manual verification in the browser: select text in a log row (selection survives, detail does
not open), right-click → Copy entry puts the full line on the clipboard, selection right-click
shows the native menu.
