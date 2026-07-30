import CryptoKit
import Foundation

public struct SimulatorAppBuildIdentity: Codable, Equatable, Sendable {
    public var workspacePath: String?
    public var projectPath: String?
    public var scheme: String
    public var configuration: String
    public var sdk: String
    public var derivedDataPath: String?

    public init(
        workspacePath: String? = nil,
        projectPath: String? = nil,
        scheme: String,
        configuration: String = "Debug",
        sdk: String = "iphonesimulator",
        derivedDataPath: String? = nil
    ) {
        self.workspacePath = workspacePath
        self.projectPath = projectPath
        self.scheme = scheme
        self.configuration = configuration
        self.sdk = sdk
        self.derivedDataPath = derivedDataPath
    }
}

public struct SimulatorAppBuildSelection: Codable, Equatable, Sendable {
    public var identity: SimulatorAppBuildIdentity

    public init(identity: SimulatorAppBuildIdentity) throws {
        try Self.validate(identity)
        self.identity = identity
    }

    public static func validated(
        workspacePath: String?,
        projectPath: String?,
        scheme: String?,
        configuration: String? = nil,
        derivedDataPath: String? = nil
    ) throws -> SimulatorAppBuildSelection {
        let trimmedScheme = scheme?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedConfiguration = configuration?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identity = SimulatorAppBuildIdentity(
            workspacePath: canonicalPath(workspacePath),
            projectPath: canonicalPath(projectPath),
            scheme: trimmedScheme,
            configuration: trimmedConfiguration.isEmpty ? "Debug" : trimmedConfiguration,
            derivedDataPath: canonicalPath(derivedDataPath)
        )
        return try SimulatorAppBuildSelection(identity: identity)
    }

    public var projectRoot: URL {
        sourceURL.deletingLastPathComponent()
    }

    public var sourceURL: URL {
        URL(fileURLWithPath: identity.workspacePath ?? identity.projectPath!)
    }

    public var sourceKind: String {
        identity.workspacePath == nil ? "project" : "workspace"
    }

