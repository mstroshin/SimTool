# Remove the Native Window — Web-Only Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the SwiftUI/AppKit native window (`SimToolUI`) from SimTool entirely, leaving the browser-based web viewer as the only visual interface.

**Architecture:** The native window was a `SimToolUI` library target driven from the `simtool` CLI via `--window` (serve) / `--native` (run). We strip the CLI plumbing first (so nothing imports the module), then delete the `SimToolUI` target/product/sources, then update docs. The web viewer (`SimToolWeb` served by `SimToolServer`) and the shared capture/input layers (`SimToolStream`, `SimulatorDirectInputClient`) are untouched.

**Tech Stack:** Swift 5.9, SwiftPM, swift-argument-parser, XCTest. The CLI package lives under `Tool/`.

## Global Constraints

- Build the CLI package with `swift build --package-path Tool`; test with `swift test --package-path Tool`. (The repo root is a separate logger-only package.)
- This is a public, app-agnostic repo: no real app/company identifiers in code, fixtures, or docs.
- Each commit must leave both packages compiling and all tests green.
- Commit messages end with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.
- Work happens on the `refactor/remove-native-window` branch (already created).

---

### Task 1: Strip window plumbing from the CLI and its tests

Removes every reference to the native window from `SimToolCLI`. The source and the CLI surface tests are coupled — `shouldOpenBrowser`'s signature change and the removed `--window`/`--native` flags break the tests — so they change together in one task. After this task `SimToolUI` is no longer imported or used anywhere, but its target/product still exist (harmless, unused) and the build stays green.

**Files:**
- Modify: `Tool/Sources/SimToolCLI/SimTool.swift`
- Test: `Tool/Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `shouldOpenBrowser(webRequested:json:detachedChild:) -> Bool` (the `nativeWindow` parameter is gone); `runViewer(device:host:port:defaultLogApp:testSessionsRoot:printSessionJSON:openBrowser:sessionId:)` (the `window` parameter is gone). `Serve` no longer has a `window` flag or a `validate()`; `Run` no longer has a `native` flag or a `validate()`.

- [ ] **Step 1: Update the CLI surface tests to the post-removal shape**

In `Tool/Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift`:

Replace `testRunParserAcceptsViewerFlagsAndConfig` (drops `--native` and the `command.native` assertion):

```swift
    func testRunParserAcceptsViewerFlagsAndConfig() throws {
        let command = try Run.parse(["--no-network", "--no-state", "--config", ".simtool/config.yml", "--json"])
        XCTAssertFalse(command.web)
        XCTAssertTrue(command.noNetwork)
        XCTAssertTrue(command.noState)
        XCTAssertEqual(command.config, ".simtool/config.yml")
        XCTAssertTrue(command.common.json)
    }
```

Delete `testRunRejectsBothViewerFlags` entirely (it asserted the `--web --native` mutual-exclusion that no longer exists):

```swift
    func testRunRejectsBothViewerFlags() {
        XCTAssertThrowsError(try Run.parse(["--web", "--native"]))
    }
```

Replace `testBrowserOpensOnlyWhenWebRequested` (drops the `nativeWindow:` argument and the native-window case):

```swift
    func testBrowserOpensOnlyWhenWebRequested() {
        XCTAssertFalse(shouldOpenBrowser(webRequested: false, json: false, detachedChild: false),
                       "the browser must stay closed unless --web is passed")
        XCTAssertTrue(shouldOpenBrowser(webRequested: true, json: false, detachedChild: false))
        XCTAssertFalse(shouldOpenBrowser(webRequested: true, json: true, detachedChild: false),
                       "--json output is for scripts; never open a browser")
        XCTAssertFalse(shouldOpenBrowser(webRequested: true, json: false, detachedChild: true),
                       "detached children run headless")
    }
```

Replace `testServeParserSupportsOptInWeb` (drops the trailing `--web --window` assertion):

```swift
    func testServeParserSupportsOptInWeb() throws {
        XCTAssertFalse(try Serve.parse([]).web, "serve must not open the browser by default")
        XCTAssertTrue(try Serve.parse(["--web"]).web)
        // --no-open is a deprecated no-op kept so existing scripts keep parsing.
        XCTAssertTrue(try Serve.parse(["--no-open"]).noOpen)
    }
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run: `swift test --package-path Tool --filter SimToolCommandSurfaceTests 2>&1 | tail -30`
Expected: compile FAILS — the source still has the old `shouldOpenBrowser` signature with `nativeWindow:` and the `Run.native` / `Serve.window` flags the new tests no longer reference, but `runViewer`/`shouldOpenBrowser` still expect the old shapes. (We fix the source in the next steps.)

- [ ] **Step 3: Remove the SimToolUI / AppKit / SwiftUI imports**

In `Tool/Sources/SimToolCLI/SimTool.swift`, delete the `import SimToolUI` line:

```swift
import SimToolUI
```

