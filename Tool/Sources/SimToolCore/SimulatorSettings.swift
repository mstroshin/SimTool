import Foundation
import SimToolNetworkLogger

// The simulator's settings and debug switches that Simulator.app kept in its
// menus and Device Hub (Xcode 27) dropped or hid: the render server's debug
// colours, slowed animations, a memory warning, Face ID and Touch ID, a push,
// the appearance and text size, the status bar and the location. One request
// type (`DeviceControlPayload`) changes any of them — from the CLI, the HTTP
// API (`POST /api/v1/device`), the viewer and YAML steps — and one snapshot
// (`SimulatorSettings`) reads them back, so a viewer shows what the device
// says rather than what was last asked of it.

// MARK: - debug options

/// A switch of Simulator.app's old Debug menu.
public enum SimulatorDebugOption: String, CaseIterable, Codable, Sendable {
    case slowAnimations = "slow-animations"
    case colorBlended = "color-blended"
    case colorCopies = "color-copies"
    case colorMisaligned = "color-misaligned"
    case colorOffscreen = "color-offscreen"

    public var title: String {
        switch self {
        case .slowAnimations: "Slow Animations"
        case .colorBlended: "Color Blended Layers"
        case .colorCopies: "Color Copied Images"
        case .colorMisaligned: "Color Misaligned Images"
        case .colorOffscreen: "Color Off-screen Rendered"
        }
    }

    /// The guest render server's debug option, which CoreSimulator's
    /// `-[SimDevice setCADebugOption:enabled:]` forwards as a number to
    /// `CARenderServerSetDebugOption`: the place of its `CA_COLOR_*` name in
    /// QuartzCore's table — COPY 1, OPAQUE (blended layers) 2, SUBPIXEL
    /// (misaligned images) 14, OFFSCREEN 17. Checked by eye on iOS 26.4 and
    /// 27. Slowed animations are UIKit's, not the render server's.
    var renderServerOption: UInt32? {
        switch self {
        case .slowAnimations: nil
        case .colorCopies: 1
        case .colorBlended: 2
        case .colorMisaligned: 14
        case .colorOffscreen: 17
        }
    }

    /// UIKit in every app reads this darwin notification's state: non-zero
    /// slows its animations down, as Simulator.app's Slow Animations did.
    static let slowAnimationsNotification = "com.apple.UIKit.SimulatorSlowMotionAnimationState"

    /// Its name, or the words people use for it: `blended`, `copies`,
    /// `misaligned`, `offscreen`, `slow`.
    public init?(parsing raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        if let option = Self(rawValue: name) { self = option; return }
        switch name {
        case "slow", "slow-animation", "slowanimations": self = .slowAnimations
        case "blended", "blended-layers", "color-blended-layers": self = .colorBlended
        case "copies", "copied", "copied-images", "color-copied-images": self = .colorCopies
        case "misaligned", "misaligned-images", "color-misaligned-images": self = .colorMisaligned
        case "offscreen", "off-screen", "offscreen-rendered", "color-off-screen-rendered", "color-offscreen-rendered": self = .colorOffscreen
        default: return nil
        }
    }

    public static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }
}

// MARK: - appearance and text size

public enum SimulatorAppearance: String, CaseIterable, Codable, Sendable {
    case light, dark
}

/// The preferred content size category (Dynamic Type), as `simctl ui
/// content_size` names it.
public enum SimulatorContentSize {
    public static let sizes = [
        "extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
        "accessibility-medium", "accessibility-large", "accessibility-extra-large",
        "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large",
    ]

    /// iOS's own default.
    public static let standard = "large"

    /// A size, `increment` / `decrement` (one step), or their short forms:
    /// `xs`, `s`, `m`, `l`, `xl`, `xxl`, `xxxl`, `ax1`…`ax5`, `default`,
    /// `bigger`, `smaller`.
    public static func parse(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        if sizes.contains(name) || name == "increment" || name == "decrement" { return name }
        let short = ["xs", "s", "m", "l", "xl", "xxl", "xxxl", "ax1", "ax2", "ax3", "ax4", "ax5"]
        if let index = short.firstIndex(of: name) { return sizes[index] }
        switch name {
        case "default", "standard": return standard
        case "bigger", "larger", "up", "+": return "increment"
        case "smaller", "down", "-": return "decrement"
        default: return nil
        }
    }

