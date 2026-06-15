# `.simtool/` Project Directory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** All per-project SimTool state lives in `<project>/.simtool/`: `config.yml` (was `.simtool.yml`), `build/<identityKey>.json` checksum metadata (was `~/Library/Caches/SimTool/app-builds/metadata`), and `test-sessions/` (was `~/.simtool/test-sessions`), with an auto-created self-ignoring `.gitignore`.

**Architecture:** A new `SimToolDirectory` enum in SimToolCore owns the anchor rule (walk up from cwd for an existing `.simtool/`, else `cwd/.simtool`, lazy creation with `.gitignore`). `ProjectConfigLoader`, `SimulatorAppBuildCache`, and `TestSessionStore` all derive paths from it. Clean break: no legacy `.simtool.yml` detection, no migration. DerivedData stays in `~/Library/Caches/SimTool`.

**Tech Stack:** Swift Package Manager, XCTest. Run tests with `swift test --filter <TestClass>`; full suite with `swift test`.

**Spec:** `docs/superpowers/specs/2026-06-12-dot-simtool-directory-design.md`

---

### Task 1: `SimToolDirectory` helper

**Files:**
- Create: `Sources/SimToolCore/SimToolDirectory.swift`
- Test: `Tests/SimToolCoreTests/SimToolDirectoryTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SimToolCoreTests/SimToolDirectoryTests.swift`:

```swift
import Foundation
import XCTest
@testable import SimToolCore

final class SimToolDirectoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-dir-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLocateFindsExistingDirectoryUpTheTree() throws {
        let simtool = root.appendingPathComponent(".simtool", isDirectory: true)
        try FileManager.default.createDirectory(at: simtool, withIntermediateDirectories: true)
        let nested = root.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertEqual(SimToolDirectory.locate(startDirectory: nested)?.path, simtool.standardizedFileURL.path)
    }

    func testLocateReturnsNilWhenAbsent() throws {
        XCTAssertNil(SimToolDirectory.locate(startDirectory: root))
    }

    func testLocateIgnoresAFileNamedDotSimtool() throws {
        // A stray *file* named .simtool must not be mistaken for the directory.
        try Data().write(to: root.appendingPathComponent(".simtool"))
        XCTAssertNil(SimToolDirectory.locate(startDirectory: root))
    }

    func testResolveFallsBackToStartDirectory() throws {
        let resolved = SimToolDirectory.resolve(startDirectory: root)
        XCTAssertEqual(resolved.path, root.standardizedFileURL.appendingPathComponent(".simtool").path)
        // Fallback must not create anything on disk.
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.path))
    }

    func testEnsureCreatesDirectoryAndGitignore() throws {
        let simtool = root.appendingPathComponent(".simtool", isDirectory: true)
        try SimToolDirectory.ensure(simtool)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: simtool.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let gitignore = simtool.appendingPathComponent(".gitignore")
        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), "*\n")
    }

    func testEnsureKeepsExistingGitignore() throws {
        let simtool = root.appendingPathComponent(".simtool", isDirectory: true)
        try FileManager.default.createDirectory(at: simtool, withIntermediateDirectories: true)
        let gitignore = simtool.appendingPathComponent(".gitignore")
        try Data("custom\n".utf8).write(to: gitignore)

        try SimToolDirectory.ensure(simtool)
        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), "custom\n")
    }

    func testEnsureEnclosingCreatesNearestSimtoolAncestor() throws {
        let nested = root.appendingPathComponent(".simtool/build", isDirectory: true)
        try SimToolDirectory.ensureEnclosing(nested)

        let gitignore = root.appendingPathComponent(".simtool/.gitignore")
        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), "*\n")
    }

    func testEnsureEnclosingIsNoOpOutsideSimtool() throws {
        let plain = root.appendingPathComponent("artifacts", isDirectory: true)
        try SimToolDirectory.ensureEnclosing(plain)
        // Nothing is created: no .gitignore anywhere, no directory.
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitignore").path))
    }

    func testWellKnownSubdirectories() {
        let simtool = URL(fileURLWithPath: "/proj/.simtool", isDirectory: true)
        XCTAssertEqual(SimToolDirectory.buildMetadataDirectory(in: simtool).path, "/proj/.simtool/build")
        XCTAssertEqual(SimToolDirectory.testSessionsDirectory(in: simtool).path, "/proj/.simtool/test-sessions")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SimToolDirectoryTests`
