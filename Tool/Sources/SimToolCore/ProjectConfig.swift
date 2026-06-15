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
        case simulator, bundleId, build, server, deeplinks, networkLogger, stateLogger
    }

    public init(
        simulator: String,
        bundleId: String,
        build: Build,
        server: Server = Server(),
        deeplinks: [Deeplink] = [],
        networkLogger: Bool = true,
        stateLogger: Bool = true,
        sourcePath: String = ""
    ) {
        self.simulator = simulator
        self.bundleId = bundleId
        self.build = build
        self.server = server
        self.deeplinks = deeplinks
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

    public func buildSelection() throws -> SimulatorAppBuildSelection {
        try build.selection()
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

    static func locate(explicitPath: String?, startDirectory: URL) throws -> URL {
        if let explicitPath, !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = NSString(string: explicitPath).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SimToolError("Project config not found at \(url.path).")
            }
            return url
        }

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
        throw SimToolError("No \(displayPath) found in the current directory or any parent. Create one or pass --config <path>.")
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
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