    /// `L`, `AX3`: what Settings' slider and Xcode's Environment Overrides call it.
    public static func short(_ size: String) -> String {
        guard let index = sizes.firstIndex(of: size) else { return size }
        return ["XS", "S", "M", "L", "XL", "XXL", "XXXL", "AX1", "AX2", "AX3", "AX4", "AX5"][index]
    }
}

// MARK: - biometrics

/// What a simulated Face ID or Touch ID sensor is told: whether a face or a
/// finger is enrolled, and that the next scan matches or does not.
public enum SimulatorBiometricAction: String, CaseIterable, Codable, Sendable {
    case enroll, unenroll, match, nomatch

    public init?(parsing raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let action = Self(rawValue: name) { self = action; return }
        switch name {
        case "enrolled", "on": self = .enroll
        case "unenrolled", "off", "not-enrolled": self = .unenroll
        case "matching", "success", "pass": self = .match
        case "no-match", "non-matching", "nonmatching", "fail", "failure": self = .nomatch
        default: return nil
        }
    }
}

/// The sensor a device type has: Face ID (`pearl-id` in its capabilities) or
/// Touch ID (`touch-id`).
public enum SimulatorBiometryKind: String, Codable, Sendable {
    case face, touch

    public var title: String { self == .face ? "Face ID" : "Touch ID" }

    /// BiometricKit's simulator hooks: the guest posts a scan's result to
    /// whatever is waiting on a Face ID or Touch ID prompt.
    func notification(matching: Bool) -> String {
        "com.apple.BiometricKit_Sim." + (self == .face ? "pearl" : "fingerTouch") + (matching ? ".match" : ".nomatch")
    }

    /// The device type's sensor, from its `capabilities.plist`; nil when it
    /// declares neither.
    public static func of(deviceTypeBundle bundlePath: String) -> SimulatorBiometryKind? {
        let url = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Resources/capabilities.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let capabilities = plist["capabilities"] as? [String: Any] ?? plist
        if (capabilities["pearl-id"] as? NSNumber)?.boolValue == true { return .face }
        if (capabilities["touch-id"] as? NSNumber)?.boolValue == true { return .touch }
        return nil
    }
}

public struct SimulatorBiometricsState: Codable, Equatable, Sendable {
    /// `face`, `touch`, or absent for a device with no sensor.
    public var kind: SimulatorBiometryKind?
    public var enrolled: Bool

    public init(kind: SimulatorBiometryKind?, enrolled: Bool) {
        self.kind = kind
        self.enrolled = enrolled
    }

    /// The guest's enrollment flag: BiometricKit reads this notification's state.
    static let enrollmentNotification = "com.apple.BiometricKit.enrollmentChanged"
}

// MARK: - status bar

/// Status bar overrides (`simctl status_bar`): the clean 9:41 of a marketing
/// screenshot, or a weak signal and a low battery to see a layout cope.
/// Absent fields are left as they are.
public struct SimulatorStatusBar: Codable, Equatable, Sendable {
    public var time: String?
    /// hide, wifi, 3g, 4g, lte, lte-a, lte+, 5g, 5g+, 5g-uwb, 5g-uc.
    public var dataNetwork: String?
    /// searching, failed, active.
    public var wifiMode: String?
    /// 0…3.
    public var wifiBars: Int?
    /// notSupported, searching, failed, active.
    public var cellularMode: String?
    /// 0…4.
    public var cellularBars: Int?
    public var operatorName: String?
    /// charging, charged, discharging.
    public var batteryState: String?
    /// 0…100.
    public var batteryLevel: Int?

