import CryptoKit
import Foundation

/// What builds the app: `xcodebuild` on the command line, or Xcode itself
/// over its MCP tools (`xcrun mcpbridge`, see `XcodeMCPBuilder`).
public enum SimulatorAppBuilder: String, Codable, CaseIterable, Sendable {
    case xcodebuild
    case xcodeMCP = "xcode-mcp"
}

public struct SimulatorAppBuildIdentity: Codable, Equatable, Sendable {
    public var workspacePath: String?
    public var projectPath: String?
    public var scheme: String
    public var configuration: String
    public var sdk: String
    public var derivedDataPath: String?
    /// xcodebuild build settings passed on its command line, as `KEY=VALUE`
    /// sorted by key. Part of the identity, so a build with other settings
    /// never reuses this one's cache; nil (not empty) when there are none, so
    /// identities without settings keep the cache keys they always had.
    public var buildSettings: [String]?
    /// `xcode-mcp` for a build Xcode makes; nil for xcodebuild, so its
    /// identities keep the cache keys they always had. Part of the identity:
    /// Xcode builds with its own settings, so the two builders keep cache
    /// entries of their own — even when, as Xcode's build location settings
    /// may have it, both write the same `.app` (the product stamp tells).
    public var builder: SimulatorAppBuilder?

    public init(
        workspacePath: String? = nil,
        projectPath: String? = nil,
        scheme: String,
        configuration: String = "Debug",
        sdk: String = "iphonesimulator",
        derivedDataPath: String? = nil,
        buildSettings: [String]? = nil,
        builder: SimulatorAppBuilder? = nil
    ) {
        self.workspacePath = workspacePath
        self.projectPath = projectPath
        self.scheme = scheme
        self.configuration = configuration
        self.sdk = sdk
        self.derivedDataPath = derivedDataPath
        self.buildSettings = buildSettings
        self.builder = builder == .xcodebuild ? nil : builder
    }
}

public struct SimulatorAppBuildSelection: Codable, Equatable, Sendable {
    public var identity: SimulatorAppBuildIdentity
    /// Builds for this simulator only — its architecture — instead of any iOS
    /// simulator. Not part of the identity: the product is the same `.app`.
    public var deviceUDID: String?
    /// How long the build may run before it is stopped, in seconds: nil (not
    /// set) or 0 for as long as it takes. Not part of the identity.
    public var timeoutSeconds: TimeInterval?

    public init(identity: SimulatorAppBuildIdentity) throws {
        try Self.validate(identity)
        self.identity = identity
    }

    /// The time limit a build of this selection runs under, nil for none.
    /// A cold build of a large project, sharing the machine with other
    /// builds, can take well over an hour; stopping a build that is merely
    /// slow throws its work away, so there is no limit unless one is set.
    public var buildTimeLimit: TimeInterval? {
        timeoutSeconds.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Parses a build timeout: seconds (`2700`), or a number with an `s`,
    /// `m` or `h` unit (`45m`, `1.5h`). `0` means no limit.
    public static func parseTimeout(_ text: String) throws -> TimeInterval {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3_600]
        var number = Substring(trimmed)
        var multiplier: TimeInterval = 1
        if let last = trimmed.last, let unit = units[last] {
            number = number.dropLast()
            multiplier = unit
        }
        guard let value = TimeInterval(number), value.isFinite, value >= 0 else {
            throw SimToolError("Invalid build timeout '\(text)': use seconds or a number with s, m or h, as in 2700, 45m or 1.5h; 0 for no limit.")
        }
        return value * multiplier
    }

    /// This selection, built for `device` alone. Whatever installs the build on
    /// a simulator it has already resolved goes through here: the generic
    /// destination compiles every simulator architecture, which on a large
    /// project doubles a build that can already run for half an hour. The
    /// identity is untouched, so the cache entry is shared with builds for any
    /// other simulator, or for none.
    public func targeting(_ device: SimulatorDevice) -> SimulatorAppBuildSelection {
        var targeted = self
        targeted.deviceUDID = device.udid
        return targeted
    }

    public var builder: SimulatorAppBuilder {
        identity.builder ?? .xcodebuild
    }

    /// `xcode-mcp` takes no DerivedData path and no build settings: Xcode
    /// builds the project as it stands, into the DerivedData its own settings
    /// name. Asking for either is an error rather than a silent drop.
    public static func validated(
        workspacePath: String?,
        projectPath: String?,
        scheme: String?,
        configuration: String? = nil,
        derivedDataPath: String? = nil,
        buildSettings: [String: String] = [:],
        builder: SimulatorAppBuilder = .xcodebuild
    ) throws -> SimulatorAppBuildSelection {
        let trimmedScheme = scheme?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedConfiguration = configuration?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for key in buildSettings.keys where !isBuildSettingName(key) {
            throw SimToolError("Invalid build setting name '\(key)': use letters, digits and underscores, as in MACOSX_DEPLOYMENT_TARGET.")
        }
        if builder == .xcodeMCP {
            if canonicalPath(derivedDataPath) != nil {
                throw SimToolError("With builder xcode-mcp, Xcode builds into the DerivedData its own settings name: a DerivedData path applies to xcodebuild builds only.")
            }
            if !buildSettings.isEmpty {
                throw SimToolError("With builder xcode-mcp, Xcode builds the project with its own settings: build settings apply to xcodebuild builds only.")
            }
        }
        let identity = SimulatorAppBuildIdentity(
            workspacePath: canonicalPath(workspacePath),
            projectPath: canonicalPath(projectPath),
            scheme: trimmedScheme,
            configuration: trimmedConfiguration.isEmpty ? "Debug" : trimmedConfiguration,
            derivedDataPath: canonicalPath(derivedDataPath),
            buildSettings: buildSettings.isEmpty ? nil : buildSettings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" },
            builder: builder
        )
        return try SimulatorAppBuildSelection(identity: identity)
    }

