import Foundation
import Yams

/// A local, gitignored per-project config (`.simtool/config.yml`) describing a single
/// app profile: which simulator to drive, which app to launch, how to build it,
/// optional viewer settings, and a named list of deeplinks.
public struct ProjectConfig: Codable, Equatable, Sendable {
    public struct Build: Codable, Equatable, Sendable {
        public var workspace: String?
        public var project: String?
        public var scheme: String
        public var configuration: String?
        public var derivedDataPath: String?

        public init(
            workspace: String? = nil,
            project: String? = nil,
            scheme: String,
            configuration: String? = nil,
            derivedDataPath: String? = nil
        ) {
            self.workspace = workspace
            self.project = project
            self.scheme = scheme
            self.configuration = configuration
            self.derivedDataPath = derivedDataPath
        }

        /// Maps the config build block onto the shared build selection so build
        /// validation (workspace XOR project, required scheme, default
        /// configuration, path canonicalization) is reused, not reimplemented.
        public func selection() throws -> SimulatorAppBuildSelection {
            try SimulatorAppBuildSelection.validated(
                workspacePath: workspace,
                projectPath: project,
                scheme: scheme,
                configuration: configuration,
                derivedDataPath: derivedDataPath
            )
        }
    }

    public struct Server: Codable, Equatable, Sendable {
        public var host: String
        public var port: UInt16

        public init(host: String = "127.0.0.1", port: UInt16 = 3200) {
            self.host = host
            self.port = port
        }
    }

    public struct Deeplink: Codable, Equatable, Sendable, CustomStringConvertible {
        public var name: String
        public var url: String

        public init(name: String, url: String) {
            self.name = name
            self.url = url
        }

        public var description: String { "\(name)  —  \(url)" }
    }

    public var simulator: String
    public var bundleId: String
    public var build: Build
    public var server: Server
    public var deeplinks: [Deeplink]
    /// Named launch recipes (`profiles:`) a test refers to by name, sorted by
    /// name. They keep app-specific argv — accounts, environment switches, an
    /// app's UI-testing master switch — out of the tests themselves.
    public var profiles: [LaunchProfile]
    /// Whether `simtool run` enables the SimTool network logger for the launched
    /// app (`SIMTOOL_NETWORK_LOGGER` + `SIMTOOL_SERVER_URL`). Defaults to true;
    /// inert for apps that do not link SimToolNetworkLogger.
    public var networkLogger: Bool
    /// Whether `simtool run` enables the SimTool state logger for the launched
    /// app (`SIMTOOL_STATE_LOGGER` + `SIMTOOL_SERVER_URL`). Defaults to true;
    /// inert for apps that do not link SimToolStateLogger.
    public var stateLogger: Bool
    /// Absolute path of the loaded config file. Populated by the loader; not part
    /// of the YAML schema.
    public var sourcePath: String

    private enum CodingKeys: String, CodingKey {
        case simulator, bundleId, build, server, deeplinks, profiles, networkLogger, stateLogger
    }

    public init(
        simulator: String,
        bundleId: String,
        build: Build,
        server: Server = Server(),
        deeplinks: [Deeplink] = [],
        profiles: [LaunchProfile] = [],
        networkLogger: Bool = true,
        stateLogger: Bool = true,
        sourcePath: String = ""
    ) {
        self.simulator = simulator
        self.bundleId = bundleId
        self.build = build
        self.server = server
        self.deeplinks = deeplinks
        self.profiles = profiles
        self.networkLogger = networkLogger
        self.stateLogger = stateLogger
        self.sourcePath = sourcePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        simulator = try container.decode(String.self, forKey: .simulator)
        bundleId = try container.decode(String.self, forKey: .bundleId)
        build = try container.decode(Build.self, forKey: .build)
        server = try container.decodeIfPresent(Server.self, forKey: .server) ?? Server()
        deeplinks = try container.decodeIfPresent([Deeplink].self, forKey: .deeplinks) ?? []
        profiles = try container.decodeIfPresent([LaunchProfile].self, forKey: .profiles) ?? []
        networkLogger = try container.decodeIfPresent(Bool.self, forKey: .networkLogger) ?? true
        stateLogger = try container.decodeIfPresent(Bool.self, forKey: .stateLogger) ?? true
        sourcePath = ""
    }

    /// The base URL the launched app should post network events to: the run
    /// server, addressed from inside the simulator (which shares host loopback).
    public var appFacingServerURL: String {
        let host = (server.host.isEmpty || server.host == "0.0.0.0") ? "127.0.0.1" : server.host
        return "http://\(host):\(server.port)"
    }