    public init(
        time: String? = nil,
        dataNetwork: String? = nil,
        wifiMode: String? = nil,
        wifiBars: Int? = nil,
        cellularMode: String? = nil,
        cellularBars: Int? = nil,
        operatorName: String? = nil,
        batteryState: String? = nil,
        batteryLevel: Int? = nil
    ) {
        self.time = time
        self.dataNetwork = dataNetwork
        self.wifiMode = wifiMode
        self.wifiBars = wifiBars
        self.cellularMode = cellularMode
        self.cellularBars = cellularBars
        self.operatorName = operatorName
        self.batteryState = batteryState
        self.batteryLevel = batteryLevel
    }

    public var isEmpty: Bool { self == SimulatorStatusBar() }

    /// The status bar a screenshot of a phone at its best shows. No cellular
    /// field: naming any makes simctl fill the rest in — 5G, full bars,
    /// "Carrier" — and the data network turns 5G instead of Wi-Fi.
    public static let clean = SimulatorStatusBar(time: "9:41", dataNetwork: "wifi", wifiMode: "active", wifiBars: 3, batteryState: "charged", batteryLevel: 100)

    static let dataNetworks = ["hide", "wifi", "3g", "4g", "lte", "lte-a", "lte+", "5g", "5g+", "5g-uwb", "5g-uc"]
    static let wifiModes = ["searching", "failed", "active"]
    static let cellularModes = ["notSupported", "searching", "failed", "active"]
    static let batteryStates = ["charging", "charged", "discharging"]

    /// `simctl status_bar … override` flags, checked first so a wrong value
    /// names itself instead of simctl's "Invalid argument".
    public func overrideArguments() throws -> [String] {
        func choice(_ value: String?, _ allowed: [String], _ name: String) throws -> String? {
            guard let value else { return nil }
            guard let match = allowed.first(where: { $0.lowercased() == value.lowercased() }) else {
                throw SimToolError("Status bar \(name) must be one of \(allowed.joined(separator: ", ")), not \(value)")
            }
            return match
        }
        func number(_ value: Int?, _ range: ClosedRange<Int>, _ name: String) throws -> Int? {
            guard let value else { return nil }
            guard range.contains(value) else { throw SimToolError("Status bar \(name) must be \(range.lowerBound)…\(range.upperBound), not \(value)") }
            return value
        }
        var arguments: [String] = []
        if let time { arguments += ["--time", time] }
        if let value = try choice(dataNetwork, Self.dataNetworks, "data network") { arguments += ["--dataNetwork", value] }
        if let value = try choice(wifiMode, Self.wifiModes, "Wi-Fi mode") { arguments += ["--wifiMode", value] }
        if let value = try number(wifiBars, 0...3, "Wi-Fi bars") { arguments += ["--wifiBars", String(value)] }
        if let value = try choice(cellularMode, Self.cellularModes, "cellular mode") { arguments += ["--cellularMode", value] }
        if let value = try number(cellularBars, 0...4, "cellular bars") { arguments += ["--cellularBars", String(value)] }
        if let operatorName { arguments += ["--operatorName", operatorName] }
        if let value = try choice(batteryState, Self.batteryStates, "battery state") { arguments += ["--batteryState", value] }
        if let value = try number(batteryLevel, 0...100, "battery level") { arguments += ["--batteryLevel", String(value)] }
        guard !arguments.isEmpty else { throw SimToolError("Name at least one status bar field to override, or clear the overrides") }
        return arguments
    }

