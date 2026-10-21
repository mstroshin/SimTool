import Foundation

/// An installed app as the simulator knows it: what the viewer's app card and
/// `simtool app info` show.
public struct SimulatorAppInfo: Codable, Equatable, Sendable {
    public var bundleId: String
    public var installed: Bool
    public var name: String?
    public var version: String?
    public var build: String?
    /// `MinimumOSVersion` from its Info.plist.
    public var minimumOS: String?
    /// The running process, when it runs.
    public var pid: Int?
    /// The `.app` bundle on the Mac.
    public var bundlePath: String?
    /// Its data container (Documents, Library, tmp) on the Mac.
    public var dataContainer: String?
    /// `SimulatorPermissionClient.read`: each permission's state.
    public var permissions: [String: String]?

    public init(bundleId: String, installed: Bool, name: String? = nil, version: String? = nil, build: String? = nil, minimumOS: String? = nil, pid: Int? = nil, bundlePath: String? = nil, dataContainer: String? = nil, permissions: [String: String]? = nil) {
        self.bundleId = bundleId
        self.installed = installed
        self.name = name
        self.version = version
        self.build = build
        self.minimumOS = minimumOS
        self.pid = pid
        self.bundlePath = bundlePath
        self.dataContainer = dataContainer
        self.permissions = permissions
    }
}

public enum SimulatorAppInfoClient {
    /// The app's card. An app that is not installed answers `installed:
    /// false` rather than failing.
    public static func read(bundleId: String, deviceUDID: String, permissions: Bool = false) async throws -> SimulatorAppInfo {
        try SimulatorPermissionClient.check(bundleId)
        let output = try await ProcessRunner.runXcrun(["simctl", "appinfo", deviceUDID, bundleId])
        guard output.status == 0 else {
            if output.stderrString.contains("No application record") || output.stderrString.contains("Application not found") {
                return SimulatorAppInfo(bundleId: bundleId, installed: false)
            }
            throw SimToolError("simctl appinfo failed: " + output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var info = parse(appinfo: output.stdout, bundleId: bundleId)
        if let path = info.bundlePath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Info.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            info.minimumOS = plist["MinimumOSVersion"] as? String
        }
        info.pid = await pid(bundleId: bundleId, deviceUDID: deviceUDID)
        if permissions { info.permissions = try? await SimulatorPermissionClient.read(bundleId: bundleId, deviceUDID: deviceUDID) }
        return info
    }

    /// `simctl appinfo` prints an old-style plist; its paths are file URLs.
    static func parse(appinfo data: Data, bundleId: String) -> SimulatorAppInfo {
        let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
        func path(_ key: String) -> String? {
            guard let value = plist[key] as? String else { return nil }
            let path = URL(string: value).flatMap { $0.isFileURL ? $0.path : nil } ?? value
            return path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        }
        return SimulatorAppInfo(
            bundleId: bundleId,
            installed: true,
            name: (plist["CFBundleDisplayName"] ?? plist["CFBundleName"]) as? String,
            version: plist["CFBundleShortVersionString"] as? String,
            build: plist["CFBundleVersion"] as? String,
            bundlePath: path("Path") ?? path("Bundle"),
            dataContainer: path("DataContainer")
        )
    }

    public static func isRunning(bundleId: String, deviceUDID: String) async -> Bool {
        await pid(bundleId: bundleId, deviceUDID: deviceUDID) != nil
    }

    /// The pid of the app's `UIKitApplication:<bundle id>[…]` job, if it runs.
    static func pid(bundleId: String, deviceUDID: String) async -> Int? {
        guard let output = try? await ProcessRunner.runXcrun(["simctl", "spawn", deviceUDID, "launchctl", "list"]), output.status == 0 else { return nil }
        return pid(inLaunchctlList: output.stdoutString, bundleId: bundleId)
    }

    static func pid(inLaunchctlList text: String, bundleId: String) -> Int? {
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 3, fields[2].hasPrefix("UIKitApplication:\(bundleId)[") else { continue }
            return Int(fields[0])
        }
        return nil
    }

