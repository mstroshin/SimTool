# Web Viewer: Terminate App Button

**Date:** 2026-06-12
**Status:** Approved

## Problem

The web viewer toolbar offers Home, Screenshot, and Shake, but no way to quit the inspected
app. Killing the app (to test cold launches, crash recovery, or state restoration) requires
switching to a terminal for `xcrun simctl terminate`.

## Design

A Terminate button sits in the toolbar immediately to the right of Shake. Clicking it kills
the inspected app on the simulator — the same effect as `xcrun simctl terminate`.

### Web UI (`WebViewer.swift`)

- `<button id="terminate" class="icon-btn" type="button" title="Terminate app">⏹️</button>`
  placed right after the Shake button. The stop-square icon matches Xcode's "stop running
  app" affordance.
- `pressTerminate()` POSTs `{action: "terminate"}` to `/api/v1/input`; failures surface in
  the status bar as `terminate failed: <message>`, mirroring Home/Shake.

### Server (`StreamServer.swift`)

New `case "terminate"` in `perform(input:action:)`:

- Bundle id resolution: `input.name` if provided, else `config.defaultLogApp` (the inspected
  app the server was started with). Neither present → `SimToolError` explaining that
  terminate needs an app bundle id (start the server with `--app` or pass `name`).
- Runs `xcrun simctl terminate <udid> <bundleId>`. A non-running app makes simctl exit
  non-zero; like Shake and Home, the route still answers `ok: true` with simctl's output —
  pressing Terminate twice is harmless.

## Testing

`SimToolWebTests`: viewer embeds the `terminate` button next to Shake, has a
`pressTerminate` handler, and posts the `terminate` action (mirrors the Shake button test).
Server-side `perform` shells out to `xcrun` and has no test seam, matching shake/home.
Manual: press the button with a running app — the app quits to springboard.