    /// The overrides `simctl status_bar … list` prints, its numbers named back.
    public static func parse(list text: String) -> SimulatorStatusBar {
        var bar = SimulatorStatusBar()
        func fields(_ line: Substring) -> [String: String] {
            var result: [String: String] = [:]
            for part in line.split(separator: ",") {
                let pair = part.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { continue }
                result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: .whitespaces)
            }
            return result
        }
        let networks = [0: "hide", 1: "wifi", 6: "3g", 7: "4g", 8: "lte", 9: "lte-a", 10: "lte+", 11: "5g", 12: "5g+", 13: "5g-uwb", 14: "5g-uc"]
        let modes = [0: "notSupported", 1: "searching", 2: "failed", 3: "active"]
        let batteries = [0: "discharging", 1: "charging", 2: "charged"]
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Time:") {
                bar.time = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Operator Name:") {
                bar.operatorName = String(line.dropFirst(14)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("DataNetworkType:") {
                let raw = Int(line.dropFirst(16).trimmingCharacters(in: .whitespaces)) ?? -1
                bar.dataNetwork = networks[raw] ?? "type \(raw)"
            } else if line.hasPrefix("WiFi Mode:") {
                let values = fields(line)
                bar.wifiMode = values["WiFi Mode"].flatMap(Int.init).flatMap { modes[$0] }
                bar.wifiBars = values["WiFi Bars"].flatMap(Int.init)
            } else if line.hasPrefix("Cell Mode:") {
                let values = fields(line)
                bar.cellularMode = values["Cell Mode"].flatMap(Int.init).flatMap { modes[$0] }
                bar.cellularBars = values["Cell Bars"].flatMap(Int.init)
            } else if line.hasPrefix("Battery State:") {
                let values = fields(line)
                bar.batteryState = values["Battery State"].flatMap(Int.init).flatMap { batteries[$0] }
                bar.batteryLevel = values["Battery Level"].flatMap(Int.init)
            }
        }
        return bar
    }

    /// `9:41 · wifi · 100% charged`
    public var summary: String {
        var parts: [String] = []
        if let time { parts.append(time) }
        if let dataNetwork { parts.append(dataNetwork) }
        if let wifiBars { parts.append("Wi-Fi \(wifiBars)/3") }
        if let cellularBars { parts.append("cell \(cellularBars)/4") }
        if let operatorName, !operatorName.isEmpty { parts.append(operatorName) }
        if let batteryLevel { parts.append("\(batteryLevel)%" + (batteryState.map { " " + $0 } ?? "")) } else if let batteryState { parts.append(batteryState) }
        return parts.isEmpty ? "no overrides" : parts.joined(separator: " · ")
    }
}

// MARK: - location

public struct SimulatorCoordinate: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// `37.3349,-122.0090` — simctl's form, a dot for decimals.
    public init?(parsing raw: String) {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]),
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.init(latitude: latitude, longitude: longitude)
    }

    public var text: String { Self.format(latitude) + "," + Self.format(longitude) }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

/// Where the simulator says it is: one point, or a route it travels along
/// between waypoints at `speed` metres per second.
public struct SimulatorLocation: Codable, Equatable, Sendable {
    public var waypoints: [SimulatorCoordinate]
    /// Metres per second along a route; simctl's default is 20.
    public var speed: Double?
    /// Seconds between updates along a route…
    public var interval: Double?
    /// …or metres between them.
    public var distance: Double?
    /// When SimTool set it.
    public var setAt: Date?

    public init(waypoints: [SimulatorCoordinate], speed: Double? = nil, interval: Double? = nil, distance: Double? = nil, setAt: Date? = nil) {
        self.waypoints = waypoints
        self.speed = speed
        self.interval = interval
        self.distance = distance
        self.setAt = setAt
    }

    public var isRoute: Bool { waypoints.count > 1 }

    func arguments(deviceUDID: String) throws -> [String] {
        guard let first = waypoints.first else { throw SimToolError("A location needs a latitude and a longitude") }
        guard isRoute else { return ["simctl", "location", deviceUDID, "set", first.text] }
        if let speed, speed <= 0 { throw SimToolError("A route's speed must be positive, in metres per second") }
        var arguments = ["simctl", "location", deviceUDID, "start"]
        if let speed { arguments.append("--speed=\(speed)") }
        if let interval { arguments.append("--interval=\(interval)") } else if let distance { arguments.append("--distance=\(distance)") }
        return arguments + waypoints.map(\.text)
    }

    /// `37.3349,-122.009`, or `route of 3 points at 20 m/s`.
    public var summary: String {
        guard isRoute else { return waypoints.first?.text ?? "" }
        return "route of \(waypoints.count) points" + (speed.map { " at \(DeviceActivityWording.number($0)) m/s" } ?? "")
    }
}