    /// Shows the app's bundle or its data container in the Finder of the Mac
    /// the simulator runs on.
    public static func reveal(_ what: String, bundleId: String, deviceUDID: String) async throws -> String {
        let info = try await read(bundleId: bundleId, deviceUDID: deviceUDID)
        guard info.installed else { throw SimToolError("\(bundleId) is not installed on this simulator") }
        let path: String? = switch what.lowercased() {
        case "bundle", "app": info.bundlePath
        case "data", "container": info.dataContainer
        default: throw SimToolError("Reveal takes bundle or data, not \(what)")
        }
        guard let path else { throw SimToolError("The simulator did not say where \(bundleId)'s \(what) is") }
        try SimulatorDeviceControl.check(await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-R", path]), what: "open -R")
        return path
    }
}

/// Installs an app from what a person has: a `.app` bundle, an `.ipa` (a zip
/// holding `Payload/<name>.app`), or a tar of a `.app` — what the viewer
/// builds from a bundle dropped on the screen, since a browser uploads files,
/// not folders.
public enum SimulatorAppInstaller {
    public struct Installed: Codable, Equatable, Sendable {
        public var bundleId: String
        public var name: String

        public init(bundleId: String, name: String) {
            self.bundleId = bundleId
            self.name = name
        }
    }

    public static func install(_ file: URL, deviceUDID: String) async throws -> Installed {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            throw SimToolError("\(file.path) does not exist")
        }
        if isDirectory.boolValue {
            guard file.pathExtension == "app" else { throw SimToolError("\(file.lastPathComponent) is a folder but not an .app bundle") }
            return try await installBundle(file, deviceUDID: deviceUDID)
        }
        let unpacked = FileManager.default.temporaryDirectory.appendingPathComponent("simtool-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        let unpack: (URL, [String]) = try kind(of: file) == "zip"
            ? (URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", file.path, unpacked.path])
            : (URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", file.path, "-C", unpacked.path])
        try SimulatorDeviceControl.check(await ProcessRunner.run(executable: unpack.0, arguments: unpack.1, timeoutSeconds: 300), what: "Unpacking \(file.lastPathComponent)")
        guard let bundle = findApp(in: unpacked) else {
            throw SimToolError("\(file.lastPathComponent) holds no .app bundle")
        }
        return try await installBundle(bundle, deviceUDID: deviceUDID)
    }

    /// zip (an `.ipa`) or tar, by the file's first bytes.
    static func kind(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 262) ?? Data()
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip" }
        if head.count >= 262, String(decoding: head[257..<262], as: UTF8.self) == "ustar" { return "tar" }
        throw SimToolError("\(file.lastPathComponent) is neither an .ipa nor an .app")
    }

    /// `Payload/<name>.app` of an ipa, or the `.app` at the top of a tar.
    static func findApp(in directory: URL) -> URL? {
        for candidate in [directory.appendingPathComponent("Payload"), directory] {
            let entries = (try? FileManager.default.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil)) ?? []
            if let app = entries.first(where: { $0.pathExtension == "app" }) { return app }
        }
        return nil
    }

    private static func installBundle(_ bundle: URL, deviceUDID: String) async throws -> Installed {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleId = plist["CFBundleIdentifier"] as? String else {
            throw SimToolError("\(bundle.lastPathComponent) has no Info.plist with a bundle identifier")
        }
        if let platforms = plist["CFBundleSupportedPlatforms"] as? [String], !platforms.contains("iPhoneSimulator") {
            throw SimToolError("\(bundle.lastPathComponent) is built for \(platforms.joined(separator: ", ")), not the simulator")
        }
        try SimulatorDeviceControl.check(await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["simctl", "install", deviceUDID, bundle.path], timeoutSeconds: 300), what: "simctl install")
        let name = (plist["CFBundleDisplayName"] ?? plist["CFBundleName"]) as? String ?? bundle.deletingPathExtension().lastPathComponent
        return Installed(bundleId: bundleId, name: name)
    }
}