    /// Parses repeated `--build-setting KEY=VALUE` entries; a later entry for
    /// the same key wins.
    public static func parseBuildSettings(_ entries: [String]) throws -> [String: String] {
        var settings: [String: String] = [:]
        for entry in entries {
            guard let separator = entry.firstIndex(of: "=") else {
                throw SimToolError("Build settings use KEY=VALUE format: \(entry)")
            }
            let key = String(entry[..<separator]).trimmingCharacters(in: .whitespaces)
            guard isBuildSettingName(key) else {
                throw SimToolError("Invalid build setting name '\(key)': use letters, digits and underscores, as in MACOSX_DEPLOYMENT_TARGET.")
            }
            settings[key] = String(entry[entry.index(after: separator)...])
        }
        return settings
    }

    static func isBuildSettingName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
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

    /// The one spelling of a path its identity keys on. Standardizing drops a
    /// leading `/private` only from a path that exists, so a DerivedData path
    /// not created yet would read otherwise than the same one after its first
    /// build, and key a cache entry of its own: the deepest existing ancestor
    /// is standardized, and the rest appended.
    static func canonicalPath(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let expanded = NSString(string: value).expandingTildeInPath
        var existing = URL(fileURLWithPath: expanded).absoluteURL.standardized
        var missing: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(existing.standardizedFileURL) { $0.appendingPathComponent($1) }.path
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

/// What a built `.app` is on disk: every file in the bundle by path, size and
/// modification time, digested. One `.app` path can be rebuilt behind a cache
/// entry's back — by a build with other settings, by Xcode, or by another
/// identity sharing the DerivedData — while the sources come back to the
/// checksum the entry was recorded for. The checksum alone would then hand out
/// someone else's build; the stamp says whether the bundle is still the one
/// that was built. Any rebuild relinks or re-signs, which rewrites files in
/// the bundle, so it changes the stamp; reading it is a stat per file.
public struct SimulatorAppProductStamp: Codable, Equatable, Sendable {
    public var digest: String
    public var fileCount: Int

    public init(digest: String, fileCount: Int) {
        self.digest = digest
        self.fileCount = fileCount
    }

    /// The stamp of the bundle at `appBundleURL`, or nil when there is no
    /// bundle directory there.
    public init?(appBundleURL: URL) {
        let root = appBundleURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(atPath: root.path)
        else { return nil }
        var entries: [String] = []
        for case let relativePath as String in enumerator {
            var info = stat()
            guard lstat(root.appendingPathComponent(relativePath).path, &info) == 0,
                  (info.st_mode & S_IFMT) != S_IFDIR
            else { continue }
            entries.append("\(relativePath)\0\(info.st_size)\0\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)")
        }
        entries.sort()
        let digest = SHA256.hash(data: Data(entries.joined(separator: "\n").utf8))
        self.init(digest: digest.map { String(format: "%02x", $0) }.joined(), fileCount: entries.count)
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
    /// The bundle that was installed. Nil in records written before SimTool
    /// stamped products, which therefore never match a build.
    public var product: SimulatorAppProductStamp?
    public var installedAt: Date

    public init(
        deviceUDID: String,
        checksum: String,
        bundleIdentifier: String,
        product: SimulatorAppProductStamp? = nil,
        installedAt: Date = Date()
    ) {
        self.deviceUDID = deviceUDID
        self.checksum = checksum
        self.bundleIdentifier = bundleIdentifier
        self.product = product
        self.installedAt = installedAt
    }
}

public struct SimulatorAppBuildCacheMetadata: Codable, Equatable, Sendable {
    public var identity: SimulatorAppBuildIdentity
    public var checksum: String
    public var inputFileCount: Int
    public var appBundlePath: String
    public var bundleIdentifier: String
    /// The bundle at `appBundlePath` as it was built. A cache hit needs the
    /// bundle to still be exactly this; nil (metadata from before SimTool
    /// stamped products) never hits.
    public var product: SimulatorAppProductStamp?
    public var builtAt: Date
    public var installRecords: [String: SimulatorAppInstallRecord]

    public init(
        identity: SimulatorAppBuildIdentity,
        checksum: String,
        inputFileCount: Int,
        appBundlePath: String,
        bundleIdentifier: String,
        product: SimulatorAppProductStamp? = nil,
        builtAt: Date = Date(),
        installRecords: [String: SimulatorAppInstallRecord] = [:]
    ) {
        self.identity = identity
        self.checksum = checksum
        self.inputFileCount = inputFileCount
        self.appBundlePath = appBundlePath
        self.bundleIdentifier = bundleIdentifier
        self.product = product
        self.builtAt = builtAt
        self.installRecords = installRecords
    }
}

public struct SimulatorAppBuildPayload: Codable, Equatable, Sendable {
    public var identity: SimulatorAppBuildIdentity
    public var checksum: String
    public var inputFileCount: Int
    public var cacheHit: Bool
    /// Whether a build ran — xcodebuild, or Xcode for `identity.builder`
    /// `xcode-mcp`; the name predates the second builder.
    public var xcodebuildRan: Bool
    public var appBundlePath: String
    public var bundleIdentifier: String
    /// The bundle at `appBundlePath`, as an install record keeps it.
    public var product: SimulatorAppProductStamp?
    /// The build's full log when one ran: xcodebuild's, written to
    /// `.simtool/build/<identity key>.log` and replaced by the next build of
    /// the same identity, or Xcode's own for `xcode-mcp`.
    public var logPath: String?
    /// The build step: xcodebuild's output (its end), or Xcode's
    /// `BuildProject` result.
    public var xcodebuild: SimulatorAppProcessStepSummary

    public init(
        identity: SimulatorAppBuildIdentity,
        checksum: String,
        inputFileCount: Int,
        cacheHit: Bool,
        xcodebuildRan: Bool,
        appBundlePath: String,
        bundleIdentifier: String,
        product: SimulatorAppProductStamp? = nil,
        logPath: String? = nil,
        xcodebuild: SimulatorAppProcessStepSummary
    ) {
        self.identity = identity
        self.checksum = checksum
        self.inputFileCount = inputFileCount
        self.cacheHit = cacheHit
        self.xcodebuildRan = xcodebuildRan
        self.appBundlePath = appBundlePath
        self.bundleIdentifier = bundleIdentifier
        self.product = product
        self.logPath = logPath
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
    /// The run's full log, `.simtool/build/<identity key>-test.log`.
    public var logPath: String?
    public var xcodebuild: SimulatorAppProcessStepSummary

    public init(
        identity: SimulatorAppBuildIdentity,
        device: SimulatorDevice,
        passed: Bool,
        xcodebuildRan: Bool,
        logPath: String? = nil,
        xcodebuild: SimulatorAppProcessStepSummary
    ) {
        self.identity = identity
        self.device = device
        self.passed = passed
        self.xcodebuildRan = xcodebuildRan
        self.logPath = logPath
        self.xcodebuild = xcodebuild
    }
}

public struct SimulatorAppBuildCache {
    /// Per-project checksum metadata: `<.simtool>/build/<identityKey>.json`.
    public var metadataRoot: URL
    /// Rebuildable xcodebuild products; kept out of the project tree because
    /// they can weigh gigabytes.
    public var derivedDataRoot: URL
    /// The build locks every SimTool process shares (`SimulatorAppBuildLock`):
    /// beside the managed DerivedData, `…/app-builds/locks`.
    public var lockRoot: URL

    public init(simtoolDirectory: URL, derivedDataRoot: URL = Self.defaultDerivedDataRoot(), lockRoot: URL? = nil) {
        self.metadataRoot = SimToolDirectory.buildMetadataDirectory(in: simtoolDirectory)
        self.derivedDataRoot = derivedDataRoot
        self.lockRoot = lockRoot ?? derivedDataRoot.deletingLastPathComponent().appendingPathComponent("locks", isDirectory: true)
    }

    /// Waits for, then holds, the locks of every directory a build of
    /// `selection` writes: its DerivedData, and the project's directory.
    func lockBuild(
        of selection: SimulatorAppBuildSelection,
        derivedDataPath: String?,
        onWait: (String) -> Void
    ) async throws -> (lock: SimulatorAppBuildLock, waited: Bool) {
        var waited = false
        let paths = [selection.projectRoot.standardizedFileURL.path, derivedDataPath].compactMap { $0 }
        let lock = try await SimulatorAppBuildLock.acquire(paths: paths, in: lockRoot) { message in
            waited = true
            onWait(message)
        }
        return (lock, waited)
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

    /// The content hashes of the project's input files, by their `stat`
    /// (`SimulatorAppInputHashCache`): one per project, whatever the identity.
    public var inputHashesURL: URL {
        metadataRoot.appendingPathComponent("input-hashes.tsv")
    }

    /// Where the full log of the last xcodebuild run of `identity` is kept,
    /// beside its metadata; each build replaces it.
    public func logURL(for identity: SimulatorAppBuildIdentity, action: String = "build") throws -> URL {
        let key = try identityKey(for: identity)
        return metadataRoot.appendingPathComponent(action == "build" ? "\(key).log" : "\(key)-\(action).log")
    }

    public func readMetadata(for identity: SimulatorAppBuildIdentity) -> SimulatorAppBuildCacheMetadata? {
        guard let url = try? metadataURL(for: identity), FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSON.decoder.decode(SimulatorAppBuildCacheMetadata.self, from: data)
    }

    /// The entry for `identity` when it was built from sources with this
    /// `checksum` and its bundle is still the one that build produced — not
    /// rebuilt since by anything else that writes to the same path.
    public func validMetadata(for identity: SimulatorAppBuildIdentity, checksum: String) -> SimulatorAppBuildCacheMetadata? {
        guard let metadata = readMetadata(for: identity), metadata.checksum == checksum,
              let recorded = metadata.product,
              SimulatorAppProductStamp(appBundleURL: URL(fileURLWithPath: metadata.appBundlePath)) == recorded
        else { return nil }
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
        product: SimulatorAppProductStamp? = nil,
        deviceUDID: String
    ) throws {
        guard var metadata = readMetadata(for: identity) else { return }
        metadata.installRecords[deviceUDID] = SimulatorAppInstallRecord(
            deviceUDID: deviceUDID,
            checksum: checksum,
            bundleIdentifier: bundleIdentifier,
            product: product
        )
        try write(metadata)
    }
}

public enum SimulatorAppBuildFingerprinter {
    /// The checksum of what a build of `selection` reads: its identity and
    /// every input file, by path, size and content. With `hashCache`, files
    /// whose `stat` is unchanged since the last fingerprint are not read
    /// again (`SimulatorAppInputHashCache`); the checksum is the same either way.
    public static func fingerprint(
        selection: SimulatorAppBuildSelection,
        cacheRoot: URL? = nil,
        hashCache: URL? = nil
    ) throws -> SimulatorAppBuildFingerprint {
        let files = try inputFiles(selection: selection, cacheRoot: cacheRoot)
        let started = Date()
        let known = hashCache.map(SimulatorAppInputHashCache.load) ?? SimulatorAppInputHashCache()
        var seen = SimulatorAppInputHashCache()
        var hasher = SHA256()
        try update(&hasher, with: JSON.data(selection.identity, pretty: false))
        for file in files {
            let status = SimulatorAppInputHashCache.Status(path: file.path)
            let contentHash: String
            if let status, let cached = known.hash(of: file.path, status: status) {
                contentHash = cached
            } else {
                contentHash = hex(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: file.path))))
            }
            if let status { seen.record(file.path, status: status, hash: contentHash) }
            update(&hasher, with: "\nfile:\(file.relativePath):\(file.byteCount):\(contentHash)\n")
        }
        if let hashCache {
            seen.writtenAt = started
            seen.write(to: hashCache)
        }
        return SimulatorAppBuildFingerprint(checksum: hex(hasher.finalize()), inputFileCount: files.count)
    }

    /// The files whose content the fingerprint hashes: the project's sources
    /// and resources, plus the Xcode containers the build reads — the
    /// workspace or project, and every project the workspace references —
    /// whether git tracks them or not.
    public static func inputFiles(selection: SimulatorAppBuildSelection, cacheRoot: URL? = nil) throws -> [SimulatorAppBuildInputFile] {
        // Paths are strings from here on: a large project lists tens of
        // thousands of files, and URL standardization goes to the disk.
        let root = selection.projectRoot.standardizedFileURL.path
        // Build products are never sources: SimTool's own DerivedData, and the
        // configured one wherever it lives — inside the project, under any name.
        let excludedRoots = [cacheRoot?.path, selection.identity.derivedDataPath]
            .compactMap { $0 }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        // When the project lives in a git work tree, hash only non-ignored files.
        // Generated artifacts (Tuist's `Derived/`, DerivedData, SPM checkouts)
        // are gitignored and derive from tracked inputs; they get rewritten on
        // builds and would otherwise destabilize the checksum, breaking cache
        // reuse. Outside git, fall back to the filesystem walk.
        var files = gitInputFiles(root: root, excludedRoots: excludedRoots)
            ?? walk(root, root: root, excludedRoots: excludedRoots)
        // A generated workspace or project is gitignored too, yet it is what
        // xcodebuild builds: the same generator inputs can produce another
        // project (generator flags, a binary cache, a generator update). Its
        // content is deterministic, so hashing it misses only when it changed.
        var seen = Set(files.map(\.path))
        for container in containers(of: selection) {
            for file in walk(container.path, root: root, excludedRoots: excludedRoots) where seen.insert(file.path).inserted {
                files.append(file)
            }
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    public static func sha256Hex(_ data: Data) throws -> String {
        hex(SHA256.hash(data: data))
    }

    /// The build-input files under `directory`, found by walking the
    /// filesystem; excluded directory names count from `directory` down.
    private static func walk(_ directory: String, root: String, excludedRoots: [String]) -> [SimulatorAppBuildInputFile] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return [] }
        var files: [SimulatorAppBuildInputFile] = []
        for case let below as String in enumerator {
            let path = directory + "/" + below
            let isDirectory = (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory
            if isExcluded(relativePath: below) || isUnder(path, anyOf: excludedRoots) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            let relativePath = relative(path, to: root)
            guard !isDirectory, isBuildInput(relativePath: relativePath), let byteCount = regularFileSize(atPath: path) else { continue }
            files.append(SimulatorAppBuildInputFile(relativePath: relativePath, path: path, byteCount: byteCount))
        }
        return files
    }

    /// Returns the build-input files known to git (tracked plus untracked but
    /// not ignored), or `nil` when `root` is not inside a git work tree (or git
    /// is unavailable) so the caller falls back to the filesystem walk. Listing
    /// via git is what excludes gitignored generated artifacts from the
    /// fingerprint; the walk's own exclusions — build directories by name, the
    /// DerivedData roots — and its type filter (`isBuildInput`) then apply
    /// as well, so a project whose `.gitignore` misses its DerivedData neither
    /// misses the cache forever nor hashes gigabytes of build products.
    private static func gitInputFiles(root: String, excludedRoots: [String]) -> [SimulatorAppBuildInputFile]? {
        // Ignored directories are not walked at all: excluded by name here,
        // and by path through pathspecs (relative to `root`, where git runs).
        var arguments = ["-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        arguments += excludedDirectoryNames.sorted().map { "--exclude=\($0)/" }
        arguments += ["--", "."]
        for excluded in excludedRoots {
            let below = relative(excluded, to: root)
            guard !below.hasPrefix("/"), !below.isEmpty else { continue }
            arguments.append(":(exclude,literal)\(below)")
        }
        guard let output = runGit(arguments), output.status == 0 else { return nil }

        var files: [SimulatorAppBuildInputFile] = []
        var seen = Set<String>()
        for listed in String(decoding: output.stdout, as: UTF8.self).split(separator: "\0") {
            let relativePath = String(listed)
            guard !relativePath.isEmpty, seen.insert(relativePath).inserted else { continue }
            let path = root + "/" + relativePath
            // Tracked files are listed whatever the exclusions say.
            if isExcluded(relativePath: relativePath) || isUnder(path, anyOf: excludedRoots) { continue }
            // Directories (submodules) and stale index entries (deleted or
            // renamed files) have no regular file to hash.
            guard isBuildInput(relativePath: relativePath), let byteCount = regularFileSize(atPath: path) else { continue }
            files.append(SimulatorAppBuildInputFile(relativePath: relativePath, path: path, byteCount: byteCount))
        }
        return files
    }

    /// The size of the regular file at `path`, links followed — what reading
    /// it reads; nil for anything else, or nothing.
    private static func regularFileSize(atPath path: String) -> Int64? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(info.st_size)
    }

    /// `path` below `root`, or `path` itself when it is not inside it.
    private static func relative(_ path: String, to root: String) -> String {
        if path == root { return "" }
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    /// The Xcode containers the build reads: the selected workspace or
    /// project, and for a workspace each project it references.
    static func containers(of selection: SimulatorAppBuildSelection) -> [URL] {
        let source = selection.sourceURL.standardizedFileURL
        guard selection.identity.workspacePath != nil else { return [source] }
        return [source] + workspaceProjects(source).filter { $0 != source }
    }

    /// The `.xcodeproj` references in a workspace's `contents.xcworkspacedata`,
    /// resolved the way Xcode resolves them: `group:` against the enclosing
    /// groups, `container:` against the workspace's directory, `absolute:` as
    /// is, `self:` as the project an embedded workspace belongs to.
    static func workspaceProjects(_ workspace: URL) -> [URL] {
        let data = workspace.appendingPathComponent("contents.xcworkspacedata")
        guard let parser = XMLParser(contentsOf: data) else { return [] }
        let collector = WorkspaceReferenceCollector(workspace: workspace)
        parser.delegate = collector
        parser.parse()
        var seen = Set<String>()
        return collector.projects.filter { seen.insert($0.path).inserted }
    }

    /// Runs git synchronously, returning its exit status and stdout, or `nil` if
    /// git could not be launched. stderr is discarded; stdout is drained before
    /// `waitUntilExit` to avoid pipe-buffer deadlock.
    private static func runGit(_ arguments: [String]) -> (status: Int32, stdout: Data)? {
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

    private static func update(_ hasher: inout SHA256, with data: Data) {
        hasher.update(data: data)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isUnder(_ path: String, anyOf roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Whether a path holds a build directory — counted from where the
    /// path is relative to.
    private static func isExcluded(relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { excludedDirectoryNames.contains(String($0)) }
    }

    /// Whether the file at `relativePath` (relative to the project root, or
    /// absolute outside it) is something a build reads.
    static func isBuildInput(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/")
        if components.contains(where: { buildPackageExtensions.contains(pathExtension($0)) }) { return true }
        guard let name = components.last else { return false }
        return includedFileNames.contains(String(name)) || includedExtensions.contains(pathExtension(name))
    }

    /// A name's extension, lowercased, as `URL.pathExtension` reads it:
    /// none for a dotfile (`.env`, `.bundle`).
    private static func pathExtension(_ name: Substring) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    private static let excludedDirectoryNames: Set<String> = [
        ".build", ".git", ".hg", ".svn", ".swiftpm", ".simtool", "Build", "build", "DerivedData", "xcuserdata"
    ]

    /// Directories whose every file is a build input: Xcode containers and
    /// catalogs, resource bundles and localizations, compiled or vendored
    /// bundles and frameworks.
    private static let buildPackageExtensions: Set<String> = [
        "bundle", "framework", "icon", "lproj", "mlmodelc", "mlpackage", "momd", "nib", "rcproject", "scnassets",
        "storyboardc", "xcassets", "xcdatamodel", "xcdatamodeld", "xcframework", "xcmappingmodel", "xcodeproj",
        "xcstickers", "xcworkspace"
    ]

    private static let includedFileNames: Set<String> = [
        ".env", "Package.resolved", "Package.swift", "Podfile", "Podfile.lock", "Cartfile", "Cartfile.private",
        "Cartfile.resolved", "project.pbxproj", "contents.xcworkspacedata"
    ]

    /// What a build compiles, links or copies into the app. Shell scripts are
    /// in, as what run-script phases run; documentation (`md`) is not, nor are
    /// scripts in other languages, mostly tooling whose edits would only cost
    /// rebuilds.
    private static let includedExtensions: Set<String> = [
        // Code, headers and build configuration
        "a", "c", "cc", "cpp", "cxx", "dylib", "entitlements", "h", "hh", "hpp", "hxx", "m", "metal", "mm",
        "modulemap", "pch", "s", "swift", "tbd", "xcconfig", "xcfilelist", "xcprivacy", "xcscheme", "sh",
        // Data, configuration and generated-code inputs
        "bin", "csv", "dat", "db", "geojson", "graphql", "intentdefinition", "json", "plist", "proto", "sqlite",
        "toml", "txt", "xalloc", "xml", "yaml", "yml",
        // Interface, localization and web content
        "css", "htm", "html", "js", "nib", "rtf", "storyboard", "strings", "stringsdict", "xcstrings", "xib",
        // Images, media, animations and fonts
        "aac", "aif", "aiff", "bmp", "caf", "gif", "heic", "heif", "jpeg", "jpg", "lottie", "m4a", "m4v", "mov",
        "mp3", "mp4", "otf", "pdf", "png", "riv", "svg", "tif", "tiff", "ttc", "ttf", "wav", "webp", "woff", "woff2",
        // Models, 3D, certificates
        "cer", "crt", "dae", "der", "mlmodel", "mom", "pem", "reality", "scn", "usdz", "xcdatamodel"
    ]
}

/// Collects the project references of a `contents.xcworkspacedata` — the
/// nested `Group`s carry the base `group:` locations resolve against.
private final class WorkspaceReferenceCollector: NSObject, XMLParserDelegate {
    private let containerDirectory: URL
    private let workspace: URL
    private var bases: [URL]
    private(set) var projects: [URL] = []

    init(workspace: URL) {
        self.workspace = workspace
        self.containerDirectory = workspace.deletingLastPathComponent()
        self.bases = [workspace.deletingLastPathComponent()]
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let location = attributes["location"].flatMap(resolve)
        switch element {
        case "Group":
            bases.append(location ?? bases[bases.count - 1])
        case "FileRef":
            if let location, location.pathExtension == "xcodeproj" { projects.append(location.standardizedFileURL) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "Group", bases.count > 1 { bases.removeLast() }
    }

    private func resolve(_ location: String) -> URL? {
        guard let colon = location.firstIndex(of: ":") else { return nil }
        let kind = location[..<colon]
        let path = String(location[location.index(after: colon)...])
        switch kind {
        case "group":
            return path.isEmpty ? bases[bases.count - 1] : bases[bases.count - 1].appendingPathComponent(path)
        case "container":
            return path.isEmpty ? containerDirectory : containerDirectory.appendingPathComponent(path)
        case "absolute":
            return URL(fileURLWithPath: path)
        case "self":
            return workspace.deletingLastPathComponent().pathExtension == "xcodeproj" ? workspace.deletingLastPathComponent() : nil
        default:
            return nil
        }
    }
}

/// The result of the checksum stage: the source fingerprint plus the resolved
/// cache decision, computed without running xcodebuild. A non-nil
/// `cachedMetadata` means a prior build of the same sources can be reused.
public struct SimulatorAppBuildPlan: Sendable {
    public var selection: SimulatorAppBuildSelection
    public var fingerprint: SimulatorAppBuildFingerprint
    public var derivedDataPath: String
    public var cachedMetadata: SimulatorAppBuildCacheMetadata?
    /// Planned with `force`: a build runs whatever the cache holds.
    public var forced: Bool

    public init(
        selection: SimulatorAppBuildSelection,
        fingerprint: SimulatorAppBuildFingerprint,
        derivedDataPath: String,
        cachedMetadata: SimulatorAppBuildCacheMetadata?,
        forced: Bool = false
    ) {
        self.selection = selection
        self.fingerprint = fingerprint
        self.derivedDataPath = derivedDataPath
        self.cachedMetadata = cachedMetadata
        self.forced = forced
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
        let fingerprint = try SimulatorAppBuildFingerprinter.fingerprint(
            selection: selection,
            cacheRoot: cache.derivedDataRoot,
            hashCache: cache.inputHashesURL
        )
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
            cachedMetadata: cachedMetadata,
            forced: force
        )
    }

    /// `progress` receives short build statuses ("Compiling Foo.swift") parsed
    /// from xcodebuild output. It is invoked on a background thread as output
    /// arrives; blocking inside it backpressures pipe reads. The build runs
    /// under the selection's time limit (`buildTimeLimit`).
    public static func build(
        selection: SimulatorAppBuildSelection,
        force: Bool = false,
        cache: SimulatorAppBuildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve()),
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SimulatorAppBuildPayload {
        let plan = try plan(selection: selection, force: force, cache: cache)
        return try await build(plan: plan, cache: cache, progress: progress)
    }

    /// Build stage: runs xcodebuild for a planned build, or returns a cache-hit
    /// payload instantly when `plan.cachedMetadata` is set. Pair with `plan`,
    /// passing the same `cache`.
    public static func build(
        plan: SimulatorAppBuildPlan,
        cache: SimulatorAppBuildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve()),
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
                product: metadata.product,
                xcodebuild: SimulatorAppProcessStepSummary(name: "xcodebuild", ran: false)
            )
        }

        // Xcode picks the DerivedData itself: the project's lock covers it.
        let lockedDerivedData = selection.builder == .xcodebuild ? plan.derivedDataPath : nil
        let (buildLock, waited) = try await cache.lockBuild(of: selection, derivedDataPath: lockedDerivedData) { message in
            report(message, to: progress)
        }
        defer { buildLock.release() }
        // The build waited for may have been of these very sources.
        if waited, !plan.forced, let metadata = cache.validMetadata(for: selection.identity, checksum: fingerprint.checksum) {
            return SimulatorAppBuildPayload(
                identity: selection.identity,
                checksum: fingerprint.checksum,
                inputFileCount: fingerprint.inputFileCount,
                cacheHit: true,
                xcodebuildRan: false,
                appBundlePath: metadata.appBundlePath,
                bundleIdentifier: metadata.bundleIdentifier,
                product: metadata.product,
                xcodebuild: SimulatorAppProcessStepSummary(name: "xcodebuild", ran: false)
            )
        }

        let previous = cache.readMetadata(for: selection.identity)
        let product: XcodeBuildProduct
        let buildStep: SimulatorAppProcessStepSummary
        let logPath: String?
        switch selection.builder {
        case .xcodebuild:
            let derivedDataPath = plan.derivedDataPath
            let buildArguments = xcodebuildArguments(selection: selection, derivedDataPath: derivedDataPath)
            let logURL = try cache.logURL(for: selection.identity)
            try SimToolDirectory.ensureEnclosing(cache.metadataRoot)
            let scanner = XcodebuildLogScanner(configuration: selection.identity.configuration)
            let onStdoutLine: @Sendable (String) -> Void = { line in
                scanner.consume(line)
                if let progress, let status = XcodebuildProgress.status(forLine: line) {
                    progress(status)
                }
            }
            let buildOutput: ProcessOutput
            do {
                buildOutput = try await ProcessRunner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                    arguments: buildArguments,
                    timeoutSeconds: selection.buildTimeLimit,
                    log: ProcessOutputLog(url: logURL),
                    onStdoutLine: onStdoutLine
                )
            } catch let timeout as ProcessTimeoutError {
                throw SimToolError("xcodebuild ran past the \(formatDuration(timeout.seconds)) time limit for scheme \(selection.identity.scheme) and was stopped; raise or lift it with build.timeout or --build-timeout (0 for no limit).\nFull log: \(logURL.path)")
            }
            buildStep = SimulatorAppProcessStepSummary(name: "xcodebuild", output: buildOutput)
            guard buildOutput.status == 0 else {
                let detail = XcodebuildFailure.detail(
                    stdoutErrorLines: scanner.failureLines,
                    stdoutTail: buildOutput.stdoutString,
                    stderr: buildOutput.stderrString
                )
                throw SimToolError("xcodebuild failed for scheme \(selection.identity.scheme): \(detail)\nFull log: \(logURL.path)")
            }
            product = try await builtProduct(
                selection: selection,
                derivedDataPath: derivedDataPath,
                logged: scanner.builtApps,
                previous: previous
            )
            logPath = logURL.path
        case .xcodeMCP:
            let outcome = try await XcodeMCPBuilder.build(
                selection: selection,
                device: try await device(udid: selection.deviceUDID),
                timeoutSeconds: selection.buildTimeLimit,
                progress: progress
            )
            try checkConfiguration(outcome.configuration, of: selection)
            buildStep = outcome.stepSummary
            product = XcodeBuildProduct(appBundleURL: outcome.appBundleURL)
            logPath = outcome.fullLogPath
        }

        let bundleIdentifier = try bundleIdentifier(appBundleURL: product.appBundleURL)
        let stamp = try productStamp(appBundleURL: product.appBundleURL)
        var metadata = SimulatorAppBuildCacheMetadata(
            identity: selection.identity,
            checksum: fingerprint.checksum,
            inputFileCount: fingerprint.inputFileCount,
            appBundlePath: product.appBundleURL.path,
            bundleIdentifier: bundleIdentifier,
            product: stamp
        )
        if let previous {
            metadata.installRecords = previous.installRecords.filter { $0.value.checksum == fingerprint.checksum && $0.value.product == stamp }
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
            product: stamp,
            logPath: logPath,
            xcodebuild: buildStep
        )
    }

    /// A status for whoever is watching: the progress line when there is one,
    /// else stderr — a `--json` run's stdout carries only its payload.
    static func report(_ message: String, to progress: (@Sendable (String) -> Void)?) {
        if let progress {
            progress(message)
        } else {
            FileHandle.standardError.write(Data("simtool: \(message)\n".utf8))
        }
    }

    /// `90m`, `1h 30m`, `45s`: a time limit as the error naming it reads.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3_600, minutes = total % 3_600 / 60, rest = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if rest > 0 || parts.isEmpty { parts.append("\(rest)s") }
        return parts.joined(separator: " ")
    }

    private static func productStamp(appBundleURL: URL) throws -> SimulatorAppProductStamp {
        guard let stamp = SimulatorAppProductStamp(appBundleURL: appBundleURL) else {
            throw SimToolError("App bundle not found: \(appBundleURL.path)")
        }
        return stamp
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
        let fingerprint = try SimulatorAppBuildFingerprinter.fingerprint(
            selection: selection,
            cacheRoot: cache.derivedDataRoot,
            hashCache: cache.inputHashesURL
        )
        let bundleIdentifier = try bundleIdentifier(appBundleURL: appBundleURL)
        let stamp = try productStamp(appBundleURL: appBundleURL)
        var metadata = SimulatorAppBuildCacheMetadata(
            identity: selection.identity,
            checksum: fingerprint.checksum,
            inputFileCount: fingerprint.inputFileCount,
            appBundlePath: appBundleURL.standardizedFileURL.path,
            bundleIdentifier: bundleIdentifier,
            product: stamp
        )
        // Drop install records of any other build: what a device has installed
        // matches the externally built app only when it is this very bundle.
        // A record of it (recording the same build twice) stays valid.
        if let previous = cache.readMetadata(for: selection.identity) {
            metadata.installRecords = previous.installRecords.filter { $0.value.checksum == fingerprint.checksum && $0.value.product == stamp }
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
            product: stamp,
            xcodebuild: SimulatorAppProcessStepSummary(name: "xcodebuild", ran: false)
        )
    }

    /// Builds for `device` only (see `SimulatorAppBuildSelection.targeting`),
    /// then installs and launches there. The build runs under the selection's
    /// time limit; `timeoutSeconds` bounds install and launch.
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
            selection: selection.targeting(device),
            force: force,
            cache: cache,
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
    /// the record was written for the previous bundle. Sources with the same
    /// checksum do not make the same bundle either — a build with other
    /// settings, or Xcode's, may have replaced it since — so the record must
    /// name this very `product`.
    public static func needsInstall(
        checksum: String,
        bundleIdentifier: String,
        product: SimulatorAppProductStamp?,
        installed: SimulatorAppInstallRecord?,
        xcodebuildRan: Bool,
        force: Bool
    ) -> Bool {
        guard let installed else { return true }
        return force
            || xcodebuildRan
            || installed.checksum != checksum
            || installed.bundleIdentifier != bundleIdentifier
            || product == nil
            || installed.product != product
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
            product: buildPayload.product,
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
            product: buildPayload.product,
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
            product: buildPayload.product,
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
                product: buildPayload.product,
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
                product: buildPayload.product,
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
        let destination = selection.deviceUDID.map { "platform=iOS Simulator,id=\($0)" } ?? "generic/platform=iOS Simulator"
        arguments += [
            "-scheme", selection.identity.scheme,
            "-configuration", selection.identity.configuration,
            "-destination", destination,
        ]
        if let derivedDataPath, !derivedDataPath.isEmpty {
            arguments += ["-derivedDataPath", derivedDataPath]
        }
        if !showBuildSettings {
            // Each run-script phase would otherwise print the whole build
            // environment, hundreds of lines a phase, into the log.
            arguments.append("-hideShellScriptEnvironment")
        }
        arguments += selection.identity.buildSettings ?? []
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
            "-destination", "platform=iOS Simulator,id=\(device.udid)",
        ]
        if let derivedDataPath, !derivedDataPath.isEmpty {
            arguments += ["-derivedDataPath", derivedDataPath]
        }
        arguments.append("-hideShellScriptEnvironment")
        arguments += selection.identity.buildSettings ?? []
        arguments.append("test")
        return arguments
    }

    /// Runs `xcodebuild test` under the selection's time limit.
    public static func test(
        selection: SimulatorAppBuildSelection,
        device: SimulatorDevice,
        cache: SimulatorAppBuildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve())
    ) async throws -> SimulatorAppTestPayload {
        let logURL = try cache.logURL(for: selection.identity, action: "test")
        try SimToolDirectory.ensureEnclosing(cache.metadataRoot)
        let (testLock, _) = try await cache.lockBuild(of: selection, derivedDataPath: selection.identity.derivedDataPath) { message in
            report(message, to: nil)
        }
        defer { testLock.release() }
        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: xcodebuildTestArguments(
                    selection: selection,
                    device: device,
                    derivedDataPath: selection.identity.derivedDataPath
                ),
                timeoutSeconds: selection.buildTimeLimit,
                log: ProcessOutputLog(url: logURL)
            )
        } catch let timeout as ProcessTimeoutError {
            throw SimToolError("xcodebuild test ran past the \(formatDuration(timeout.seconds)) time limit for scheme \(selection.identity.scheme) and was stopped; raise or lift it with build.timeout or --build-timeout (0 for no limit).\nFull log: \(logURL.path)")
        }
        let step = SimulatorAppProcessStepSummary(name: "xcodebuild test", output: output)
        return SimulatorAppTestPayload(
            identity: selection.identity,
            device: device,
            passed: output.status == 0,
            xcodebuildRan: true,
            logPath: logURL.path,
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

    /// The simulator a selection targets, for Xcode to match by name and OS
    /// version among its run destinations.
    private static func device(udid: String?) async throws -> SimulatorDevice? {
        guard let udid else { return nil }
        return try await SimulatorDeviceClient.listDevices().first { $0.udid == udid }
    }

    /// Xcode builds the scheme's Run configuration, whatever the selection
    /// asks for; a mismatch would cache, say, a Release app as the Debug one.
    static func checkConfiguration(_ built: String?, of selection: SimulatorAppBuildSelection) throws {
        let expected = selection.identity.configuration
        guard let built, !built.isEmpty, built != expected else { return }
        throw SimToolError("Xcode built scheme \(selection.identity.scheme) in its Run configuration \(built), not \(expected). Set the scheme's Run configuration to \(expected) in Xcode, or ask for configuration \(built).")
    }

    /// The `.app` a successful xcodebuild run produced. The build's own log
    /// says where it wrote it, whatever products root Xcode's build location
    /// settings chose — `-derivedDataPath` does not decide that on its own.
    /// A build with nothing to do writes nothing; then the bundle this
    /// identity's previous build made is still the product, provided nothing
    /// has rebuilt it since. Only when neither tells is xcodebuild asked for
    /// its build settings: a second run that loads the workspace again.
    static func builtProduct(
        selection: SimulatorAppBuildSelection,
        derivedDataPath: String,
        logged: [URL],
        previous: SimulatorAppBuildCacheMetadata?
    ) async throws -> XcodeBuildProduct {
        if let url = productInLog(logged, scheme: selection.identity.scheme, previous: previous) {
            return XcodeBuildProduct(appBundleURL: url)
        }
        if logged.isEmpty, let previous, let recorded = previous.product,
           SimulatorAppProductStamp(appBundleURL: URL(fileURLWithPath: previous.appBundlePath)) == recorded {
            return XcodeBuildProduct(appBundleURL: URL(fileURLWithPath: previous.appBundlePath))
        }
        return try await builtProductFromSettings(selection: selection, derivedDataPath: derivedDataPath)
    }

    /// The app among those the build log shows written: the one the previous
    /// build of this identity produced, by name; else the only one; else the
    /// one named after the scheme. Nil when that leaves more than one (an
    /// app with an App Clip, say) or none.
    static func productInLog(_ logged: [URL], scheme: String, previous: SimulatorAppBuildCacheMetadata?) -> URL? {
        let apps = logged.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        if let previous, let same = apps.first(where: { $0.lastPathComponent == URL(fileURLWithPath: previous.appBundlePath).lastPathComponent }) {
            return same
        }
        if apps.count == 1 { return apps[0] }
        let named = apps.filter { $0.lastPathComponent == "\(scheme).app" }
        return named.count == 1 ? named[0] : nil
    }

    private static func builtProductFromSettings(selection: SimulatorAppBuildSelection, derivedDataPath: String) async throws -> XcodeBuildProduct {
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
        // The simulator's camera, when SimTool has one on for this device.
        let launchEnvironment = SimulatorCamera.launchEnvironment(deviceUDID: deviceUDID, merging: launchEnvironment)
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

struct XcodeBuildProduct: Equatable {
    var appBundleURL: URL
}

private struct XcodeBuildSettingsEntry: Decodable {
    var buildSettings: [String: String]
}