/// The location SimTool last gave a device. simctl sets a location but cannot
/// read one back, so whoever sets it — the CLI or a server — notes it here,
/// per device, and every reader shows the same.
enum SimulatorLocationStore {
    static func url(deviceUDID: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SimTool/Locations/\(deviceUDID).json")
    }

    static func read(deviceUDID: String) -> SimulatorLocation? {
        guard let url = url(deviceUDID: deviceUDID), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSON.decoder.decode(SimulatorLocation.self, from: data)
    }

    static func write(_ location: SimulatorLocation?, deviceUDID: String) {
        guard let url = url(deviceUDID: deviceUDID) else { return }
        guard let location else { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSON.data(location, pretty: false).write(to: url, options: .atomic)
    }
}

// MARK: - the snapshot

/// Every setting as the device reports it. A setting the device would not
/// say is absent, and `unavailable` says why.
public struct SimulatorSettings: Codable, Equatable, Sendable {
    /// light, dark — or unsupported on a runtime without appearances.
    public var appearance: String?
    /// A `SimulatorContentSize.sizes` name.
    public var contentSize: String?
    public var increaseContrast: Bool?
    /// Each `SimulatorDebugOption` by name: on or off.
    public var debug: [String: Bool]?
    public var biometrics: SimulatorBiometricsState?
    /// The overrides in force; empty when there are none.
    public var statusBar: SimulatorStatusBar?
    /// The location SimTool last set; absent when it set none (or cleared it).
    public var location: SimulatorLocation?
    /// Setting → why it could not be read.
    public var unavailable: [String: String]?

    /// What a reading can be limited to.
    public enum Part: String, CaseIterable, Sendable {
        case appearance, contentSize, increaseContrast, debug, biometrics, statusBar, location
    }

    public init(
        appearance: String? = nil,
        contentSize: String? = nil,
        increaseContrast: Bool? = nil,
        debug: [String: Bool]? = nil,
        biometrics: SimulatorBiometricsState? = nil,
        statusBar: SimulatorStatusBar? = nil,
        location: SimulatorLocation? = nil,
        unavailable: [String: String]? = nil
    ) {
        self.appearance = appearance
        self.contentSize = contentSize
        self.increaseContrast = increaseContrast
        self.debug = debug
        self.biometrics = biometrics
        self.statusBar = statusBar
        self.location = location
        self.unavailable = unavailable
    }
}

// MARK: - the request

/// One change to the simulator's settings, or one debug action:
///
/// | action | fields |
/// |---|---|
/// | `appearance` | `value`: light, dark |
/// | `content-size` | `value`: a size, increment, decrement |
/// | `increase-contrast` | `enabled` |
/// | `debug` | `option` (a `SimulatorDebugOption`), `enabled` |
/// | `memory-warning` | — |
/// | `biometrics` | `value`: enroll, unenroll, match, nomatch |
/// | `push` | `payload` (an object with `aps`), `bundleId` (default: the app) |
/// | `status-bar` | `statusBar`, or `value`: clear |
/// | `location` | `location`, or `value`: clear |
public struct DeviceControlPayload: Codable, Equatable, Sendable {
    public var action: String
    public var option: String?
    public var value: String?
    public var enabled: Bool?
    public var bundleId: String?
    public var payload: NetworkLoggerJSONValue?
    public var statusBar: SimulatorStatusBar?
    public var location: SimulatorLocation?

    public init(
        action: String,
        option: String? = nil,
        value: String? = nil,
        enabled: Bool? = nil,
        bundleId: String? = nil,
        payload: NetworkLoggerJSONValue? = nil,
        statusBar: SimulatorStatusBar? = nil,
        location: SimulatorLocation? = nil
    ) {
        self.action = action
        self.option = option
        self.value = value
        self.enabled = enabled
        self.bundleId = bundleId
        self.payload = payload
        self.statusBar = statusBar
        self.location = location
    }