    /// The directory the config was loaded from — the project's `.simtool`
    /// directory. Everything else project-scoped (build checksum metadata,
    /// test sessions) anchors here. For an explicit `--config <path>`, the
    /// file's parent directory plays this role.
    public var simtoolDirectory: URL {
        URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
    }

    /// The project checkout's own path, for comparing "is this the same
    /// project" across a session file, a freshly loaded config, and a
    /// recorded test run — computed once here so the three call sites cannot
    /// drift into comparing different strings for the same directory.
    ///
    /// Resolves symlinks rather than merely standardizing: on macOS `/tmp` is
    /// itself a symlink to `/private/tmp`, so a checkout reached through one
    /// spelling must still match a session recorded through the other.
    /// Resolving both sides of a comparison can only turn a false "foreign
    /// project" into a correct match — it cannot break a match that already
    /// held.
    public var projectRoot: String {
        simtoolDirectory.deletingLastPathComponent().resolvingSymlinksInPath().path
    }

    public func buildSelection() throws -> SimulatorAppBuildSelection {
        try build.selection()
    }

    /// Looks up a configured launch profile by name, throwing a clear error that
    /// lists the available names on a miss — a test naming a profile that does
    /// not exist must say so, not launch with no arguments at all.
    public func profile(named name: String) throws -> LaunchProfile {
        guard let match = profiles.first(where: { $0.name == name }) else {
            throw SimToolError(ProjectConfig.unknownProfileMessage(name: name, profiles: profiles))
        }
        return match
    }

    /// The "unknown launch profile" wording, factored out so a pre-flight check
    /// that only has a profile list (not a full `ProjectConfig`) — a test's
    /// `launch.profile` checked before the simulator is touched — reports the
    /// same message as this lookup would, rather than a second phrasing of the
    /// same fact.
    public static func unknownProfileMessage(name: String, profiles: [LaunchProfile]) -> String {
        let available = profiles.map(\.name).joined(separator: ", ")
        let hint = available.isEmpty
            ? " No `profiles:` are defined in \(ProjectConfigLoader.displayPath)."
            : " Available: \(available)."
        return "Unknown launch profile '\(name)'.\(hint)"
    }

    /// Looks up a configured deeplink by name, throwing a clear error that lists
    /// the available names on a miss.
    public func deeplink(named name: String) throws -> Deeplink {
        guard let match = deeplinks.first(where: { $0.name == name }) else {
            let available = deeplinks.map(\.name).joined(separator: ", ")
            let hint = available.isEmpty ? "" : " Available: \(available)."
            throw SimToolError("Unknown deeplink '\(name)'.\(hint)")
        }
        return match
    }
}

/// Scaffolds a starter `.simtool/config.yml`: detects the Xcode container and
/// scheme where it can, and renders an annotated template the user finishes by
/// filling in the `# TODO` fields.
public enum ProjectConfigTemplate {
    public struct Detected: Equatable, Sendable {
        public var workspace: String?
        public var project: String?
        public var scheme: String?

        public init(workspace: String? = nil, project: String? = nil, scheme: String? = nil) {
            self.workspace = workspace
            self.project = project
            self.scheme = scheme
        }
    }

    /// Detects a single top-level `.xcworkspace` (preferred) or `.xcodeproj` in
    /// `directory`, plus a scheme from that container's shared schemes — the one
    /// matching the container's name, or the only one present.
    public static func detect(in directory: URL) -> Detected {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let names = entries.map { $0.lastPathComponent }.sorted()
        let workspace = names.first { $0.hasSuffix(".xcworkspace") }
        let project = workspace == nil ? names.first { $0.hasSuffix(".xcodeproj") } : nil

        var scheme: String?
        if let container = workspace ?? project {
            let containerBase = (container as NSString).deletingPathExtension
            let schemesDir = directory
                .appendingPathComponent(container, isDirectory: true)
                .appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
            let schemeNames = ((try? FileManager.default.contentsOfDirectory(atPath: schemesDir.path)) ?? [])
                .filter { $0.hasSuffix(".xcscheme") }
                .map { ($0 as NSString).deletingPathExtension }
                .sorted()
            scheme = schemeNames.first { $0 == containerBase } ?? (schemeNames.count == 1 ? schemeNames.first : nil)
        }
        return Detected(workspace: workspace, project: project, scheme: scheme)
    }

