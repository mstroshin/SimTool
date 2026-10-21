import Foundation

/// What `simtool doctor` says about driving an iPhone Duo: a runtime that can
/// run one, and, for each booted one, whether Device Hub has taken its input.
public enum FoldableReadiness {
    public static let duoDeviceType = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
    /// Published by the guest while the simulator's HID daemon (dtuhidd) owns
    /// input, which Device Hub starts.
    static let deviceHubInputKey = "com.apple.coredevice.dtuhidd.active"

    public struct Check: Codable, Equatable, Sendable {
        public var name: String
        public var available: Bool
        public var detail: String
    }

    /// The installed runtimes a device type runs on, from
    /// `simctl list runtimes --json`. An iPhone Duo runs only on its own
    /// device-specific runtime (`iOS-27-2-iPhone19-4`), never the generic one.
    static func runtimes(supporting deviceType: String, inRuntimes data: Data) -> [String] {
        struct List: Decodable {
            struct Runtime: Decodable {
                struct DeviceType: Decodable { var identifier: String }
                var identifier: String
                var name: String?
                var isAvailable: Bool?
                var supportedDeviceTypes: [DeviceType]?
            }
            var runtimes: [Runtime]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
        return list.runtimes
            .filter { $0.isAvailable != false && ($0.supportedDeviceTypes ?? []).contains { $0.identifier == deviceType } }
            .map { runtime in runtime.name.map { "\($0) (\(runtime.identifier))" } ?? runtime.identifier }
    }

    /// `notifyutil -g …dtuhidd.active` prints `<key> 1` while dtuhidd owns
    /// input, `<key> 0` when it does not; nil when the guest publishes no state.
    static func isInputShadowed(notifyutil output: String) -> Bool? {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2, parts[0] == deviceHubInputKey, let value = Int(parts[1]) else { return nil }
        return value != 0
    }

    /// The 3D preview: the device model in the selected Xcode, loaded the way
    /// the preview loads it (`simtool duo-render --check`, run as
    /// `executable`) — its fold animation and screens present.
    public static func previewCheck(executable: URL, developerDir: String) async -> Check {
        let name = "iPhone Duo 3D preview"
        let layout = await SimulatorDisplayLayout.load(deviceType: duoDeviceType)
        let located = Duo3DModel.locate(layout: layout, developerDir: developerDir)
        guard let model = located.url else {
            return Check(name: name, available: false, detail: (located.reason ?? "no device model") + " — the viewer shows the flat screen")
        }
        let output = try? await ProcessRunner.run(executable: executable, arguments: ["duo-render", "--check", "--model", model.path], timeoutSeconds: 60)
        guard let output, output.status == 0 else {
            let said = output?.stderrString.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Check(name: name, available: false, detail: "\(model.path) does not render: \(said.isEmpty ? "the renderer failed" : said) — the viewer shows the flat screen")
        }
        return Check(name: name, available: true, detail: model.path)
    }

    public static func runtimeCheck() async -> Check {
        let name = "iPhone Duo runtime"
        guard let output = try? await ProcessRunner.runXcrun(["simctl", "list", "runtimes", "--json"]), output.status == 0 else {
            return Check(name: name, available: false, detail: "simctl list runtimes failed")
        }
        let runtimes = runtimes(supporting: duoDeviceType, inRuntimes: output.stdout)
        guard !runtimes.isEmpty else {
            return Check(name: name, available: false, detail: "no installed runtime runs an iPhone Duo — it needs Xcode 27.2's device-specific iOS 27.2 runtime, not the generic one")
        }
        return Check(name: name, available: true, detail: runtimes.joined(separator: ", "))
    }

    /// One check per booted foldable: Device Hub's HID daemon owning its input.
    /// SimTool's touches still reach it — they claim each panel's touch screen,
    /// and a screen iOS has stood down fails touches loudly — so this informs,
    /// it does not fail.
    public static func inputChecks(for devices: [SimulatorDevice]) async -> [Check] {
        var checks: [Check] = []
        for device in devices where device.state == "Booted" && device.deviceTypeIdentifier == duoDeviceType {
            let name = "Device Hub input (\(device.name))"
            let output = try? await ProcessRunner.runXcrun(["simctl", "spawn", device.udid, "notifyutil", "-g", deviceHubInputKey])
            switch output.flatMap({ isInputShadowed(notifyutil: $0.stdoutString) }) {
            case true?:
                checks.append(Check(name: name, available: true, detail: "dtuhidd owns HID input (\(deviceHubInputKey) = 1); SimTool's touches reconnect each panel's touch screen and fail with an error if iOS has stood one down"))
            case false?:
                checks.append(Check(name: name, available: true, detail: "legacy input (\(deviceHubInputKey) = 0)"))
            case nil:
                checks.append(Check(name: name, available: true, detail: "the runtime publishes no input state"))
            }
        }
        return checks
    }
}

/// Where the 3D preview of a foldable gets its model: the device model Xcode's
/// Device Hub draws it with, read from the user's own Xcode at run time —
/// never shipped with SimTool.
public enum Duo3DModel {
    /// `<Xcode>/Contents/SharedFrameworks/DeviceKit.framework/…/PlugIns/*.devicekitplugin/Contents/Resources/<product class>.usdz`.
    public static func url(productClass: String, developerDir: String) -> URL? {
        let plugins = URL(fileURLWithPath: developerDir)
            .deletingLastPathComponent()
            .appendingPathComponent("SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns")
        let fileManager = FileManager.default
        for plugin in (try? fileManager.contentsOfDirectory(atPath: plugins.path))?.sorted() ?? [] where plugin.hasSuffix(".devicekitplugin") {
            let model = plugins.appendingPathComponent(plugin).appendingPathComponent("Contents/Resources/\(productClass).usdz")
            if fileManager.fileExists(atPath: model.path) { return model }
        }
        return nil
    }

    /// The model for `layout`, or why there is none. RealityKit renders
    /// offscreen from macOS 15.
    public static func locate(layout: SimulatorDisplayLayout?, developerDir: String) -> (url: URL?, reason: String?) {
        guard let layout, layout.isFoldable else { return (nil, "only a foldable device has a 3D preview") }
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) else {
            return (nil, "the 3D preview renders with RealityKit, which needs macOS 15 or newer")
        }
        guard let productClass = layout.productClass else { return (nil, "the device type names no product class to find its model by") }
        guard let url = url(productClass: productClass, developerDir: developerDir) else {
            return (nil, "the selected Xcode (\(developerDir)) has no \(productClass).usdz device model — the iPhone Duo's ships with Xcode 27.1 and later")
        }
        return (url, nil)
    }
}