    public static let actions = ["appearance", "content-size", "increase-contrast", "debug", "memory-warning", "biometrics", "push", "status-bar", "location"]
}

// MARK: - acting and reading

public enum SimulatorDeviceControl {
    /// Performs one request and returns what the device reports afterwards,
    /// in words (`dark`, `Face ID enrolled`). `app` is the app a push goes to
    /// when the request names none.
    public static func perform(_ control: DeviceControlPayload, deviceUDID udid: String, app: String? = nil) async throws -> String {
        switch control.action.lowercased() {
        case "appearance":
            guard let raw = control.value, let appearance = SimulatorAppearance(rawValue: raw.lowercased()) else {
                throw SimToolError("Appearance takes light or dark")
            }
            try await simctl(["ui", udid, "appearance", appearance.rawValue])
            return try await ui(udid, "appearance")
        case "content-size", "text-size":
            guard let raw = control.value, let size = SimulatorContentSize.parse(raw) else {
                throw SimToolError("Text size takes one of \(SimulatorContentSize.sizes.joined(separator: ", ")), increment or decrement")
            }
            try await simctl(["ui", udid, "content_size", size])
            return try await ui(udid, "content_size")
        case "increase-contrast", "contrast":
            guard let enabled = control.enabled else { throw SimToolError("Increase Contrast takes enabled: true or false") }
            try await simctl(["ui", udid, "increase_contrast", enabled ? "enabled" : "disabled"])
            return try await ui(udid, "increase_contrast")
        case "debug":
            guard let raw = control.option, let option = SimulatorDebugOption(parsing: raw) else {
                throw SimToolError("Debug takes an option: \(SimulatorDebugOption.names)")
            }
            guard let enabled = control.enabled else { throw SimToolError("Debug \(option.rawValue) takes enabled: true or false") }
            let now = try await setDebug(option, enabled: enabled, deviceUDID: udid)
            guard now == enabled else { throw SimToolError("The simulator kept \(option.title) \(now ? "on" : "off")") }
            return option.title + (now ? " on" : " off")
        case "memory-warning":
            try await SimulatorDirectInputClient.shared.simulateMemoryWarning(deviceUDID: udid)
            return "sent"
        case "biometrics":
            guard let raw = control.value, let action = SimulatorBiometricAction(parsing: raw) else {
                throw SimToolError("Biometrics takes enroll, unenroll, match or nomatch")
            }
            return try await biometrics(action, deviceUDID: udid)
        case "push":
            guard let bundleId = control.bundleId.flatMap({ $0.isEmpty ? nil : $0 }) ?? app else {
                throw SimToolError("A push needs the app's bundle id: pass bundleId, or start the server with --app")
            }
            guard let payload = control.payload else { throw SimToolError("A push needs a payload: a JSON object with an `aps` dictionary") }
            try await push(payload, bundleId: bundleId, deviceUDID: udid)
            return "to " + bundleId
        case "status-bar":
            if control.value?.lowercased() == "clear" {
                try await simctl(["status_bar", udid, "clear"])
                return "cleared"
            }
            guard let bar = control.statusBar else { throw SimToolError("A status bar override needs statusBar fields, or value: clear") }
            try await simctl(["status_bar", udid, "override"] + bar.overrideArguments())
            return try await statusBar(deviceUDID: udid).summary
        case "location":
            if control.value?.lowercased() == "clear" {
                try await simctl(["location", udid, "clear"])
                SimulatorLocationStore.write(nil, deviceUDID: udid)
                return "cleared"
            }
            guard var location = control.location, !location.waypoints.isEmpty else {
                throw SimToolError("A location needs waypoints — one point, or a route of two or more — or value: clear")
            }
            let arguments = try location.arguments(deviceUDID: udid)
            try await check(ProcessRunner.runXcrun(arguments), what: "simctl location")
            location.setAt = Date()
            SimulatorLocationStore.write(location, deviceUDID: udid)
            return location.summary
        default:
            throw SimToolError("Unknown device action \(control.action.isEmpty ? "<missing>" : control.action): use one of \(DeviceControlPayload.actions.joined(separator: ", "))")
        }
    }

