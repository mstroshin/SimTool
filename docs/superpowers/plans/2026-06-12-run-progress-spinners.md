# Run Progress Spinners Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `simtool run`, `simtool app build`, and `simtool app launch` show Noora spinners per stage, with a single in-place status line during xcodebuild ("Compiling HomeView.swift", "Linking MyApp").

**Architecture:** `ProcessRunner` gains an optional per-line stdout callback. A new pure parser (`XcodebuildProgress`) maps xcodebuild step lines to short statuses. `SimulatorAppLifecycleClient` exposes optional `progress` callbacks on `build` and a new `installAndLaunch` (extracted from `launch`, which becomes their composition). The CLI wraps each stage in `Noora().progressStep` and feeds parsed statuses into `updateMessage` through a deduplicating/throttling relay. `--json` paths are untouched.

**Tech Stack:** Swift 5.9 SPM package, XCTest, Noora 0.15+ (`progressStep`), ArgumentParser.

**Spec:** `docs/superpowers/specs/2026-06-12-run-progress-spinners-design.md`

## File Structure

- Modify `Sources/SimToolCore/ProcessRunner.swift` — add `onStdoutLine` parameter + private `LineSplitter`.
- Create `Sources/SimToolCore/XcodebuildProgress.swift` — pure line→status parser.
- Modify `Sources/SimToolCore/SimulatorAppLifecycle.swift` — `progress` callback on `build`, new `installAndLaunch`, `launch` becomes composition.
- Create `Sources/SimToolCLI/ProgressStatusRelay.swift` — dedupe + throttle + prefix for `updateMessage`.
- Modify `Sources/SimToolCLI/SimTool.swift` — progress helpers, rewire `Run`, `AppCommand.Build`, `AppCommand.Launch`.
- Create `Tests/SimToolCoreTests/ProcessRunnerTests.swift`, `Tests/SimToolCoreTests/XcodebuildProgressTests.swift`, `Tests/SimToolCLITests/ProgressStatusRelayTests.swift`.

---

### Task 1: ProcessRunner stdout line streaming

**Files:**
- Modify: `Sources/SimToolCore/ProcessRunner.swift`
- Test: `Tests/SimToolCoreTests/ProcessRunnerTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

Create `Tests/SimToolCoreTests/ProcessRunnerTests.swift`:

```swift
import Foundation
import XCTest
@testable import SimToolCore

final class ProcessRunnerTests: XCTestCase {
    func testRunDeliversStdoutLinesIncludingUnterminatedTail() async throws {
        let collector = LineCollector()
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'one\\ntwo\\nthree'"],
            onStdoutLine: { collector.append($0) }
        )
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdoutString, "one\ntwo\nthree")
        XCTAssertEqual(collector.lines(), ["one", "two", "three"])
    }

    func testRunSkipsEmptyLines() async throws {
        let collector = LineCollector()
        _ = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'a\\n\\nb\\n'"],
            onStdoutLine: { collector.append($0) }
        )
        XCTAssertEqual(collector.lines(), ["a", "b"])
    }

    func testRunWithoutLineCallbackStillBuffersOutput() async throws {
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'plain\\n'"]
        )
        XCTAssertEqual(output.stdoutString, "plain\n")
    }
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProcessRunnerTests`
Expected: compile error — `extra argument 'onStdoutLine' in call`.

- [ ] **Step 3: Implement `onStdoutLine` in `ProcessRunner.run`**

In `Sources/SimToolCore/ProcessRunner.swift`, change the `run` signature (the first overload, line 25) to:

```swift
public static func run(
    executable: URL,
    arguments: [String],
    stdin: Data? = nil,
    environment: [String: String]? = nil,
    timeoutSeconds: TimeInterval? = nil,
    onStdoutLine: (@Sendable (String) -> Void)? = nil
) async throws -> ProcessOutput {
```

After `let stderrBuffer = ProcessOutputBuffer()` add:

```swift
        let lineSplitter = onStdoutLine.map { LineSplitter(onLine: $0) }
```

Replace the stdout readability handler with:

```swift
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutBuffer.append(data)
                lineSplitter?.append(data)
            }
        }