    private static func validate(_ identity: SimulatorAppBuildIdentity) throws {
        let hasWorkspace = identity.workspacePath?.isEmpty == false
        let hasProject = identity.projectPath?.isEmpty == false
        guard hasWorkspace != hasProject else {
            throw SimToolError("Pass exactly one of --workspace <path> or --project <path>.")
        }
        guard !identity.scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimToolError("Pass --scheme <scheme> for simulator app builds.")
        }
        // Fail fast on missing paths: fingerprinting walks the source's parent
        // directory, which resolves to "/" for a bad top-level path.
        if let workspacePath = identity.workspacePath, !FileManager.default.fileExists(atPath: workspacePath) {
            throw SimToolError("Workspace not found: \(workspacePath)")
        }
        if let projectPath = identity.projectPath, !FileManager.default.fileExists(atPath: projectPath) {
            throw SimToolError("Project not found: \(projectPath)")
        }
    }

    private static func canonicalPath(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let expanded = NSString(string: value).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

public struct SimulatorAppBuildInputFile: Codable, Equatable, Sendable {
    public var relativePath: String
    public var path: String
    public var byteCount: Int64

    public init(relativePath: String, path: String, byteCount: Int64) {
        self.relativePath = relativePath
        self.path = path
        self.byteCount = byteCount
    }
}

public struct SimulatorAppBuildFingerprint: Codable, Equatable, Sendable {
    public var checksum: String
    public var inputFileCount: Int

    public init(checksum: String, inputFileCount: Int) {
        self.checksum = checksum
        self.inputFileCount = inputFileCount
    }
}

public struct SimulatorAppProcessStepSummary: Codable, Equatable, Sendable {
    public var name: String
    public var ran: Bool
    public var status: Int32?
    public var stdout: String
    public var stderr: String

    public init(name: String, ran: Bool, status: Int32? = nil, stdout: String = "", stderr: String = "") {
        self.name = name
        self.ran = ran
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public init(name: String, output: ProcessOutput, maxCharacters: Int = 4_000) {
        self.name = name
        self.ran = true
        self.status = output.status
        self.stdout = Self.trim(output.stdoutString, maxCharacters: maxCharacters)
        self.stderr = Self.trim(output.stderrString, maxCharacters: maxCharacters)
    }

    private static func trim(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }
        let suffix = value.suffix(maxCharacters)
        return "..." + suffix
    }
}

public struct SimulatorAppInstallRecord: Codable, Equatable, Sendable {
    public var deviceUDID: String
    public var checksum: String
    public var bundleIdentifier: String
    public var installedAt: Date

    public init(deviceUDID: String, checksum: String, bundleIdentifier: String, installedAt: Date = Date()) {
        self.deviceUDID = deviceUDID
        self.checksum = checksum
        self.bundleIdentifier = bundleIdentifier
        self.installedAt = installedAt
    }
}

public struct SimulatorAppBuildCacheMetadata: Codable, Equatable, Sendable {
    public var identity: SimulatorAppBuildIdentity
    public var checksum: String
    public var inputFileCount: Int
    public var appBundlePath: String
    public var bundleIdentifier: String
    public var builtAt: Date
    public var installRecords: [String: SimulatorAppInstallRecord]

    public init(
        identity: SimulatorAppBuildIdentity,
        checksum: String,
        inputFileCount: Int,
        appBundlePath: String,
        bundleIdentifier: String,
        builtAt: Date = Date(),
        installRecords: [String: SimulatorAppInstallRecord] = [:]
    ) {
        self.identity = identity
        self.checksum = checksum
        self.inputFileCount = inputFileCount
        self.appBundlePath = appBundlePath
        self.bundleIdentifier = bundleIdentifier
        self.builtAt = builtAt
        self.installRecords = installRecords
    }
}

public struct SimulatorAppBuildPayload: Codable, Equatable, Sendable {
    public var identity: SimulatorAppBuildIdentity
    public var checksum: String
    public var inputFileCount: Int
    public var cacheHit: Bool
    public var xcodebuildRan: Bool
    public var appBundlePath: String
    public var bundleIdentifier: String
    public var xcodebuild: SimulatorAppProcessStepSummary

    public init(
        identity: SimulatorAppBuildIdentity,
        checksum: String,
        inputFileCount: Int,
        cacheHit: Bool,
        xcodebuildRan: Bool,
        appBundlePath: String,
        bundleIdentifier: String,
        xcodebuild: SimulatorAppProcessStepSummary
    ) {
        self.identity = identity
        self.checksum = checksum
        self.inputFileCount = inputFileCount
        self.cacheHit = cacheHit
        self.xcodebuildRan = xcodebuildRan
        self.appBundlePath = appBundlePath
        self.bundleIdentifier = bundleIdentifier
        self.xcodebuild = xcodebuild
    }
}

public struct SimulatorAppLaunchPayload: Codable, Equatable, Sendable {
    public var build: SimulatorAppBuildPayload
    public var device: SimulatorDevice
    public var launchEnvironment: [String: String]
    public var launchArguments: [String]
    public var installed: Bool
    public var launched: Bool
    public var installRan: Bool
    public var launchRan: Bool
    public var install: SimulatorAppProcessStepSummary
    public var launch: SimulatorAppProcessStepSummary

    public init(
        build: SimulatorAppBuildPayload,
        device: SimulatorDevice,
        launchEnvironment: [String: String] = [:],
        launchArguments: [String] = [],
        installed: Bool,
        launched: Bool,
        installRan: Bool,
        launchRan: Bool,
        install: SimulatorAppProcessStepSummary,
        launch: SimulatorAppProcessStepSummary
    ) {
        self.build = build
        self.device = device
        self.launchEnvironment = launchEnvironment
        self.launchArguments = launchArguments
        self.installed = installed
        self.launched = launched
        self.installRan = installRan
        self.launchRan = launchRan
        self.install = install
        self.launch = launch
    }
}

public struct SimulatorAppTestPayload: Codable, Equatable, Sendable {
    public var identity: SimulatorAppBuildIdentity
    public var device: SimulatorDevice
    public var passed: Bool
    public var xcodebuildRan: Bool
    public var xcodebuild: SimulatorAppProcessStepSummary

    public init(
        identity: SimulatorAppBuildIdentity,
        device: SimulatorDevice,
        passed: Bool,
        xcodebuildRan: Bool,
        xcodebuild: SimulatorAppProcessStepSummary
    ) {
        self.identity = identity
        self.device = device
        self.passed = passed
        self.xcodebuildRan = xcodebuildRan
        self.xcodebuild = xcodebuild
    }
}

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

    public func identityKey(for identity: SimulatorAppBuildIdentity) throws -> String {
        try SimulatorAppBuildFingerprinter.sha256Hex(JSON.data(identity, pretty: false))
    }

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

    public func readMetadata(for identity: SimulatorAppBuildIdentity) -> SimulatorAppBuildCacheMetadata? {
        guard let url = try? metadataURL(for: identity), FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSON.decoder.decode(SimulatorAppBuildCacheMetadata.self, from: data)
    }

    public func validMetadata(for identity: SimulatorAppBuildIdentity, checksum: String) -> SimulatorAppBuildCacheMetadata? {
        guard let metadata = readMetadata(for: identity), metadata.checksum == checksum else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: metadata.appBundlePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return metadata
    }

    public func write(_ metadata: SimulatorAppBuildCacheMetadata) throws {
        let url = try metadataURL(for: metadata.identity)
        try SimToolDirectory.ensureEnclosing(metadataRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSON.data(metadata).write(to: url, options: [.atomic])
    }

    public func recordInstall(
        identity: SimulatorAppBuildIdentity,
        checksum: String,
        bundleIdentifier: String,
        deviceUDID: String
    ) throws {
        guard var metadata = readMetadata(for: identity) else { return }
        metadata.installRecords[deviceUDID] = SimulatorAppInstallRecord(
            deviceUDID: deviceUDID,
            checksum: checksum,
            bundleIdentifier: bundleIdentifier
        )
        try write(metadata)
    }
}

public enum SimulatorAppBuildFingerprinter {
    public static func fingerprint(selection: SimulatorAppBuildSelection, cacheRoot: URL? = nil) throws -> SimulatorAppBuildFingerprint {
        let files = try inputFiles(selection: selection, cacheRoot: cacheRoot)
        var hasher = SHA256()
        try update(&hasher, with: JSON.data(selection.identity, pretty: false))
        for file in files {
            update(&hasher, with: "\nfile:\(file.relativePath):\(file.byteCount)\n")
            try update(&hasher, with: Data(contentsOf: URL(fileURLWithPath: file.path)))
        }
        return SimulatorAppBuildFingerprint(checksum: hex(hasher.finalize()), inputFileCount: files.count)
    }

    public static func inputFiles(selection: SimulatorAppBuildSelection, cacheRoot: URL? = nil) throws -> [SimulatorAppBuildInputFile] {
        let root = selection.projectRoot.standardizedFileURL
        // When the project lives in a git work tree, hash only non-ignored files.
        // Generated artifacts (Tuist's `.xcodeproj`/`Derived/`, DerivedData, SPM
        // checkouts) are gitignored; they get rewritten on every build and would
        // otherwise destabilize the checksum, breaking cache reuse. Outside git,
        // fall back to the filesystem walk.
        if let gitFiles = gitInputFiles(root: root, cacheRoot: cacheRoot) {
            return gitFiles
        }
        let excludedRoot = cacheRoot?.standardizedFileURL.path
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: nil
        ) else { return [] }

        var files: [SimulatorAppBuildInputFile] = []
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            let path = standardized.path
            if let excludedRoot, path == excludedRoot || path.hasPrefix(excludedRoot + "/") {
                if isDirectory(standardized) { enumerator.skipDescendants() }
                continue
            }
            if isExcludedPath(standardized, root: root) {
                if isDirectory(standardized) { enumerator.skipDescendants() }
                continue
            }
            guard !isDirectory(standardized), isBuildInputFile(standardized, root: root) else { continue }
            let relativePath = standardized.pathRelative(to: root)
            let byteCount = ((try? standardized.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
            files.append(SimulatorAppBuildInputFile(relativePath: relativePath, path: path, byteCount: byteCount))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    public static func sha256Hex(_ data: Data) throws -> String {
        hex(SHA256.hash(data: data))
    }

    /// Returns the build-input files known to git (tracked plus untracked but
    /// not ignored), or `nil` when `root` is not inside a git work tree (or git
    /// is unavailable) so the caller falls back to the filesystem walk. Listing
    /// via git is what excludes gitignored generated artifacts from the
    /// fingerprint; the same type filter (`isBuildInputFile`) is then applied so
    /// the included file set matches the filesystem walk for tracked files.
    private static func gitInputFiles(root: URL, cacheRoot: URL?) -> [SimulatorAppBuildInputFile]? {
        guard let output = runGit(
            ["-C", root.path, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            in: root
        ), output.status == 0 else { return nil }

        let excludedRoot = cacheRoot?.standardizedFileURL.path
        var files: [SimulatorAppBuildInputFile] = []
        var seen = Set<String>()
        for relative in String(decoding: output.stdout, as: UTF8.self).split(separator: "\0") {
            let relativePath = String(relative)
            if relativePath.isEmpty { continue }
            let url = root.appendingPathComponent(relativePath).standardizedFileURL
            let path = url.path
            guard seen.insert(path).inserted else { continue }
            if let excludedRoot, path == excludedRoot || path.hasPrefix(excludedRoot + "/") { continue }
            guard isBuildInputFile(url, root: root) else { continue }
            // Skip directories and stale index entries (deleted/renamed files).
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let byteCount = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
            files.append(SimulatorAppBuildInputFile(relativePath: url.pathRelative(to: root), path: path, byteCount: byteCount))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    /// Runs git synchronously, returning its exit status and stdout, or `nil` if
    /// git could not be launched. stderr is discarded; stdout is drained before
    /// `waitUntilExit` to avoid pipe-buffer deadlock.
    private static func runGit(_ arguments: [String], in directory: URL) -> (status: Int32, stdout: Data)? {
        let gitURL = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: gitURL.path) else { return nil }
        let process = Process()
        process.executableURL = gitURL
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    private static func update(_ hasher: inout SHA256, with string: String) {
        hasher.update(data: Data(string.utf8))
    }

    private static func update(_ hasher: inout SHA256, with data: Data) throws {
        hasher.update(data: data)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isDirectory(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) == true
    }

    private static func isExcludedPath(_ url: URL, root: URL) -> Bool {
        let components = url.pathRelative(to: root).split(separator: "/").map(String.init)
        return components.contains { excludedDirectoryNames.contains($0) }
    }

    private static func isBuildInputFile(_ url: URL, root: URL) -> Bool {
        let relativeComponents = url.pathRelative(to: root).split(separator: "/").map(String.init)
        if relativeComponents.contains(where: isBuildPackageComponent) { return true }
        let filename = url.lastPathComponent
        if includedFileNames.contains(filename) { return true }
        let fileExtension = url.pathExtension.lowercased()
        return includedExtensions.contains(fileExtension)
    }

    private static func isBuildPackageComponent(_ component: String) -> Bool {
        buildPackageExtensions.contains(URL(fileURLWithPath: component).pathExtension.lowercased())
    }

    private static let excludedDirectoryNames: Set<String> = [
        ".build", ".git", ".hg", ".svn", ".swiftpm", ".simtool", "Build", "build", "DerivedData", "xcuserdata"
    ]

    private static let buildPackageExtensions: Set<String> = [
        "xcassets", "xcdatamodeld", "xcodeproj", "xcworkspace"
    ]

    private static let includedFileNames: Set<String> = [
        ".env", "Package.resolved", "Package.swift", "Podfile", "Podfile.lock", "Cartfile", "Cartfile.resolved",
        "project.pbxproj", "contents.xcworkspacedata"
    ]

    private static let includedExtensions: Set<String> = [
        "c", "cc", "cpp", "entitlements", "graphql", "h", "hpp", "html", "json", "m", "metal", "mm", "modulemap",
        "plist", "png", "jpg", "jpeg", "pdf", "storyboard", "strings", "stringsdict", "swift", "svg", "toml", "webp",
        "xalloc", "xcconfig", "xcdatamodel", "xcscheme", "xib", "xml", "yaml", "yml"
    ]
}

/// The result of the checksum stage: the source fingerprint plus the resolved
/// cache decision, computed without running xcodebuild. A non-nil
/// `cachedMetadata` means a prior build of the same sources can be reused.
public struct SimulatorAppBuildPlan: Sendable {
    public var selection: SimulatorAppBuildSelection
    public var fingerprint: SimulatorAppBuildFingerprint
    public var derivedDataPath: String
    public var cachedMetadata: SimulatorAppBuildCacheMetadata?

    public init(
        selection: SimulatorAppBuildSelection,
        fingerprint: SimulatorAppBuildFingerprint,
        derivedDataPath: String,
        cachedMetadata: SimulatorAppBuildCacheMetadata?
    ) {
        self.selection = selection
        self.fingerprint = fingerprint
        self.derivedDataPath = derivedDataPath
        self.cachedMetadata = cachedMetadata
    }

    public var isCacheHit: Bool { cachedMetadata != nil }
}

public enum SimulatorAppLifecycleClient {
    /// Checksum stage: fingerprints the sources and resolves the build cache
    /// without running xcodebuild. Split out from `build` so callers (e.g. the
    /// `run` progress UI) can present it as its own step. `force` skips the
    /// cache lookup so the plan always reports a miss.
    public static func plan(
        selection: SimulatorAppBuildSelection,
        force: Bool = false,
        cache: SimulatorAppBuildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve())
    ) throws -> SimulatorAppBuildPlan {
        let fingerprint = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, cacheRoot: cache.derivedDataRoot)
        let derivedDataPath: String
        if let selectedDerivedDataPath = selection.identity.derivedDataPath {
            derivedDataPath = selectedDerivedDataPath
        } else {
            derivedDataPath = try cache.derivedDataPath(for: selection.identity)
        }
        let cachedMetadata = force ? nil : cache.validMetadata(for: selection.identity, checksum: fingerprint.checksum)
        return SimulatorAppBuildPlan(
            selection: selection,
            fingerprint: fingerprint,
            derivedDataPath: derivedDataPath,
            cachedMetadata: cachedMetadata
        )
    }

    /// `progress` receives short build statuses ("Compiling Foo.swift") parsed
    /// from xcodebuild output. It is invoked on a background thread as output
    /// arrives; blocking inside it backpressures pipe reads.
    public static func build(
        selection: SimulatorAppBuildSelection,
        force: Bool = false,
        cache: SimulatorAppBuildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve()),
        timeoutSeconds: TimeInterval? = 1_800,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SimulatorAppBuildPayload {
        let plan = try plan(selection: selection, force: force, cache: cache)
        return try await build(plan: plan, cache: cache, timeoutSeconds: timeoutSeconds, progress: progress)
    }

    /// Build stage: runs xcodebuild for a planned build, or returns a cache-hit
    /// payload instantly when `plan.cachedMetadata` is set. Pair with `plan`,
    /// passing the same `cache`.
    public static func build(
        plan: SimulatorAppBuildPlan,
        cache: SimulatorAppBuildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve()),
        timeoutSeconds: TimeInterval? = 1_800,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SimulatorAppBuildPayload {
        let selection = plan.selection
        let fingerprint = plan.fingerprint
        if let metadata = plan.cachedMetadata {
            return SimulatorAppBuildPayload(
                identity: selection.identity,
                checksum: fingerprint.checksum,
                inputFileCount: fingerprint.inputFileCount,
                cacheHit: true,
                xcodebuildRan: false,
                appBundlePath: metadata.appBundlePath,
                bundleIdentifier: metadata.bundleIdentifier,
                xcodebuild: SimulatorAppProcessStepSummary(name: "xcodebuild", ran: false)
            )
        }

        let derivedDataPath = plan.derivedDataPath
        let buildArguments = xcodebuildArguments(selection: selection, derivedDataPath: derivedDataPath)
        let onStdoutLine: (@Sendable (String) -> Void)? = progress.map { progress in
            { @Sendable line in
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
        let buildStep = SimulatorAppProcessStepSummary(name: "xcodebuild", output: buildOutput)
        guard buildOutput.status == 0 else {
            let detail = XcodebuildFailure.detail(from: buildOutput)
            throw SimToolError("xcodebuild failed for scheme \(selection.identity.scheme): \(detail)")
        }

        let product = try await builtProduct(selection: selection, derivedDataPath: derivedDataPath)
        let bundleIdentifier = try bundleIdentifier(appBundleURL: product.appBundleURL)
        var metadata = SimulatorAppBuildCacheMetadata(
            identity: selection.identity,
            checksum: fingerprint.checksum,
            inputFileCount: fingerprint.inputFileCount,
            appBundlePath: product.appBundleURL.path,
            bundleIdentifier: bundleIdentifier
        )
        if let previous = cache.readMetadata(for: selection.identity) {
            metadata.installRecords = previous.installRecords.filter { $0.value.checksum == fingerprint.checksum }
        }
        try cache.write(metadata)

        return SimulatorAppBuildPayload(
            identity: selection.identity,
            checksum: fingerprint.checksum,
            inputFileCount: fingerprint.inputFileCount,
            cacheHit: false,
            xcodebuildRan: true,
            appBundlePath: product.appBundleURL.path,
            bundleIdentifier: bundleIdentifier,
            xcodebuild: buildStep
        )
    }

    /// Records checksum-cache metadata for an app built outside SimTool — for
    /// example, from an Xcode post-build phase. Computes the same source
    /// fingerprint `build` does and writes it alongside the externally built
    /// `.app` path and its bundle identifier, so a later `simtool run` (or
    /// `app build`) sees a cache hit and reuses the bundle instead of
    /// re-running xcodebuild. `appBundleURL` must point at an existing `.app`
    /// directory. The fingerprint must use the same `cache` (hence the same
    /// excluded DerivedData root) as `run`, or the checksum will not match.
    @discardableResult
    public static func recordExternalBuild(
        selection: SimulatorAppBuildSelection,
        appBundleURL: URL,
        cache: SimulatorAppBuildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve())
    ) throws -> SimulatorAppBuildPayload {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appBundleURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SimToolError("App bundle not found: \(appBundleURL.path)")
        }
        let fingerprint = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, cacheRoot: cache.derivedDataRoot)
        let bundleIdentifier = try bundleIdentifier(appBundleURL: appBundleURL)
        var metadata = SimulatorAppBuildCacheMetadata(
            identity: selection.identity,
            checksum: fingerprint.checksum,
            inputFileCount: fingerprint.inputFileCount,
            appBundlePath: appBundleURL.standardizedFileURL.path,
            bundleIdentifier: bundleIdentifier
        )
        // Drop install records for older checksums: the externally built app no
        // longer matches what any device has installed. Records matching the new
        // checksum (a rebuild with no source change) stay valid.
        if let previous = cache.readMetadata(for: selection.identity) {
            metadata.installRecords = previous.installRecords.filter { $0.value.checksum == fingerprint.checksum }
        }
        try cache.write(metadata)

        return SimulatorAppBuildPayload(
            identity: selection.identity,
            checksum: fingerprint.checksum,
            inputFileCount: fingerprint.inputFileCount,
            cacheHit: false,
            xcodebuildRan: false,
            appBundlePath: metadata.appBundlePath,
            bundleIdentifier: bundleIdentifier,
            xcodebuild: SimulatorAppProcessStepSummary(name: "xcodebuild", ran: false)
        )
    }

    public static func launch(
        selection: SimulatorAppBuildSelection,
        device: SimulatorDevice,
        launchEnvironment: [String: String] = [:],
        launchArguments: [String] = [],
        force: Bool = false,
        cache: SimulatorAppBuildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve()),
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

    /// Whether the bundle recorded as installed on this device is the one we are
    /// about to run. `force` reinstalls regardless; a fresh `xcodebuild` means
    /// whatever is on the device is stale even when the checksum matches, because
    /// the record was written for the previous bundle.
    public static func needsInstall(
        checksum: String,
        bundleIdentifier: String,
        installed: SimulatorAppInstallRecord?,
        xcodebuildRan: Bool,
        force: Bool
    ) -> Bool {
        force
            || xcodebuildRan
            || installed?.checksum != checksum
            || installed?.bundleIdentifier != bundleIdentifier
    }

    /// Brings the app on the device up to date without launching it — what a
    /// test run needs before it stages anything, since the run launches the app
    /// itself with the test's own arguments.
    @discardableResult
    public static func install(
        build buildPayload: SimulatorAppBuildPayload,
        device: SimulatorDevice,
        force: Bool = false,
        cache: SimulatorAppBuildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve()),
        timeoutSeconds: TimeInterval? = 1_800,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Bool {
        let installRecord = cache.readMetadata(for: buildPayload.identity)?.installRecords[device.udid]
        guard needsInstall(
            checksum: buildPayload.checksum,
            bundleIdentifier: buildPayload.bundleIdentifier,
            installed: installRecord,
            xcodebuildRan: buildPayload.xcodebuildRan,
            force: force
        ) else { return false }

        progress?("Installing…")
        _ = try await installApp(
            deviceUDID: device.udid,
            appBundlePath: buildPayload.appBundlePath,
            timeoutSeconds: timeoutSeconds
        )
        try cache.recordInstall(
            identity: buildPayload.identity,
            checksum: buildPayload.checksum,
            bundleIdentifier: buildPayload.bundleIdentifier,
            deviceUDID: device.udid
        )
        return true
    }

    /// Installs (only when the cache's install record does not match the
    /// payload checksum, or `force` is set — `force` forces a reinstall, not a
    /// rebuild) and cold-launches the app, retrying install+launch once when
    /// the failure looks like a missing install. `progress` receives phase
    /// statuses ("Installing…", "Launching…", "Reinstalling…").
    public static func installAndLaunch(
        build buildPayload: SimulatorAppBuildPayload,
        device: SimulatorDevice,
        launchEnvironment: [String: String] = [:],
        launchArguments: [String] = [],
        force: Bool = false,
        cache: SimulatorAppBuildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve()),
        timeoutSeconds: TimeInterval? = 1_800,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SimulatorAppLaunchPayload {
        let metadata = cache.readMetadata(for: buildPayload.identity)
        let installRecord = metadata?.installRecords[device.udid]
        var installStep = SimulatorAppProcessStepSummary(name: "simctl install", ran: false)
        var installRan = false

        let needsInstall = needsInstall(
            checksum: buildPayload.checksum,
            bundleIdentifier: buildPayload.bundleIdentifier,
            installed: installRecord,
            xcodebuildRan: buildPayload.xcodebuildRan,
            force: force
        )
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

    /// Builds the `xcrun simctl launch` argument vector. Always passes
    /// `--terminate-running-process` so the app is cold-launched: launch
    /// arguments and `SIMCTL_CHILD_*` environment only take effect on a fresh
    /// process, never on an already-running one. Anything in `launchArguments`
    /// is forwarded verbatim after the bundle id and reaches the app through
    /// `CommandLine.arguments` (and the `NSArgumentDomain` of `UserDefaults`).
    public static func simctlLaunchArguments(
        deviceUDID: String,
        bundleIdentifier: String,
        launchArguments: [String] = []
    ) -> [String] {
        ["simctl", "launch", "--terminate-running-process", deviceUDID, bundleIdentifier] + launchArguments
    }

    public static func xcodebuildArguments(
        selection: SimulatorAppBuildSelection,
        derivedDataPath: String?,
        showBuildSettings: Bool = false
    ) -> [String] {
        var arguments = ["xcodebuild"]
        if let workspacePath = selection.identity.workspacePath {
            arguments += ["-workspace", workspacePath]
        } else if let projectPath = selection.identity.projectPath {
            arguments += ["-project", projectPath]
        }
        arguments += [
            "-scheme", selection.identity.scheme,
            "-configuration", selection.identity.configuration,
            "-sdk", selection.identity.sdk,
            "-destination", "generic/platform=iOS Simulator",
        ]
        if let derivedDataPath, !derivedDataPath.isEmpty {
            arguments += ["-derivedDataPath", derivedDataPath]
        }
        if showBuildSettings {
            arguments += ["-showBuildSettings", "-json"]
        } else {
            arguments.append("build")
        }
        return arguments
    }

    public static func xcodebuildTestArguments(
        selection: SimulatorAppBuildSelection,
        device: SimulatorDevice,
        derivedDataPath: String?
    ) -> [String] {
        var arguments = ["xcodebuild"]
        if let workspacePath = selection.identity.workspacePath {
            arguments += ["-workspace", workspacePath]
        } else if let projectPath = selection.identity.projectPath {
            arguments += ["-project", projectPath]
        }
        arguments += [
            "-scheme", selection.identity.scheme,
            "-configuration", selection.identity.configuration,
            "-sdk", selection.identity.sdk,
            "-destination", "platform=iOS Simulator,id=\(device.udid)",
        ]
        if let derivedDataPath, !derivedDataPath.isEmpty {
            arguments += ["-derivedDataPath", derivedDataPath]
        }
        arguments.append("test")
        return arguments
    }

    public static func test(
        selection: SimulatorAppBuildSelection,
        device: SimulatorDevice,
        timeoutSeconds: TimeInterval? = 1_800
    ) async throws -> SimulatorAppTestPayload {
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: xcodebuildTestArguments(
                selection: selection,
                device: device,
                derivedDataPath: selection.identity.derivedDataPath
            ),
            timeoutSeconds: timeoutSeconds
        )
        let step = SimulatorAppProcessStepSummary(name: "xcodebuild test", output: output)
        return SimulatorAppTestPayload(
            identity: selection.identity,
            device: device,
            passed: output.status == 0,
            xcodebuildRan: true,
            xcodebuild: step
        )
    }

    public static func parseLaunchEnvironment(_ entries: [String]) throws -> [String: String] {
        var environment: [String: String] = [:]
        for entry in entries {
            guard let separator = entry.firstIndex(of: "=") else {
                throw SimToolError("Launch environment entries must use KEY=VALUE format: \(entry)")
            }
            let key = String(entry[..<separator])
            let value = String(entry[entry.index(after: separator)...])
            guard isValidEnvironmentKey(key) else {
                throw SimToolError("Launch environment keys must be non-empty and contain only letters, numbers, and underscores: \(key)")
            }
            environment[key] = value
        }
        return environment
    }

    public static func simctlChildEnvironment(
        launchEnvironment: [String: String],
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        for (key, value) in launchEnvironment {
            environment["SIMCTL_CHILD_\(key)"] = value
        }
        return environment
    }

    public static func bundleIdentifier(appBundleURL: URL) throws -> String {
        let infoPlistURL = appBundleURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL) else {
            throw SimToolError("Unable to read Info.plist for app bundle: \(appBundleURL.path)")
        }
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = value as? [String: Any], let bundleIdentifier = dictionary["CFBundleIdentifier"] as? String, !bundleIdentifier.isEmpty else {
            throw SimToolError("Unable to determine CFBundleIdentifier for app bundle: \(appBundleURL.path)")
        }
        return bundleIdentifier
    }

    private static func builtProduct(selection: SimulatorAppBuildSelection, derivedDataPath: String) async throws -> XcodeBuildProduct {
        let settingsArguments = xcodebuildArguments(selection: selection, derivedDataPath: derivedDataPath, showBuildSettings: true)
        let settingsOutput = try await ProcessRunner.runXcrun(settingsArguments)
        if settingsOutput.status == 0, let product = try? parseBuildSettings(settingsOutput.stdout) {
            return product
        }
        if let fallback = findAppBundle(in: URL(fileURLWithPath: derivedDataPath), configuration: selection.identity.configuration) {
            return XcodeBuildProduct(appBundleURL: fallback)
        }
        let detail = settingsOutput.stderrString.isEmpty ? settingsOutput.stdoutString : settingsOutput.stderrString
        throw SimToolError("Unable to locate built .app for scheme \(selection.identity.scheme): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    private static func parseBuildSettings(_ data: Data) throws -> XcodeBuildProduct {
        let decoded = try JSONDecoder().decode([XcodeBuildSettingsEntry].self, from: data)
        for entry in decoded {
            guard let targetBuildDir = entry.buildSettings["TARGET_BUILD_DIR"],
                  let fullProductName = entry.buildSettings["FULL_PRODUCT_NAME"],
                  fullProductName.hasSuffix(".app")
            else { continue }
            let appURL = URL(fileURLWithPath: targetBuildDir).appendingPathComponent(fullProductName)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return XcodeBuildProduct(appBundleURL: appURL)
            }
        }
        throw SimToolError("xcodebuild settings did not include a built .app product")
    }

    private static func findAppBundle(in derivedDataURL: URL, configuration: String) -> URL? {
        let products = derivedDataURL.appendingPathComponent("Build/Products", isDirectory: true)
        let preferred = products.appendingPathComponent("\(configuration)-iphonesimulator", isDirectory: true)
        return newestAppBundle(in: preferred) ?? newestAppBundle(in: products)
    }

    private static func newestAppBundle(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return nil }
        var candidates: [(url: URL, date: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "app" {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            candidates.append((url, date))
            enumerator.skipDescendants()
        }
        return candidates.sorted { $0.date > $1.date }.first?.url
    }

    private static func installApp(deviceUDID: String, appBundlePath: String, timeoutSeconds: TimeInterval?) async throws -> SimulatorAppProcessStepSummary {
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "install", deviceUDID, appBundlePath],
            timeoutSeconds: timeoutSeconds
        )
        let step = SimulatorAppProcessStepSummary(name: "simctl install", output: output)
        guard output.status == 0 else {
            let detail = output.stderrString.isEmpty ? output.stdoutString : output.stderrString
            throw SimToolError("simctl install failed for \(appBundlePath): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return step
    }

    private static func launchApp(
        deviceUDID: String,
        bundleIdentifier: String,
        launchEnvironment: [String: String],
        launchArguments: [String] = [],
        timeoutSeconds: TimeInterval?
    ) async throws -> SimulatorAppProcessStepSummary {
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: simctlLaunchArguments(
                deviceUDID: deviceUDID,
                bundleIdentifier: bundleIdentifier,
                launchArguments: launchArguments
            ),
            environment: launchEnvironment.isEmpty ? nil : simctlChildEnvironment(launchEnvironment: launchEnvironment),
            timeoutSeconds: timeoutSeconds
        )
        return SimulatorAppProcessStepSummary(name: "simctl launch", output: output)
    }

    /// Internal rather than private: the project-config loader validates
    /// `profiles[].env` keys against the same rule the CLI's `--env` uses.
    static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        for scalar in key.unicodeScalars {
            let value = scalar.value
            let isLetter = (65...90).contains(value) || (97...122).contains(value)
            let isNumber = (48...57).contains(value)
            guard isLetter || isNumber || value == 95 else { return false }
        }
        return true
    }

    private static func isMissingInstallLaunchFailure(_ step: SimulatorAppProcessStepSummary) -> Bool {
        let text = (step.stdout + "\n" + step.stderr).lowercased()
        return text.contains("not installed") || text.contains("no such application") || text.contains("could not be found")
    }
}

private struct XcodeBuildProduct: Equatable {
    var appBundleURL: URL
}

private struct XcodeBuildSettingsEntry: Decodable {
    var buildSettings: [String: String]
}

private extension URL {
    func pathRelative(to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + (path == rootPath ? 0 : 1)))
    }
}