And delete the conditional AppKit/SwiftUI import block that follows the import group:

```swift
#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI
#endif
```

- [ ] **Step 4: Remove the `--window` flag and `validate()` from `Serve`**

In the `Serve` struct, delete the `--window` flag:

```swift
    @Flag(help: "Open a native SwiftUI window with direct simulator rendering.")
    var window = false
```

And delete the now-pointless validator (it only rejected `--web --window`):

```swift
    func validate() throws {
        if web && window {
            throw ValidationError("Pass at most one of --web or --window.")
        }
    }
```

- [ ] **Step 5: Update the `runViewer` call in `Serve.run`**

Replace the call (drop the `window:` argument and the `nativeWindow:` argument):

```swift
        try await runViewer(
            device: resolved,
            host: host,
            port: port,
            defaultLogApp: app.flatMap { $0.isEmpty ? nil : $0 },
            testSessionsRoot: SimToolDirectory.testSessionsDirectory(in: SimToolDirectory.resolve()),
            printSessionJSON: common.json || detachedChild,
            openBrowser: shouldOpenBrowser(webRequested: web, json: common.json, detachedChild: detachedChild),
            sessionId: sessionId
        )
```

- [ ] **Step 6: Drop the `nativeWindow` parameter from `shouldOpenBrowser`**

Replace the function and its doc comment:

```swift
/// The browser viewer is opt-in: it opens only when the user passes `--web`, and
/// never for machine-facing invocations (JSON output, detached children). The
/// server starts and prints its URL regardless.
func shouldOpenBrowser(webRequested: Bool, json: Bool, detachedChild: Bool) -> Bool {
    webRequested && !json && !detachedChild
}
```

- [ ] **Step 7: Drop the `window` parameter from `runViewer` and always capture**

Replace the doc comment and signature so `window` is gone:

```swift
/// Shared simulator-stream viewer bootstrap used by both `serve` and `run`:
/// start the server (reclaiming the port if needed), persist the session,
/// install signal handlers, report it, optionally open the browser, and block
/// in the foreground until interrupted.
func runViewer(
    device: SimulatorDevice,
    host: String,
    port: UInt16,
    defaultLogApp: String?,
    testSessionsRoot: URL,
    printSessionJSON: Bool,
    openBrowser: Bool,
    sessionId: String?
) async throws {
```

In the same function, change the server config so capture is always on (was `captureEnabled: !window`):

```swift
        captureEnabled: true,
```

And remove the native-window branch at the end of the function, leaving only the foreground block. Replace:

```swift
    if window {
        await runNativeWindow(session: session, server: server)
        return
    }
    while !Task.isCancelled {
        try await Task.sleep(for: .seconds(3600))
    }
```

with:

```swift
    while !Task.isCancelled {
        try await Task.sleep(for: .seconds(3600))
    }
```

- [ ] **Step 8: Remove the `--native` flag, `validate()`, and update the abstract in `Run`**

In the `Run` struct configuration, replace the abstract:

```swift
        abstract: "Read .simtool/config.yml, launch the configured app, and start the web viewer server."
```

Delete the `--native` flag:

```swift
    @Flag(help: "Open a native SwiftUI window instead of the browser viewer.")
    var native = false
```

Delete the validator:

```swift
    func validate() throws {
        if web && native {
            throw ValidationError("Pass at most one of --web or --native.")
        }
    }
```

- [ ] **Step 9: Update the `runViewer` call in `Run.run`**

Replace the call (drop `window:` and `nativeWindow:`):

```swift
        try await runViewer(
            device: booted,
            host: projectConfig.server.host,
            port: projectConfig.server.port,
            defaultLogApp: projectConfig.bundleId,
            testSessionsRoot: SimToolDirectory.testSessionsDirectory(in: projectConfig.simtoolDirectory),
            printSessionJSON: common.json,
            openBrowser: shouldOpenBrowser(webRequested: web, json: common.json, detachedChild: false),
            sessionId: nil
        )
```

- [ ] **Step 10: Delete the native-window runtime block**