```

In the `terminationHandler`, replace the final stdout drain
(`stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())`) with:

```swift
                let remainingStdout = stdout.fileHandleForReading.readDataToEndOfFile()
                stdoutBuffer.append(remainingStdout)
                lineSplitter?.append(remainingStdout)
                lineSplitter?.flush()
```

At file scope (next to `ProcessOutputBuffer`) add:

```swift
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        partial.append(data)
        var lines: [String] = []
        while let newlineIndex = partial.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = partial[partial.startIndex ..< newlineIndex]
            partial.removeSubrange(partial.startIndex ... newlineIndex)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        lock.unlock()
        for line in lines { onLine(line) }
    }

    func flush() {
        lock.lock()
        let remaining = partial
        partial = Data()
        lock.unlock()
        if !remaining.isEmpty, let line = String(data: remaining, encoding: .utf8), !line.isEmpty {
            onLine(line)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProcessRunnerTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SimToolCore/ProcessRunner.swift Tests/SimToolCoreTests/ProcessRunnerTests.swift
git commit -m "feat(core): stream stdout lines from ProcessRunner via optional callback"
```

---

### Task 2: XcodebuildProgress line parser

**Files:**
- Create: `Sources/SimToolCore/XcodebuildProgress.swift`
- Test: `Tests/SimToolCoreTests/XcodebuildProgressTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

Create `Tests/SimToolCoreTests/XcodebuildProgressTests.swift`:

```swift
import XCTest
@testable import SimToolCore

final class XcodebuildProgressTests: XCTestCase {
    func testCompileLines() {
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "SwiftCompile normal arm64 Compiling\\ ContentView.swift /Users/dev/App/ContentView.swift (in target 'App' from project 'App')"),
            "Compiling ContentView.swift"
        )
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "CompileC /out/foo.o /Users/dev/App/foo.m normal arm64 objective-c com.apple.compilers.llvm.clang.1_0.compiler"),
            "Compiling foo.m"
        )
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "CompileSwiftSources normal arm64 com.apple.xcode.tools.swift.compiler (in target 'App' from project 'App')"),
            "Compiling sources"
        )
    }

    func testLinkSignAndPlistLines() {
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "Ld /Users/dev/DerivedData/App-abc/Build/Products/Debug-iphonesimulator/App.app/App normal (in target 'App' from project 'App')"),
            "Linking App"
        )
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "CodeSign /Users/dev/DerivedData/App-abc/Build/Products/Debug-iphonesimulator/App.app (in target 'App' from project 'App')"),
            "Signing App.app"
        )
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "ProcessInfoPlistFile /out/Info.plist /in/Info.plist (in target 'App' from project 'App')"),
            "Processing Info.plist"
        )
    }

    func testResourceScriptAndPlanningLines() {
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "CompileAssetCatalog /out /Users/dev/App/Assets.xcassets (in target 'App' from project 'App')"),
            "Compiling asset catalogs"
        )
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "CompileStoryboard /Users/dev/App/Main.storyboard (in target 'App' from project 'App')"),
            "Compiling Main.storyboard"
        )
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "PhaseScriptExecution Run\\ SwiftLint /Users/dev/DerivedData/Script-ABC.sh (in target 'App' from project 'App')"),
            "Running script Run SwiftLint"
        )
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "CpResource /out/Settings.bundle /in/Settings.bundle (in target 'App' from project 'App')"),
            "Copying resources"
        )
        XCTAssertEqual(XcodebuildProgress.status(forLine: "Resolve Package Graph"), "Resolving packages")
        XCTAssertEqual(XcodebuildProgress.status(forLine: "Build description signature: 4cd4b2d"), "Planning build")
        XCTAssertEqual(XcodebuildProgress.status(forLine: "Planning build"), "Planning build")
    }

    func testUnknownAndIndentedLinesReturnNil() {
        XCTAssertNil(XcodebuildProgress.status(forLine: "    cd /Users/dev/App"))
        XCTAssertNil(XcodebuildProgress.status(forLine: "\texport SDKROOT=iphonesimulator"))
        XCTAssertNil(XcodebuildProgress.status(forLine: "warning: deprecated API"))
        XCTAssertNil(XcodebuildProgress.status(forLine: "** BUILD SUCCEEDED **"))
        XCTAssertNil(XcodebuildProgress.status(forLine: ""))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter XcodebuildProgressTests`
Expected: compile error — `cannot find 'XcodebuildProgress' in scope`.

- [ ] **Step 3: Implement the parser**

Create `Sources/SimToolCore/XcodebuildProgress.swift`:

```swift
import Foundation

/// Maps raw xcodebuild output lines to short human-readable statuses for
/// progress UIs. Unknown lines map to nil so callers keep the previous status.
public enum XcodebuildProgress {
    public static func status(forLine line: String) -> String? {
        guard let first = line.first, first != " ", first != "\t" else { return nil }
        if line.hasPrefix("Resolve Package Graph") || line.hasPrefix("Resolving ") {
            return "Resolving packages"
        }
        if line.hasPrefix("Build description") || line.hasPrefix("Planning") {
            return "Planning build"
        }
        let tokens = tokenize(line)
        guard let verb = tokens.first else { return nil }
        switch verb {
        case "SwiftCompile", "CompileSwift", "CompileSwiftSources", "CompileC":
            let sourceSuffixes = [".swift", ".m", ".mm", ".c", ".cc", ".cpp"]
            if let file = tokens.dropFirst().last(where: { token in
                sourceSuffixes.contains(where: token.hasSuffix)
            }) {
                return "Compiling \(lastPathComponent(file))"
            }
            return "Compiling sources"
        case "Ld":
            guard tokens.count > 1 else { return "Linking" }
            return "Linking \(lastPathComponent(tokens[1]))"
        case "CodeSign":
            guard tokens.count > 1 else { return "Signing" }
            return "Signing \(lastPathComponent(tokens[1]))"
        case "CompileAssetCatalog", "CompileAssetCatalogVariant":
            return "Compiling asset catalogs"
        case "CompileStoryboard", "CompileXIB":
            guard tokens.count > 1 else { return "Compiling interface files" }
            return "Compiling \(lastPathComponent(tokens[1]))"
        case "PhaseScriptExecution":
            guard tokens.count > 1 else { return "Running build script" }
            return "Running script \(tokens[1])"
        case "ProcessInfoPlistFile":
            return "Processing Info.plist"
        case "CopySwiftLibs", "CpResource", "PBXCp", "Copy", "CopyStringsFile", "CpHeader":
            return "Copying resources"
        default:
            return nil
        }
    }

    /// Splits a line on spaces while honoring xcodebuild's backslash-escaped
    /// spaces (e.g. `PhaseScriptExecution Run\ SwiftLint /path.sh`).
    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if character == "\\", next < line.endIndex, line[next] == " " {
                current.append(" ")
                index = line.index(index, offsetBy: 2)
            } else if character == " " {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                index = next
            } else {
                current.append(character)
                index = next
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter XcodebuildProgressTests`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SimToolCore/XcodebuildProgress.swift Tests/SimToolCoreTests/XcodebuildProgressTests.swift
git commit -m "feat(core): map xcodebuild output lines to short progress statuses"
```

---

### Task 3: Progress callbacks in SimulatorAppLifecycleClient

`launch` currently does build → conditional install → launch with a missing-install retry (lines 506–582 of `SimulatorAppLifecycle.swift`). Extract everything after the build into a public `installAndLaunch`, add optional progress callbacks. No retry/cache logic is duplicated; behavior is identical when callbacks are nil. This is a refactor guarded by the existing test suite — no new unit tests (the moved code paths require simctl).

**Files:**
- Modify: `Sources/SimToolCore/SimulatorAppLifecycle.swift:442-582`

- [ ] **Step 1: Add `progress` to `build`**

Change the `build` signature to:

```swift
    public static func build(
        selection: SimulatorAppBuildSelection,
        force: Bool = false,
        cache: SimulatorAppBuildCache = .shared,
        timeoutSeconds: TimeInterval? = 1_800,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SimulatorAppBuildPayload {
```

Replace the `ProcessRunner.run` call for xcodebuild with:

```swift
        let onStdoutLine: (@Sendable (String) -> Void)? = progress.map { progress in
            { line in
                if let status = XcodebuildProgress.status(forLine: line) {
                    progress(status)
                }
            }
        }
        let buildOutput = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: buildArguments,
            timeoutSeconds: timeoutSeconds,
            onStdoutLine: onStdoutLine
        )
```

- [ ] **Step 2: Extract `installAndLaunch`**

Replace the body of `launch` after the `build(...)` call with a call to the new
function. The new function uses `buildPayload.identity` where the old code used
`selection.identity` (they are the same value — `build` copies it into the
payload). Final code for both functions:

```swift
    public static func launch(
        selection: SimulatorAppBuildSelection,
        device: SimulatorDevice,
        launchEnvironment: [String: String] = [:],
        launchArguments: [String] = [],
        force: Bool = false,
        cache: SimulatorAppBuildCache = .shared,
        timeoutSeconds: TimeInterval? = 1_800,
        buildProgress: (@Sendable (String) -> Void)? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SimulatorAppLaunchPayload {
        let buildPayload = try await build(
            selection: selection,
            force: force,
            cache: cache,
            timeoutSeconds: timeoutSeconds,
            progress: buildProgress
        )
        return try await installAndLaunch(
            build: buildPayload,
            device: device,
            launchEnvironment: launchEnvironment,
            launchArguments: launchArguments,
            force: force,
            cache: cache,
            timeoutSeconds: timeoutSeconds,
            progress: progress
        )
    }

    public static func installAndLaunch(
        build buildPayload: SimulatorAppBuildPayload,
        device: SimulatorDevice,
        launchEnvironment: [String: String] = [:],
        launchArguments: [String] = [],
        force: Bool = false,
        cache: SimulatorAppBuildCache = .shared,
        timeoutSeconds: TimeInterval? = 1_800,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SimulatorAppLaunchPayload {
        let metadata = cache.readMetadata(for: buildPayload.identity)
        let installRecord = metadata?.installRecords[device.udid]
        var installStep = SimulatorAppProcessStepSummary(name: "simctl install", ran: false)
        var installRan = false

        let needsInstall = force || buildPayload.xcodebuildRan || installRecord?.checksum != buildPayload.checksum || installRecord?.bundleIdentifier != buildPayload.bundleIdentifier
        if needsInstall {
            progress?("Installing…")
            installStep = try await installApp(
                deviceUDID: device.udid,
                appBundlePath: buildPayload.appBundlePath,
                timeoutSeconds: timeoutSeconds
            )
            installRan = true
            try cache.recordInstall(
                identity: buildPayload.identity,
                checksum: buildPayload.checksum,
                bundleIdentifier: buildPayload.bundleIdentifier,
                deviceUDID: device.udid
            )
        }

        progress?("Launching…")
        var launchStep = try await launchApp(
            deviceUDID: device.udid,
            bundleIdentifier: buildPayload.bundleIdentifier,
            launchEnvironment: launchEnvironment,
            launchArguments: launchArguments,
            timeoutSeconds: timeoutSeconds
        )
        if launchStep.status != 0, !installRan, isMissingInstallLaunchFailure(launchStep) {
            progress?("Reinstalling…")
            installStep = try await installApp(
                deviceUDID: device.udid,
                appBundlePath: buildPayload.appBundlePath,
                timeoutSeconds: timeoutSeconds
            )
            installRan = true
            try cache.recordInstall(
                identity: buildPayload.identity,
                checksum: buildPayload.checksum,
                bundleIdentifier: buildPayload.bundleIdentifier,
                deviceUDID: device.udid
            )
            progress?("Launching…")
            launchStep = try await launchApp(
                deviceUDID: device.udid,
                bundleIdentifier: buildPayload.bundleIdentifier,
                launchEnvironment: launchEnvironment,
                launchArguments: launchArguments,
                timeoutSeconds: timeoutSeconds
            )
        }
        guard launchStep.status == 0 else {
            let detail = launchStep.stderr.isEmpty ? launchStep.stdout : launchStep.stderr
            throw SimToolError("simctl launch failed for \(buildPayload.bundleIdentifier): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        return SimulatorAppLaunchPayload(
            build: buildPayload,
            device: device,
            launchEnvironment: launchEnvironment,
            launchArguments: launchArguments,
            installed: true,
            launched: true,
            installRan: installRan,
            launchRan: true,
            install: installStep,
            launch: launchStep
        )
    }
```

Keep the original `installApp`/`launchApp`/`isMissingInstallLaunchFailure`
private helpers unchanged.

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: all tests PASS (new parameters are optional; behavior unchanged).

- [ ] **Step 4: Commit**

```bash
git add Sources/SimToolCore/SimulatorAppLifecycle.swift
git commit -m "feat(core): add progress callbacks to app build and install/launch lifecycle"
```

---

### Task 4: ProgressStatusRelay (dedupe + throttle)

**Files:**
- Create: `Sources/SimToolCLI/ProgressStatusRelay.swift`
- Test: `Tests/SimToolCLITests/ProgressStatusRelayTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

Create `Tests/SimToolCLITests/ProgressStatusRelayTests.swift`:

```swift
import Foundation
import XCTest
@testable import SimToolCLI

final class ProgressStatusRelayTests: XCTestCase {
    func testPrefixesAndDeduplicatesStatuses() {
        let collector = UpdateCollector()
        let relay = ProgressStatusRelay(prefix: "Building App", minimumInterval: 0) { collector.append($0) }
        relay.send("Compiling A.swift")
        relay.send("Compiling A.swift")
        relay.send("Compiling B.swift")
        XCTAssertEqual(collector.updates(), [
            "Building App · Compiling A.swift",
            "Building App · Compiling B.swift",
        ])
    }

    func testThrottlesRapidDistinctUpdates() {
        let collector = UpdateCollector()
        let relay = ProgressStatusRelay(prefix: "Building", minimumInterval: 60) { collector.append($0) }
        relay.send("one")
        relay.send("two")
        relay.send("three")
        XCTAssertEqual(collector.updates(), ["Building · one"])
    }
}

private final class UpdateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ update: String) {
        lock.lock()
        storage.append(update)
        lock.unlock()
    }

    func updates() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProgressStatusRelayTests`
Expected: compile error — `cannot find 'ProgressStatusRelay' in scope`.

- [ ] **Step 3: Implement the relay**

Create `Sources/SimToolCLI/ProgressStatusRelay.swift`:

```swift
import Foundation

/// Forwards live progress statuses into a Noora progressStep `updateMessage`
/// callback, prefixed with the stage message. Drops duplicate statuses and
/// rate-limits distinct ones so fast xcodebuild output does not thrash the
/// terminal renderer.
final class ProgressStatusRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStatus: String?
    private var lastUpdate = Date.distantPast
    private let prefix: String
    private let minimumInterval: TimeInterval
    private let update: @Sendable (String) -> Void

    init(prefix: String, minimumInterval: TimeInterval = 0.1, update: @escaping @Sendable (String) -> Void) {
        self.prefix = prefix
        self.minimumInterval = minimumInterval
        self.update = update
    }

    func send(_ status: String) {
        lock.lock()
        let now = Date()
        guard status != lastStatus, now.timeIntervalSince(lastUpdate) >= minimumInterval else {
            lock.unlock()
            return
        }
        lastStatus = status
        lastUpdate = now
        lock.unlock()
        update("\(prefix) · \(status)")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProgressStatusRelayTests`
Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SimToolCLI/ProgressStatusRelay.swift Tests/SimToolCLITests/ProgressStatusRelayTests.swift
git commit -m "feat(cli): add deduplicating throttled progress status relay"
```

---

### Task 5: Wire spinners into `run`, `app build`, `app launch`

**Files:**
- Modify: `Sources/SimToolCLI/SimTool.swift` (helpers near `AppBuildOptions` ~line 523; `AppCommand.Build.run` ~line 587; `AppCommand.Launch.run` ~line 627; `Run.run` ~line 936)

No new unit tests: these helpers are thin Noora wrappers around already-tested
core calls; spinner rendering is verified manually (spec, Testing section).
Existing CLI surface tests guard against regressions.

- [ ] **Step 1: Add stage helpers**

In `Sources/SimToolCLI/SimTool.swift`, add at file scope (above `extension AppCommand`):

```swift
func resolveSimulatorWithProgress(_ value: String?) async throws -> SimulatorDevice {
    try await Noora().progressStep(
        message: "Resolving simulator",
        successMessage: "Resolved simulator",
        errorMessage: "Failed to resolve simulator",
        showSpinner: true
    ) { _ in
        try await SimulatorDeviceClient.resolve(value)
    }
}

func bootSimulatorWithProgress(_ device: SimulatorDevice) async throws -> SimulatorDevice {
    try await Noora().progressStep(
        message: "Booting \(device.name)",
        successMessage: "Booted \(device.name)",
        errorMessage: "Failed to boot \(device.name)",
        showSpinner: true
    ) { _ in
        try await SimulatorDeviceClient.ensureBooted(device)
    }
}

func buildAppWithProgress(selection: SimulatorAppBuildSelection, force: Bool) async throws -> SimulatorAppBuildPayload {
    let stage = "Building \(selection.identity.scheme) (\(selection.identity.configuration))"
    let live = isatty(STDOUT_FILENO) == 1
    return try await Noora().progressStep(
        message: stage,
        successMessage: "Built \(selection.identity.scheme) (\(selection.identity.configuration))",
        errorMessage: "Build failed for \(selection.identity.scheme)",
        showSpinner: true
    ) { updateMessage in
        let relay = live ? ProgressStatusRelay(prefix: stage, update: updateMessage) : nil
        return try await SimulatorAppLifecycleClient.build(
            selection: selection,
            force: force,
            progress: relay.map { relay in { @Sendable status in relay.send(status) } }
        )
    }
}

func installAndLaunchAppWithProgress(
    build buildPayload: SimulatorAppBuildPayload,
    device: SimulatorDevice,
    launchEnvironment: [String: String] = [:],
    launchArguments: [String] = [],
    force: Bool
) async throws -> SimulatorAppLaunchPayload {
    let stage = "Launching \(buildPayload.identity.scheme)"
    let live = isatty(STDOUT_FILENO) == 1
    return try await Noora().progressStep(
        message: stage,
        successMessage: "Launched \(buildPayload.bundleIdentifier)",
        errorMessage: "Launch failed for \(buildPayload.bundleIdentifier)",
        showSpinner: true
    ) { updateMessage in
        let relay = live ? ProgressStatusRelay(prefix: stage, update: updateMessage) : nil
        return try await SimulatorAppLifecycleClient.installAndLaunch(
            build: buildPayload,
            device: device,
            launchEnvironment: launchEnvironment,
            launchArguments: launchArguments,
            force: force,
            progress: relay.map { relay in { @Sendable status in relay.send(status) } }
        )
    }
}
```

(`isatty`/`STDOUT_FILENO` come through Foundation's Darwin re-export — no new import needed.)

- [ ] **Step 2: Rewire `Run.run()`**

Replace the resolve/boot/launch/alert block (currently):

```swift
        let resolved = try await SimulatorDeviceClient.resolve(projectConfig.simulator)
        let booted = try await SimulatorDeviceClient.ensureBooted(resolved)
        let launch = try await SimulatorAppLifecycleClient.launch(
            selection: try projectConfig.buildSelection(),
            device: booted,
            force: force
        )
        if !common.json {
            let buildAction = launch.build.cacheHit ? "reused (checksum cache)" : "built"
            Noora().success(.alert("Launched \(launch.build.bundleIdentifier)", takeaways: [
                "Device: \(booted.name)",
                "Build: \(buildAction)",
                "Network logger: \(networkLoggerEnabled ? "on → \(projectConfig.appFacingServerURL)" : "off")",
                "State logger: \(stateLoggerEnabled ? "on → \(projectConfig.appFacingServerURL)" : "off")",
            ]))
        }
```

with:

```swift
        let booted: SimulatorDevice
        let launch: SimulatorAppLaunchPayload
        if common.json {
            let resolved = try await SimulatorDeviceClient.resolve(projectConfig.simulator)
            booted = try await SimulatorDeviceClient.ensureBooted(resolved)
            launch = try await SimulatorAppLifecycleClient.launch(
                selection: try projectConfig.buildSelection(),
                device: booted,
                force: force
            )
        } else {
            let resolved = try await resolveSimulatorWithProgress(projectConfig.simulator)
            booted = try await bootSimulatorWithProgress(resolved)
            let buildPayload = try await buildAppWithProgress(
                selection: try projectConfig.buildSelection(),
                force: force
            )
            launch = try await installAndLaunchAppWithProgress(
                build: buildPayload,
                device: booted,
                force: force
            )
            let buildAction = launch.build.cacheHit ? "reused (checksum cache)" : "built"
            Noora().success(.alert("Launched \(launch.build.bundleIdentifier)", takeaways: [
                "Device: \(booted.name)",
                "Build: \(buildAction)",
                "Network logger: \(networkLoggerEnabled ? "on → \(projectConfig.appFacingServerURL)" : "off")",
                "State logger: \(stateLoggerEnabled ? "on → \(projectConfig.appFacingServerURL)" : "off")",
            ]))
        }
```

The trailing `runViewer(...)` call stays unchanged.

- [ ] **Step 3: Rewire `AppCommand.Build.run()`**

Replace the body with:

```swift
        func run() async throws {
            let selection = try buildOptions.selection()
            if common.json {
                let payload = try await SimulatorAppLifecycleClient.build(
                    selection: selection,
                    force: buildOptions.force
                )
                try printJSON(payload)
                return
            }
            let payload = try await buildAppWithProgress(selection: selection, force: buildOptions.force)
            if payload.cacheHit {
                Noora().success(.alert("Reused cached build", takeaways: [
                    "Scheme: \(payload.identity.scheme)",
                    "Bundle: \(payload.bundleIdentifier)",
                    "App: \(payload.appBundlePath)",
                    "Checksum: \(payload.checksum)",
                ]))
            } else {
                Noora().success(.alert("Built app", takeaways: [
                    "Scheme: \(payload.identity.scheme)",
                    "Bundle: \(payload.bundleIdentifier)",
                    "App: \(payload.appBundlePath)",
                    "Checksum: \(payload.checksum)",
                ]))
            }
        }
```

- [ ] **Step 4: Rewire `AppCommand.Launch.run()`**

Replace the body with (note: `app launch` never booted the device before — keep
that behavior, only the resolve step gets a spinner):

```swift
        func run() async throws {
            let launchEnvironment = try SimulatorAppLifecycleClient.parseLaunchEnvironment(environment)
            let selection = try buildOptions.selection()
            let payload: SimulatorAppLaunchPayload
            if common.json {
                let resolved = try await SimulatorDeviceClient.resolve(device)
                payload = try await SimulatorAppLifecycleClient.launch(
                    selection: selection,
                    device: resolved,
                    launchEnvironment: launchEnvironment,
                    launchArguments: launchArguments,
                    force: buildOptions.force
                )
                try printJSON(payload)
                return
            }
            let resolved = try await resolveSimulatorWithProgress(device)
            let buildPayload = try await buildAppWithProgress(selection: selection, force: buildOptions.force)
            payload = try await installAndLaunchAppWithProgress(
                build: buildPayload,
                device: resolved,
                launchEnvironment: launchEnvironment,
                launchArguments: launchArguments,
                force: buildOptions.force
            )
            let buildAction = payload.build.xcodebuildRan ? "built" : "reused"
            let installAction = payload.installRan ? "installed" : "already installed"
            var takeaways: [TerminalText] = [
                "Device: \(payload.device.name)",
                "Bundle: \(payload.build.bundleIdentifier)",
                "Build: \(buildAction)",
                "Install: \(installAction)",
            ]
            if !payload.launchArguments.isEmpty {
                takeaways.append("Launch args: \(payload.launchArguments.joined(separator: " "))")
            }
            Noora().success(.alert("Launched app", takeaways: takeaways))
        }
```

- [ ] **Step 5: Build and run the full test suite**

Run: `swift build && swift test`
Expected: build succeeds, all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SimToolCLI/SimTool.swift
git commit -m "feat(cli): show per-stage progress spinners in run and app build/launch"
```

- [ ] **Step 7: Manual verification (interactive terminal)**

In a project with `.simtool.yml`, run `simtool run` from a real terminal and check:
- spinner lines for Resolving/Booting/Building/Launching;
- the Building line updates in place with "Compiling <file>" statuses, no scrollback spam;
- second run (cache hit) completes the build step in under a second;
- `simtool run --json` output is unchanged (no spinner artifacts).