    /// Reads the settings the device will tell — all of them, or `parts` —
    /// at once.
    public static func read(deviceUDID udid: String, deviceType: String? = nil, parts: Set<SimulatorSettings.Part> = Set(SimulatorSettings.Part.allCases)) async -> SimulatorSettings {
        @Sendable func when<T>(_ part: SimulatorSettings.Part, _ body: () async throws -> T) async -> Result<T, Error>? {
            parts.contains(part) ? await attempt(body) : nil
        }
        async let appearance = when(.appearance) { try await ui(udid, "appearance") }
        async let contentSize = when(.contentSize) { try await ui(udid, "content_size") }
        async let contrast = when(.increaseContrast) { try await ui(udid, "increase_contrast") }
        async let debug = when(.debug) { try await debugOptions(deviceUDID: udid) }
        async let biometrics = when(.biometrics) { try await biometricsState(deviceUDID: udid, deviceType: deviceType) }
        async let statusBar = when(.statusBar) { try await statusBar(deviceUDID: udid) }
        var settings = SimulatorSettings(location: parts.contains(.location) ? SimulatorLocationStore.read(deviceUDID: udid) : nil)
        var unavailable: [String: String] = [:]
        func keep<T>(_ result: Result<T, Error>?, _ name: String, _ assign: (T) -> Void) {
            switch result {
            case .success(let value)?: assign(value)
            case .failure(let error)?: unavailable[name] = (error as? SimToolError)?.message ?? error.localizedDescription
            case nil: break
            }
        }
        keep(await appearance, "appearance") { settings.appearance = $0 }
        keep(await contentSize, "contentSize") { settings.contentSize = $0 }
        keep(await contrast, "increaseContrast") { value in
            if value == "enabled" || value == "disabled" { settings.increaseContrast = value == "enabled" } else { unavailable["increaseContrast"] = value }
        }
        keep(await debug, "debug") { settings.debug = $0 }
        keep(await biometrics, "biometrics") { settings.biometrics = $0 }
        keep(await statusBar, "statusBar") { settings.statusBar = $0 }
        settings.unavailable = unavailable.isEmpty ? nil : unavailable
        return settings
    }

    // MARK: debug options

    /// Sets one option and returns what the device reports for it afterwards.
    public static func setDebug(_ option: SimulatorDebugOption, enabled: Bool, deviceUDID udid: String) async throws -> Bool {
        if let number = option.renderServerOption {
            return try await SimulatorDirectInputClient.shared.setRenderDebugOption(number, enabled: enabled, deviceUDID: udid)
        }
        let key = SimulatorDebugOption.slowAnimationsNotification
        let states = try await SimulatorNotify.run(["-s", key, enabled ? "1" : "0", "-p", key, "-g", key], deviceUDID: udid)
        return (states[key] ?? 0) != 0
    }

    public static func debugOptions(deviceUDID udid: String) async throws -> [String: Bool] {
        var options: [String: Bool] = [:]
        for option in SimulatorDebugOption.allCases {
            if let number = option.renderServerOption {
                options[option.rawValue] = try await SimulatorDirectInputClient.shared.renderDebugOption(number, deviceUDID: udid)
            }
        }
        let key = SimulatorDebugOption.slowAnimationsNotification
        options[SimulatorDebugOption.slowAnimations.rawValue] = try await (SimulatorNotify.run(["-g", key], deviceUDID: udid)[key] ?? 0) != 0
        return options
    }

    // MARK: biometrics

    static func biometrics(_ action: SimulatorBiometricAction, deviceUDID udid: String) async throws -> String {
        let key = SimulatorBiometricsState.enrollmentNotification
        switch action {
        case .enroll, .unenroll:
            let states = try await SimulatorNotify.run(["-s", key, action == .enroll ? "1" : "0", "-p", key, "-g", key], deviceUDID: udid)
            return (states[key] ?? 0) != 0 ? "enrolled" : "not enrolled"
        case .match, .nomatch:
            let kind = await biometryKind(deviceUDID: udid, deviceType: nil) ?? .face
            _ = try await SimulatorNotify.run(["-p", kind.notification(matching: action == .match)], deviceUDID: udid)
            return kind.title + (action == .match ? " matched" : " did not match")
        }
    }

