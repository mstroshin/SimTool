# Remove the native window — web-only viewer

**Date:** 2026-06-23
**Status:** Approved

## Goal

Remove the SwiftUI/AppKit native window from SimTool entirely. The browser-based
web viewer (`SimToolWeb` served by `SimToolServer`) becomes the only visual
interface. The CLI keeps its current shape minus the window-launch flags.

## Motivation

The native window (`SimToolUI`) duplicates the web viewer's functionality —
live simulator rendering plus log and network inspectors — while carrying a
second, divergent SwiftUI codebase and a private-framework native-capture path
in the GUI layer. Consolidating on the web viewer removes that duplication and
the maintenance cost of a second UI.

## Scope

### Removed

1. **`SimToolUI` target and product** — both source files
   (`SimToolSessionView.swift`, `NativeSimulatorStreamView.swift`), the
   `.target(name: "SimToolUI")` definition, the `.library(name: "SimToolUI")`
   product, and the `"SimToolUI"` dependency entry on the `SimToolCLI` target —
   all in `Tool/Package.swift`.

2. **CLI window plumbing** in `Tool/Sources/SimToolCLI/SimTool.swift`:
   - `import SimToolUI` and the `#if canImport(AppKit) && canImport(SwiftUI)`
     `import AppKit` / `import SwiftUI` block.
   - `runNativeWindow(session:server:)`, `SimToolWindowDelegate`, and
     `SimToolWindowDelegateRetainer`.
   - The `--window` flag on `Serve` and its `validate()` check rejecting
     `--web --window`.
   - The `--native` flag on `Run` and its `validate()` check rejecting
     `--web --native`.

3. **Tests** in `Tool/Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift`
   that assert `--native` / `--window` parsing and their conflict with `--web`.

4. **Docs** — `README.md` references to `--native`, `--window`, and `SimToolUI`.

### Changed (not removed)

- `runViewer(...)` loses its `window: Bool` parameter. The trailing
  `if window { await runNativeWindow(...) ; return }` branch is removed; the
  function always blocks in the foreground
  (`while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }`)
  after starting the server.
- The server config inside `runViewer` changes from `captureEnabled: !window`
  to `captureEnabled: true`. Server-side H.264 capture was previously disabled
  in window mode because the window captured frames natively; with web-only it
  must always be on.
- `shouldOpenBrowser(...)` loses its `nativeWindow` parameter, reducing to
  `webRequested && !json && !detachedChild`. Both call sites (`Serve.run`,
  `Run.run`) drop the `nativeWindow:` argument.

### Out of scope (untouched)

- `SimToolStream` (native frame capture / H.264 encode) — consumed by
  `StreamServer` to produce the web stream. Stays.
- `SimulatorDirectInputClient` — used by `StreamServer` for input. Stays.
- The `--web` opt-in browser behavior and the deprecated `--no-open` no-op are
  unchanged.

## Verification

- `swift build --package-path Tool`
- `swift test --package-path Tool` — in particular `SimToolCLITests` after the
  window/native assertions are removed.
- Manual:
  - `simtool serve` starts the server and prints its URL (no window).
  - `simtool serve --web` opens the browser viewer.
  - `simtool serve --window` and `simtool run --native` now fail as unknown
    flags.