Expected: compilation FAILURE — `cannot find 'SimToolDirectory' in scope`.

- [ ] **Step 3: Implement `SimToolDirectory`**

Create `Sources/SimToolCore/SimToolDirectory.swift`:

```swift
import Foundation

/// The per-project `.simtool/` directory: the project config, build checksum
/// metadata, and test sessions all live here. Discovered by walking up from
/// the invocation directory; created lazily on first write, together with a
/// self-ignoring `.gitignore` so the whole folder stays out of git.
public enum SimToolDirectory {
    public static let directoryName = ".simtool"
    public static let configFileName = "config.yml"

    /// First existing `.simtool` directory walking up from `startDirectory`.
    ///
    /// Walks using filesystem path strings rather than `URL` path
    /// manipulation: `NSString.deletingLastPathComponent` converges
    /// deterministically at the root ("/" -> "/"), whereas
    /// `URL.deletingLastPathComponent()` does not reach a `.path` fixed point
    /// on newer Foundation `URL` backends, which would loop forever.
    public static func locate(
        startDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL? {
        var directory = startDirectory.standardizedFileURL.path
        while true {
            let candidate = (directory as NSString).appendingPathComponent(directoryName)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: candidate, isDirectory: true).standardizedFileURL
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { return nil }
            directory = parent
        }
    }

    /// The located `.simtool` directory, or `<startDirectory>/.simtool` when
    /// none exists anywhere up the tree. Does not touch the filesystem; the
    /// fallback is created later, on first write, via `ensure`.
    public static func resolve(
        startDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL {
        locate(startDirectory: startDirectory)
            ?? startDirectory.standardizedFileURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Creates the directory (with intermediates) and a `.gitignore`
    /// containing `*` so git ignores the whole folder. An existing
    /// `.gitignore` is never overwritten — user edits win.
    public static func ensure(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gitignore = directory.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: gitignore.path) {
            try Data("*\n".utf8).write(to: gitignore, options: [.atomic])
        }
    }

    /// Ensures the nearest `.simtool` ancestor of `path` (including `path`
    /// itself). No-op when `path` is not inside a `.simtool` directory, so
    /// stores rooted at arbitrary paths (test fixtures) stay untouched.
    public static func ensureEnclosing(_ path: URL) throws {
        var directory = path.standardizedFileURL.path
        while true {
            if (directory as NSString).lastPathComponent == directoryName {
                try ensure(URL(fileURLWithPath: directory, isDirectory: true))
                return
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { return }
            directory = parent
        }
    }

    /// `<.simtool>/build` — per-project build checksum metadata.
    public static func buildMetadataDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("build", isDirectory: true)
    }

    /// `<.simtool>/test-sessions` — recorded agent test sessions.
    public static func testSessionsDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("test-sessions", isDirectory: true)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SimToolDirectoryTests`