    public static func render(_ detected: Detected) -> String {
        let sourceLine: String
        if let workspace = detected.workspace {
            sourceLine = "  workspace: \(workspace)"
        } else if let project = detected.project {
            sourceLine = "  project: \(project)"
        } else {
            sourceLine = "  workspace: MyApp.xcworkspace    # or `project: MyApp.xcodeproj` (exactly one)"
        }
        let scheme = detected.scheme ?? "MyApp"
        let schemeComment = detected.scheme == nil ? "    # TODO: the app scheme to build" : ""

        return """
        # .simtool/config.yml — local, machine-specific SimTool config (this whole
        # directory is gitignored). See https://github.com/mstroshin/SimTool#readme.

        simulator: booted                 # UDID, name, or `booted` for the first booted simulator
        bundleId: com.example.app         # TODO: the launched app's bundle identifier

        build:
        \(sourceLine)
          scheme: \(scheme)\(schemeComment)
          configuration: Debug            # Debug | Beta | Release
          # derivedDataPath: ./DerivedData  # optional; unset → SimTool-managed build cache

        # deeplinks:                      # optional; open by name with `simtool open <name>`
        #   - name: Home
        #     url: myapp://home

        # profiles:                       # optional; named launch recipes a test refers to
        #   staging-account1:             #   by name (`launch: {profile: staging-account1}`)
        #     arguments: [-UITesting, -Environment, staging, -AutoLogin, "${ACCOUNT1}"]
        #     env: { SOME_FLAG: "1" }     #   exported to the app as SIMCTL_CHILD_*
        #     # deeplink: myapp://home    #   opened once the app is running
        #                                 # ${VAR} is read from your shell, so accounts and
        #                                 # secrets stay out of the file.

        """
    }
}

public enum ProjectConfigLoader {
    /// Project-relative location of the config file, for error messages.
    public static let displayPath = "\(SimToolDirectory.directoryName)/\(SimToolDirectory.configFileName)"

    /// Loads and validates the project config. When `explicitPath` is provided it
    /// is used verbatim (no upward search); otherwise the loader walks up from
    /// `startDirectory` looking for `.simtool/config.yml`.
    public static func load(
        explicitPath: String? = nil,
        startDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> ProjectConfig {
        let url = try locate(explicitPath: explicitPath, startDirectory: startDirectory)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SimToolError("Unable to read project config at \(url.path): \(error.localizedDescription)")
        }
        let raw: RawProjectConfig
        do {
            raw = try YAMLDecoder().decode(RawProjectConfig.self, from: text)
        } catch {
            throw SimToolError("Failed to parse \(url.path) as YAML: \(error.localizedDescription)")
        }
        return try make(from: raw, sourceURL: url)
    }

    /// Loads the project config when one is available. An absent config is not
    /// an error here (returns nil) so commands that merely default from the
    /// config can use it opportunistically — but a config that exists and fails
    /// to parse or validate still throws, and an explicit path must exist.
    public static func loadIfPresent(
        explicitPath: String? = nil,
        startDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> ProjectConfig? {
        if let explicitPath, !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try load(explicitPath: explicitPath, startDirectory: startDirectory)
        }
        guard search(startDirectory: startDirectory) != nil else { return nil }
        return try load(startDirectory: startDirectory)
    }