    static func biometricsState(deviceUDID udid: String, deviceType: String?) async throws -> SimulatorBiometricsState {
        let key = SimulatorBiometricsState.enrollmentNotification
        async let states = SimulatorNotify.run(["-g", key], deviceUDID: udid)
        async let kind = biometryKind(deviceUDID: udid, deviceType: deviceType)
        return SimulatorBiometricsState(kind: await kind, enrolled: try await (states[key] ?? 0) != 0)
    }

    private static let kinds = BiometryKindCache()

    static func biometryKind(deviceUDID udid: String, deviceType: String?) async -> SimulatorBiometryKind? {
        var type = deviceType
        if type == nil { type = (try? await SimulatorDeviceClient.listDevices())?.first { $0.udid == udid }?.deviceTypeIdentifier }
        guard let type else { return nil }
        if let known = kinds.get(type) { return known }
        guard let bundle = await SimulatorDisplayLayout.load(deviceType: type)?.bundlePath else { return nil }
        let kind = SimulatorBiometryKind.of(deviceTypeBundle: bundle)
        kinds.set(type, kind)
        return kind
    }

    // MARK: push

    static func push(_ payload: NetworkLoggerJSONValue, bundleId: String, deviceUDID udid: String) async throws {
        guard case .object(let fields) = payload, case .object = fields["aps"] else {
            throw SimToolError("A push payload is a JSON object with an `aps` dictionary, like {\"aps\": {\"alert\": \"Hello\"}}")
        }
        let data = try JSONEncoder().encode(payload)
        guard data.count <= 4096 else { throw SimToolError("A push payload is at most 4096 bytes; this one is \(data.count)") }
        try await check(
            ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["simctl", "push", udid, bundleId, "-"], stdin: data, timeoutSeconds: 20),
            what: "simctl push"
        )
    }

    // MARK: status bar

    public static func statusBar(deviceUDID udid: String) async throws -> SimulatorStatusBar {
        SimulatorStatusBar.parse(list: try await simctl(["status_bar", udid, "list"]))
    }

    // MARK: simctl

    /// `simctl ui <udid> <option>`: what the device has now.
    static func ui(_ udid: String, _ option: String) async throws -> String {
        try await simctl(["ui", udid, option]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func simctl(_ arguments: [String]) async throws -> String {
        try await check(ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["simctl"] + arguments, timeoutSeconds: 20), what: "simctl " + (arguments.first ?? ""))
    }

    @discardableResult
    static func check(_ output: ProcessOutput, what: String) throws -> String {
        guard output.status == 0 else {
            let detail = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimToolError("\(what) failed" + (detail.isEmpty ? "" : ": " + detail))
        }
        return output.stdoutString
    }

    private static func attempt<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}

private final class BiometryKindCache: @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [String: SimulatorBiometryKind?] = [:]

    func get(_ type: String) -> SimulatorBiometryKind?? { lock.withLock { kinds[type] } }
    func set(_ type: String, _ kind: SimulatorBiometryKind?) { lock.withLock { kinds[type] = .some(kind) } }
}

/// Darwin notifications inside the simulator, through its own `notifyutil`.
enum SimulatorNotify {
    /// Runs notifyutil's commands in order (`-s KEY STATE`, `-p KEY`, `-g KEY`)
    /// and returns the states the `-g`s printed.
    static func run(_ commands: [String], deviceUDID udid: String) async throws -> [String: UInt64] {
        let output = try SimulatorDeviceControl.check(
            await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["simctl", "spawn", udid, "notifyutil"] + commands, timeoutSeconds: 15),
            what: "notifyutil"
        )
        return parse(output)
    }

    /// `KEY STATE` per line.
    static func parse(_ text: String) -> [String: UInt64] {
        var states: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let state = UInt64(parts[1]) { states[String(parts[0])] = state }
        }
        return states
    }
}