Expected: all 9 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SimToolCore/SimToolDirectory.swift Tests/SimToolCoreTests/SimToolDirectoryTests.swift
git commit -m "feat(core): add SimToolDirectory helper for the per-project .simtool dir"
```

---

### Task 2: Config moves to `.simtool/config.yml`

**Files:**
- Modify: `Sources/SimToolCore/ProjectConfig.swift`
- Test: `Tests/SimToolCoreTests/ProjectConfigLoaderTests.swift`
- Modify: `Tests/SimToolCoreTests/InteractiveDeeplinksTests.swift:11`

- [ ] **Step 1: Update the loader tests to the new layout**

In `Tests/SimToolCoreTests/ProjectConfigLoaderTests.swift`:

Replace the `writeConfig` helper (lines 224–234) with:

```swift
    private func writeConfig(_ yaml: String, in directory: URL) throws {
        let simtoolDir = directory.appendingPathComponent(SimToolDirectory.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: simtoolDir, withIntermediateDirectories: true)
        try Data(yaml.utf8).write(to: simtoolDir.appendingPathComponent(SimToolDirectory.configFileName))
        // Selection validation requires the referenced source to exist; the
        // fixtures all use these two names.
        for fixture in ["App.xcworkspace", "App.xcodeproj"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(fixture, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }
```

In `testLoadsConfigFromWorkingDirectory`, replace the relative-workspace comment (line 15) with `// Relative workspace resolves against the project root (parent of .simtool).` and replace the `sourcePath` assertion (line 27) with:

```swift
        XCTAssertEqual(
            config.sourcePath,
            root.appendingPathComponent(".simtool/config.yml").standardizedFileURL.path
        )
        XCTAssertEqual(config.simtoolDirectory.path, root.appendingPathComponent(".simtool").standardizedFileURL.path)
```

In `testNoConfigFoundThrows`, replace the error-content assertion (line 67) with:

```swift
            XCTAssertTrue("\(error)".contains(".simtool/config.yml"))
```

Add a new test after `testExplicitPathOverridesDiscovery`:

```swift
    func testExplicitPathAnchorsSimtoolDirectoryAtItsParent() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configDir = root.appendingPathComponent("cfg", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data(minimalYAML.utf8).write(to: configDir.appendingPathComponent("custom.yml"))
        // Relative paths resolve against the parent of the config's directory.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("App.xcworkspace", isDirectory: true),
            withIntermediateDirectories: true
        )

        let config = try ProjectConfigLoader.load(
            explicitPath: configDir.appendingPathComponent("custom.yml").path,
            startDirectory: root
        )
        XCTAssertEqual(config.simtoolDirectory.path, configDir.standardizedFileURL.path)
        XCTAssertEqual(
            config.build.workspace,
            root.appendingPathComponent("App.xcworkspace").standardizedFileURL.path
        )
    }
```

Note: the existing `testExplicitPathOverridesDiscovery` writes `custom.yml` and `App.xcworkspace` side by side in `root`; with project-root resolution the workspace is now expected at `root`'s **parent**. Fix that test by placing the config one level down instead — replace its body with:

```swift
    func testExplicitPathOverridesDiscovery() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configDir = root.appendingPathComponent("cfg", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let custom = configDir.appendingPathComponent("custom.yml")
        try Data(minimalYAML.utf8).write(to: custom)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("App.xcworkspace", isDirectory: true),
            withIntermediateDirectories: true
        )
        let elsewhere = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        let config = try ProjectConfigLoader.load(explicitPath: custom.path, startDirectory: elsewhere)
        XCTAssertEqual(config.simulator, "iPhone 16 Pro")
    }
```

(With both tests covering the same fixture shape, the new `testExplicitPathAnchorsSimtoolDirectoryAtItsParent` adds the anchor assertions; keep both.)

In `Tests/SimToolCoreTests/InteractiveDeeplinksTests.swift` line 11, change `sourcePath: "/tmp/.simtool.yml"` to `sourcePath: "/tmp/.simtool/config.yml"`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectConfigLoaderTests`
Expected: compilation FAILURE (`ProjectConfigLoader.fileName` still exists but `simtoolDirectory` does not) or test FAILURES on the new layout.

- [ ] **Step 3: Update `ProjectConfig.swift`**

In `Sources/SimToolCore/ProjectConfig.swift`:

1. Update the type doc comment (lines 4–6) to start with: `/// A local, gitignored per-project config (`.simtool/config.yml`) describing a single`.

2. Add a computed property to `ProjectConfig` (after `appFacingServerURL`, around line 123):

```swift
    /// The directory the config was loaded from — the project's `.simtool`
    /// directory. Everything else project-scoped (build checksum metadata,
    /// test sessions) anchors here. For an explicit `--config <path>`, the
    /// file's parent directory plays this role.
    public var simtoolDirectory: URL {
        URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
    }
```

3. In `ProjectConfigLoader`, replace `public static let fileName = ".simtool.yml"` with:

```swift
    /// Project-relative location of the config file, for error messages.
    public static let displayPath = "\(SimToolDirectory.directoryName)/\(SimToolDirectory.configFileName)"
```

4. In `locate(explicitPath:startDirectory:)`, replace the walk-up body (the `var directory…` loop and the final `throw`, lines 181–191) with:

```swift
        var directory = startDirectory.standardizedFileURL.path
        while true {
            let candidate = ((directory as NSString)
                .appendingPathComponent(SimToolDirectory.directoryName) as NSString)
                .appendingPathComponent(SimToolDirectory.configFileName)
            if FileManager.default.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate).standardizedFileURL
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { break }
            directory = parent
        }
        throw SimToolError("No \(displayPath) found in the current directory or any parent. Create one or pass --config <path>.")
```

5. In `make(from:sourceURL:)`, replace `let configDirectory = sourceURL.deletingLastPathComponent()` (line 209) with:

```swift
        // The config lives at `<project>/.simtool/config.yml`; relative paths
        // resolve against the project root, not the .simtool directory.
        let projectRoot = sourceURL.deletingLastPathComponent().deletingLastPathComponent()
```

and change the three `resolvePath(..., relativeTo: configDirectory)` calls to `relativeTo: projectRoot`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProjectConfigLoaderTests && swift test --filter InteractiveDeeplinksTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SimToolCore/ProjectConfig.swift Tests/SimToolCoreTests/ProjectConfigLoaderTests.swift Tests/SimToolCoreTests/InteractiveDeeplinksTests.swift
git commit -m "feat(core): load project config from .simtool/config.yml"
```

---

### Task 3: Build checksum metadata moves to `.simtool/build/`

**Files:**
- Modify: `Sources/SimToolCore/SimulatorAppLifecycle.swift` (cache struct ~278–346, lifecycle signatures ~456, ~532, ~567)
- Test: `Tests/SimToolCoreTests/SimulatorAppLifecycleTests.swift` (~line 74)

- [ ] **Step 1: Update the cache test**

In `Tests/SimToolCoreTests/SimulatorAppLifecycleTests.swift`, in `testCacheMetadataReadWriteValidationCorruptMissesAndInstallRecords`, replace the cache construction (line 74) with:

```swift
        let simtoolDir = root.appendingPathComponent(".simtool", isDirectory: true)
        let cache = SimulatorAppBuildCache(
            simtoolDirectory: simtoolDir,
            derivedDataRoot: root.appendingPathComponent("derived", isDirectory: true)
        )
```

and immediately after the first `try cache.write(metadata)` (line 88), add:

```swift
        // Metadata lands in `.simtool/build/<identityKey>.json`, and writing
        // creates the self-ignoring .gitignore.
        XCTAssertTrue(
            try cache.metadataURL(for: selection.identity).path
                .hasPrefix(simtoolDir.appendingPathComponent("build").path)
        )
        XCTAssertEqual(
            try String(contentsOf: simtoolDir.appendingPathComponent(".gitignore"), encoding: .utf8),
            "*\n"
        )
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SimulatorAppLifecycleTests`
Expected: compilation FAILURE — `SimulatorAppBuildCache` has no `init(simtoolDirectory:derivedDataRoot:)`.

- [ ] **Step 3: Rework `SimulatorAppBuildCache`**

In `Sources/SimToolCore/SimulatorAppLifecycle.swift`, replace the `SimulatorAppBuildCache` struct (lines 278–346) properties/init/path helpers as follows (keep `identityKey`, `readMetadata`, `validMetadata`, `recordInstall` bodies as they are):

```swift
public struct SimulatorAppBuildCache {
    /// Per-project checksum metadata: `<.simtool>/build/<identityKey>.json`.
    public var metadataRoot: URL
    /// Rebuildable xcodebuild products; kept out of the project tree because
    /// they can weigh gigabytes.
    public var derivedDataRoot: URL

    public init(simtoolDirectory: URL, derivedDataRoot: URL = Self.defaultDerivedDataRoot()) {
        self.metadataRoot = SimToolDirectory.buildMetadataDirectory(in: simtoolDirectory)
        self.derivedDataRoot = derivedDataRoot
    }

    public static func defaultDerivedDataRoot() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SimTool/app-builds/DerivedData", isDirectory: true)
    }
```

Delete `public static let shared = SimulatorAppBuildCache()`, the old `root` property, and the old `defaultRoot()`.

Update the path helpers:

```swift
    public func derivedDataPath(for identity: SimulatorAppBuildIdentity) throws -> String {
        try derivedDataRoot
            .appendingPathComponent(identityKey(for: identity), isDirectory: true)
            .path
    }

    public func metadataURL(for identity: SimulatorAppBuildIdentity) throws -> URL {
        try metadataRoot
            .appendingPathComponent(identityKey(for: identity))
            .appendingPathExtension("json")
    }
```

Update `write(_:)` to ensure the enclosing `.simtool` directory (and its `.gitignore`) exists:

```swift
    public func write(_ metadata: SimulatorAppBuildCacheMetadata) throws {
        let url = try metadataURL(for: metadata.identity)
        try SimToolDirectory.ensureEnclosing(metadataRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSON.data(metadata).write(to: url, options: [.atomic])
    }
```

- [ ] **Step 4: Update the lifecycle client default cache and fingerprint root**

Still in `SimulatorAppLifecycle.swift`:

1. In `SimulatorAppLifecycleClient.build` (line ~456), `launch` (~532), and `installAndLaunch` (~567), change the parameter

   `cache: SimulatorAppBuildCache = .shared`

   to

   `cache: SimulatorAppBuildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve())`

   (Default arguments evaluate at the call site, so flag-driven `simtool app …` invocations anchor on the directory they are run from — found `.simtool` up the tree, else `cwd/.simtool` — exactly the spec's rule. Check for any other `= .shared` occurrences with `grep -n "\.shared" Sources/SimToolCore/SimulatorAppLifecycle.swift` and convert them the same way.)

2. In `build`, change the fingerprint call (line ~460) from `cacheRoot: cache.root` to `cacheRoot: cache.derivedDataRoot`. (`cacheRoot` only excludes cache-owned files from input enumeration; the derived-data tree is the part that can overlap a build's inputs.)

- [ ] **Step 5: Run tests and build**

Run: `swift test --filter SimulatorAppLifecycleTests && swift build`
Expected: tests PASS; `swift build` FAILS in `SimToolCLI` only if any CLI call site still references `.shared` — there should be none (CLI helpers rely on the default argument). If the whole build passes, continue.

- [ ] **Step 6: Commit**

```bash
git add Sources/SimToolCore/SimulatorAppLifecycle.swift Tests/SimToolCoreTests/SimulatorAppLifecycleTests.swift
git commit -m "feat(core): store build checksum metadata in .simtool/build"
```

---

### Task 4: Test sessions move to `.simtool/test-sessions/`

**Files:**
- Modify: `Sources/SimToolCore/TestSession.swift:98–129`
- Modify: `Sources/SimToolServer/StreamServer.swift:20–36, 84`
- Modify: `Sources/SimToolCLI/SimTool.swift` (`runViewer` ~1034, `Serve.run` ~974, `Run.run` ~1219)
- Modify: `Sources/SimToolServer/TestSessionController.swift:199` (comment only)
- Test: `Tests/SimToolCoreTests/TestSessionStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/SimToolCoreTests/TestSessionStoreTests.swift`:

```swift
    func testWriteInsideSimtoolDirectoryCreatesGitignore() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-project-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let simtoolDir = projectRoot.appendingPathComponent(".simtool", isDirectory: true)
        let store = TestSessionStore(root: SimToolDirectory.testSessionsDirectory(in: simtoolDir))

        let session = TestSession(
            id: TestSessionStore.makeId(),
            title: "t",
            deviceUdid: "UDID",
            deviceName: "iPhone 16 Pro",
            startedAt: Date(),
            status: .running
        )
        try store.write(session)

        XCTAssertEqual(
            try String(contentsOf: simtoolDir.appendingPathComponent(".gitignore"), encoding: .utf8),
            "*\n"
        )
    }
```

- [ ] **Step 2: Run tests to verify the new one fails**

Run: `swift test --filter TestSessionStoreTests`
Expected: new test FAILS — no `.gitignore` is created (other tests still pass).

- [ ] **Step 3: Rework `TestSessionStore` root handling**

In `Sources/SimToolCore/TestSession.swift`:

1. Replace the class doc comment (lines 98–100) with:

```swift
/// Disk layout: `<root>/<session-id>/session.json` + `video.mp4`. The root is
/// the project's `.simtool/test-sessions` directory: test artifacts belong to
/// the project the server was started for and must outlive `$TMPDIR` where
/// daemon sessions live.
```

2. Delete `static var defaultRoot` (lines 102–106) and make the root required:

```swift
    public init(root: URL) {
        self.root = root
    }
```

3. In `ensureDirectory(for:)` (line 127), ensure the enclosing `.simtool` directory first:

```swift
    public func ensureDirectory(for id: String) throws {
        try SimToolDirectory.ensureEnclosing(root)
        try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
    }
```

- [ ] **Step 4: Make the server's test-session root explicit**

In `Sources/SimToolServer/StreamServer.swift`:

1. Change the property and doc (lines 19–20):

```swift
    /// Where test sessions persist: the project's `.simtool/test-sessions`.
    public var testSessionsRoot: URL
```

2. In the init, change the parameter to:

```swift
        testSessionsRoot: URL = SimToolDirectory.testSessionsDirectory(in: SimToolDirectory.resolve())
```

(The default encodes the standalone-`serve` rule — resolve `.simtool` from cwd — and keeps unrelated route tests compiling.)

3. Line 84 already reads `TestSessionStore(root: config.testSessionsRoot)`; it now passes a non-optional URL — no change needed beyond compiling.

In `Sources/SimToolServer/TestSessionController.swift` line 199, update the comment that mentions `~/.simtool` to say the store root is injected so unit tests never mutate a real project's `.simtool` directory.

- [ ] **Step 5: Thread the root through the CLI**

In `Sources/SimToolCLI/SimTool.swift`:

1. Add a parameter to `runViewer` (line 1034):

```swift
func runViewer(
    device: SimulatorDevice,
    host: String,
    port: UInt16,
    defaultLogApp: String?,
    testSessionsRoot: URL,
    window: Bool,
    printSessionJSON: Bool,
    openBrowser: Bool,
    sessionId: String?
) async throws {
```

and pass it into the config construction (line 1045):

```swift
    let config = StreamServerConfig(
        host: host,
        port: port,
        device: device,
        captureEnabled: !window,
        defaultLogApp: defaultLogApp,
        testSessionsRoot: testSessionsRoot
    )
```

2. In `Serve.run()` (the `runViewer` call at ~line 981), add:

```swift
            testSessionsRoot: SimToolDirectory.testSessionsDirectory(in: SimToolDirectory.resolve()),
```

3. In `Run.run()` (the `runViewer` call at ~line 1219), add:

```swift
            testSessionsRoot: SimToolDirectory.testSessionsDirectory(in: projectConfig.simtoolDirectory),
```

4. Add `import SimToolCore` check — `SimTool.swift` already imports it (verify with `grep -n "import SimToolCore" Sources/SimToolCLI/SimTool.swift`).

- [ ] **Step 6: Run tests and build**

Run: `swift build && swift test --filter TestSessionStoreTests && swift test --filter TestSessionControllerTests && swift test --filter TestSessionRouteTests`
Expected: build PASSES, all listed suites PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/SimToolCore/TestSession.swift Sources/SimToolServer/StreamServer.swift Sources/SimToolServer/TestSessionController.swift Sources/SimToolCLI/SimTool.swift Tests/SimToolCoreTests/TestSessionStoreTests.swift
git commit -m "feat: persist test sessions in the project's .simtool/test-sessions"
```

---

### Task 5: `simtool run` anchors the build cache on the config

**Files:**
- Modify: `Sources/SimToolCLI/SimTool.swift` (`buildAppWithProgress` ~line 624, `installAndLaunchAppWithProgress` ~line 641, `Run.run` ~1170–1219)

- [ ] **Step 1: Add a cache parameter to the progress helpers**

In `Sources/SimToolCLI/SimTool.swift`:

```swift
func buildAppWithProgress(
    selection: SimulatorAppBuildSelection,
    force: Bool,
    cache: SimulatorAppBuildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve())
) async throws -> SimulatorAppBuildPayload {
```

and forward it in the body: `SimulatorAppLifecycleClient.build(selection: selection, force: force, cache: cache, progress: ...)`.

Same for `installAndLaunchAppWithProgress`:

```swift
func installAndLaunchAppWithProgress(
    build buildPayload: SimulatorAppBuildPayload,
    device: SimulatorDevice,
    launchEnvironment: [String: String] = [:],
    launchArguments: [String] = [],
    force: Bool,
    cache: SimulatorAppBuildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve())
) async throws -> SimulatorAppLaunchPayload {
```

forwarding `cache: cache` into `SimulatorAppLifecycleClient.installAndLaunch(...)`.

(`AppCommand.Build/Launch/Test` keep calling the helpers/client without `cache:` — the cwd-resolved default is the spec behavior for flag-driven commands.)

- [ ] **Step 2: Anchor `Run` on the config's `.simtool` directory**

In `Run.run()`, after `let projectConfig = try ProjectConfigLoader.load(explicitPath: config)` add:

```swift
        let buildCache = SimulatorAppBuildCache(simtoolDirectory: projectConfig.simtoolDirectory)
```

- In the `common.json` branch, pass `cache: buildCache` to `SimulatorAppLifecycleClient.launch(...)`.
- In the interactive branch, pass `cache: buildCache` to both `buildAppWithProgress(...)` and `installAndLaunchAppWithProgress(...)`.

- [ ] **Step 3: Build and run CLI tests**

Run: `swift build && swift test --filter SimToolCLITests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/SimToolCLI/SimTool.swift
git commit -m "feat(cli): anchor build checksum cache on the project's .simtool directory"
```

---

### Task 6: Help texts, docs, and surface tests

**Files:**
- Modify: `Sources/SimToolCLI/SimTool.swift:1136, 1157, 1240, 1290`
- Modify: `Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift:55, 60`
- Modify: `README.md` (lines ~59, ~101, ~300–345 — verify with grep)

- [ ] **Step 1: Update CLI help texts**

In `Sources/SimToolCLI/SimTool.swift`:

- Line 1136 (`Run` abstract): `"Read .simtool/config.yml, launch the configured app, and open the web or native viewer."`
- Lines 1157, 1240, 1290 (`--config` help on `Run`, `Open`, `Interactive`): `"Path to the project config. Defaults to .simtool/config.yml discovered from the working directory upward."`

- [ ] **Step 2: Update the surface test**

In `Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift` lines 55 and 60, change `.simtool.yml` to `.simtool/config.yml` (both the parsed argument and the assertion).

- [ ] **Step 3: Update README and docs**

Run `grep -rn "simtool.yml\|~/.simtool" README.md docs CLAUDE.md 2>/dev/null` and update every hit:

- README line ~59: interactive mode reads deeplinks from `.simtool/config.yml`.
- README line ~101: sessions persist under `<project>/.simtool/test-sessions/<session-id>/`.
- README lines ~300–306: the config is a local `.simtool/config.yml` (the `.simtool` folder is git-ignored via its own auto-created `.gitignore`); SimTool discovers `.simtool/config.yml` by searching upward from the working directory. Update the YAML example header comment to `# .simtool/config.yml`.
- README line ~339: `swift run simtool run --config path/to/.simtool/config.yml`.
- Mention that build checksum metadata lives in `.simtool/build/` while DerivedData stays in `~/Library/Caches/SimTool`, wherever the README currently describes checksum caching (grep for "checksum" in README.md).

- [ ] **Step 4: Run the full suite**

Run: `swift build && swift test`
Expected: everything PASSES.

- [ ] **Step 5: Commit**

```bash
git add Sources/SimToolCLI/SimTool.swift Tests/SimToolCLITests/SimToolCommandSurfaceTests.swift README.md
git commit -m "docs(cli): point help texts and README at .simtool/config.yml"
```

---

### Task 7: End-to-end smoke check

- [ ] **Step 1: Verify discovery and error message**

```bash
cd "$(mktemp -d)" && swift run --package-path /Users/maksim/Workspace/SimTool simtool run 2>&1 | head -3
```

Expected output contains: `No .simtool/config.yml found in the current directory or any parent. Create one or pass --config <path>.`

- [ ] **Step 2: Verify the self-ignoring `.gitignore` keeps git clean**

```bash
T=$(mktemp -d) && cd "$T" && git init -q && mkdir .simtool && printf '*\n' > .simtool/.gitignore && touch .simtool/config.yml && git status --porcelain
```

Expected: empty output (the whole `.simtool/` folder is ignored).

- [ ] **Step 3: Final full test run and merge prep**

```bash
cd /Users/maksim/Workspace/SimTool && swift test
```

Expected: PASS. Then use superpowers:finishing-a-development-branch if working on a branch.