    static func locate(explicitPath: String?, startDirectory: URL) throws -> URL {
        if let explicitPath, !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = NSString(string: explicitPath).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SimToolError("Project config not found at \(url.path).")
            }
            return url
        }
        if let found = search(startDirectory: startDirectory) { return found }
        throw SimToolError("No \(displayPath) found in the current directory or any parent. Create one or pass --config <path>.")
    }

    static func search(startDirectory: URL) -> URL? {
        // Walk up using filesystem path strings rather than `URL` path manipulation: `NSString`'s
        // `deletingLastPathComponent` converges deterministically at the root ("/" -> "/"), whereas
        // `URL.deletingLastPathComponent()` does not reach a `.path` fixed point on newer Foundation
        // `URL` backends, which would loop forever.
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
        return nil
    }

    static func make(from raw: RawProjectConfig, sourceURL: URL) throws -> ProjectConfig {
        let fileName = sourceURL.lastPathComponent
        guard let simulator = raw.simulator?.trimmed, !simulator.isEmpty else {
            throw SimToolError("\(fileName) is missing required field `simulator`.")
        }
        guard let bundleId = raw.bundleId?.trimmed, !bundleId.isEmpty else {
            throw SimToolError("\(fileName) is missing required field `bundleId`.")
        }
        guard let rawBuild = raw.build else {
            throw SimToolError("\(fileName) is missing the required `build` block.")
        }
        guard let scheme = rawBuild.scheme?.trimmed, !scheme.isEmpty else {
            throw SimToolError("\(fileName) is missing required field `build.scheme`.")
        }

        // The config lives at `<project>/.simtool/config.yml`; relative paths
        // resolve against the project root, not the .simtool directory.
        let projectRoot = sourceURL.deletingLastPathComponent().deletingLastPathComponent()
        let build = ProjectConfig.Build(
            workspace: resolvePath(rawBuild.workspace, relativeTo: projectRoot),
            project: resolvePath(rawBuild.project, relativeTo: projectRoot),
            scheme: scheme,
            configuration: rawBuild.configuration?.trimmed,
            derivedDataPath: resolvePath(rawBuild.derivedDataPath, relativeTo: projectRoot)
        )
        // Reuse the shared build-selection validation (workspace XOR project).
        _ = try build.selection()

        var seenNames = Set<String>()
        var deeplinks: [ProjectConfig.Deeplink] = []
        for (index, rawLink) in (raw.deeplinks ?? []).enumerated() {
            guard let name = rawLink.name?.trimmed, !name.isEmpty else {
                throw SimToolError("Deeplink at index \(index) in \(fileName) is missing `name`.")
            }
            guard let url = rawLink.url?.trimmed, !url.isEmpty else {
                throw SimToolError("Deeplink '\(name)' in \(fileName) is missing `url`.")
            }
            guard seenNames.insert(name).inserted else {
                throw SimToolError("Duplicate deeplink name '\(name)' in \(fileName). Deeplink names must be unique.")
            }
            deeplinks.append(ProjectConfig.Deeplink(name: name, url: url))
        }

        // Profiles arrive as a YAML mapping, whose order is not preserved by
        // decoding; sort by name so listings and error hints are stable.
        var profiles: [LaunchProfile] = []
        for (name, rawProfile) in (raw.profiles ?? [:]).sorted(by: { $0.key < $1.key }) {
            let trimmedName = name.trimmed
            guard !trimmedName.isEmpty else {
                throw SimToolError("A launch profile in \(fileName) has an empty name.")
            }
            let deeplink = rawProfile.deeplink?.trimmed
            let profile = LaunchProfile(
                name: trimmedName,
                arguments: (rawProfile.arguments ?? []).map(\.text),
                environment: (rawProfile.env ?? [:]).reduce(into: [:]) { $0[$1.key] = $1.value.text },
                deeplink: deeplink?.isEmpty == false ? deeplink : nil
            )
            for key in profile.environment.keys where !SimulatorAppLifecycleClient.isValidEnvironmentKey(key) {
                throw SimToolError("Launch profile '\(trimmedName)' in \(fileName) has an invalid `env` key '\(key)'. Keys may contain only letters, numbers and underscores.")
            }
            profiles.append(profile)
        }

        let host = raw.server?.host?.trimmed
        let server = ProjectConfig.Server(
            host: (host?.isEmpty == false ? host! : "127.0.0.1"),
            port: raw.server?.port.map { UInt16(clamping: $0) } ?? 3200
        )

        return ProjectConfig(
            simulator: simulator,
            bundleId: bundleId,
            build: build,
            server: server,
            deeplinks: deeplinks,
            profiles: profiles,
            networkLogger: raw.networkLogger ?? true,
            stateLogger: raw.stateLogger ?? true,
            sourcePath: sourceURL.path
        )
    }

    private static func resolvePath(_ value: String?, relativeTo base: URL) -> String? {
        guard let trimmed = value?.trimmed, !trimmed.isEmpty else { return nil }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return base.appendingPathComponent(expanded).standardizedFileURL.path
    }
}

/// Permissive decoding shape: every field is optional so the loader can raise
/// precise, field-named validation errors rather than opaque decode failures.
struct RawProjectConfig: Decodable {
    var simulator: String?
    var bundleId: String?
    var build: RawBuild?
    var server: RawServer?
    var deeplinks: [RawDeeplink]?
    var profiles: [String: RawLaunchProfile]?
    var networkLogger: Bool?
    var stateLogger: Bool?

    struct RawBuild: Decodable {
        var workspace: String?
        var project: String?
        var scheme: String?
        var configuration: String?
        var derivedDataPath: String?
    }

    struct RawServer: Decodable {
        var host: String?
        var port: Int?
    }

    struct RawDeeplink: Decodable {
        var name: String?
        var url: String?
    }

    /// `arguments` and `env` values decode through `YAMLScalarText` because argv
    /// is text: `-RemoteConfig some_flag true` must not lose `true` to YAML's
    /// Bool typing.
    struct RawLaunchProfile: Decodable {
        var arguments: [YAMLScalarText]?
        var env: [String: YAMLScalarText]?
        var deeplink: String?
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