Delete the entire `#if canImport(AppKit) && canImport(SwiftUI)` … `#endif` block that defines `runNativeWindow(session:server:)`, `SimToolWindowDelegateRetainer`, and `SimToolWindowDelegate`. It begins at the `runNativeWindow` comment/`#if` (just after the `Interactive` command's closing brace) and ends at the `#endif` immediately before `private extension URL`. The block to remove:

```swift
#if canImport(AppKit) && canImport(SwiftUI)
@MainActor
private func runNativeWindow(session: SessionInfo, server: StreamServer) {
    // … full body …
}

private final class SimToolWindowDelegateRetainer {
    // … full body …
}

private final class SimToolWindowDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    // … full body, through stopOnce() …
}
#endif
```

Leave the `private extension URL { … }` that follows it in place.

- [ ] **Step 11: Build and test**

Run: `swift build --package-path Tool 2>&1 | tail -20`
Expected: build SUCCEEDS with no `SimToolUI` / `runNativeWindow` / `window` references remaining.

Run: `swift test --package-path Tool --filter SimToolCLITests 2>&1 | tail -20`
Expected: PASS — all `SimToolCommandSurfaceTests` green.

- [ ] **Step 12: Commit**

```bash
git add Tool/Sources/SimToolCLI/SimTool.swift Tool/Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift
git commit -m "$(cat <<'EOF'
refactor(cli): drop native-window flags and runtime

Remove --window (serve) and --native (run), their validators, the
runNativeWindow/SimToolWindowDelegate runtime, and the window plumbing
threaded through runViewer/shouldOpenBrowser. Server-side capture is now
always on. SimToolUI is no longer imported anywhere.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Delete the `SimToolUI` target, product, and sources

With nothing importing `SimToolUI`, remove the target/product wiring from the package manifest and delete the source directory.

**Files:**
- Modify: `Tool/Package.swift`
- Delete: `Tool/Sources/SimToolUI/SimToolSessionView.swift`
- Delete: `Tool/Sources/SimToolUI/NativeSimulatorStreamView.swift`

**Interfaces:**
- Consumes: from Task 1, the fact that `SimToolCLI` no longer imports `SimToolUI`.
- Produces: a package with no `SimToolUI` target or product.

- [ ] **Step 1: Remove the `SimToolUI` library product**

In `Tool/Package.swift`, delete this line from the `products:` array:

```swift
        .library(name: "SimToolUI", targets: ["SimToolUI"]),
```

- [ ] **Step 2: Remove the `SimToolUI` target**

Delete the entire target definition:

```swift
        .target(
            name: "SimToolUI",
            dependencies: [
                "SimToolClient",
                "SimToolCore",
                "SimToolStream",
                .product(name: "SimToolNetworkLogger", package: "SimTool"),
            ]
        ),
```

- [ ] **Step 3: Remove `SimToolUI` from the `SimToolCLI` target dependencies**

In the `SimToolCLI` `.executableTarget` dependency list, delete this line:

```swift
                "SimToolUI",
```

- [ ] **Step 4: Delete the source files**

Run: `git rm Tool/Sources/SimToolUI/SimToolSessionView.swift Tool/Sources/SimToolUI/NativeSimulatorStreamView.swift && rmdir Tool/Sources/SimToolUI`
Expected: both files staged for deletion; the now-empty `SimToolUI` directory removed.

- [ ] **Step 5: Build and run the full test suite**

Run: `swift build --package-path Tool 2>&1 | tail -20`
Expected: build SUCCEEDS — SwiftPM resolves the manifest with no `SimToolUI` target.

Run: `swift test --package-path Tool 2>&1 | tail -25`
Expected: all test targets PASS.

- [ ] **Step 6: Commit**

```bash
git add Tool/Package.swift
git commit -m "$(cat <<'EOF'
refactor(package): remove the SimToolUI target and product

Delete the native-window SwiftUI module and its package wiring now that
nothing depends on it.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Update the README

Remove the native-window mentions from user-facing docs.

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: docs that describe only the web viewer.

- [ ] **Step 1: Update the intro paragraph**

Replace the opening description (drop "a SwiftUI package surface for native consumers"):

```markdown
The MVP focuses on a local browser viewer with JPEG and H.264/AVCC streams and a
machine-readable CLI for agents.
```

- [ ] **Step 2: Update the `run` description and example**

Replace the `--web` / `--native` sentence:

```markdown
viewer server and prints its URL (`Open http://…`, or the `url` field with
`--json`) — handy for scripts that open the page themselves. Pass `--web` to
also open the browser viewer. It runs in the foreground like `serve` (Ctrl-C
stops it).
```

In the `run` example block, delete the `--native` line:

```sh
swift run simtool run --native
```

- [ ] **Step 3: Update the `SimToolClient` / API closing note**

Replace the closing paragraph that described `SimToolUI` so it no longer references the removed module:

```markdown
`SimToolClient` exposes these routes as typed async Swift calls.
```

- [ ] **Step 4: Verify no stray native-window references remain**

Run: `grep -n "SimToolUI\|--native\|--window\|native SwiftUI\|SwiftUI package surface" README.md`
Expected: no matches (exit status 1). The remaining `SwiftUI bindings` mention on the state-logger debounce line is about app-side SwiftUI and is intentionally left.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: drop native-window references from the README

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Notes for the implementer

- `SimToolStream` (native frame capture / H.264 encode) and `SimulatorDirectInputClient` stay — `SimToolServer` consumes both to drive the web viewer. Do not remove them.
- The historical spec files under `docs/superpowers/specs/` and plan files under `docs/superpowers/plans/` that mention `captureEnabled` / `--native` are project history and are intentionally left untouched.
- The `--no-open` flag on `serve` is a separate, pre-existing deprecated no-op and is unrelated to this change — leave it.
