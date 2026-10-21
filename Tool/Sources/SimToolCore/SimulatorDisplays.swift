import Foundation

/// One screen of a simulator, as its device type declares it.
///
/// A phone has one. A foldable (iPhone Duo) has two: a small cover panel and an
/// inner panel that opens like a book, each its own framebuffer, its own touch
/// screen and its own name in `simctl io … --display=`. Only one of them is lit
/// at a time; `SimulatorDisplayState` says which.
public struct SimulatorDisplay: Codable, Equatable, Sendable {
    /// simctl's name for it — what `simctl io screenshot --display=` takes:
    /// `primary`, `primary-1`.
    public var id: String
    /// CoreSimulator's screen number (`1`, `3`): `--display=` takes it too.
    public var screenID: Int
    /// `cover` or `inner` on a foldable; nil on a one-screen device.
    public var role: String?
    /// The framebuffer in pixels, the way the panel scans it out. The picture
    /// on it may be turned (`SimulatorDisplayState.rotations`).
    public var width: Int
    public var height: Int
    public var scale: Double
    /// The screen's corner radii in points, clockwise from the top-left, in the
    /// framebuffer's own orientation. The cover's are uneven: tight on the
    /// hinge side, round on the outer edge.
    public var cornerRadii: [Double]?
    /// The DeviceKit chrome Simulator draws around this screen
    /// (`com.apple.dt.devicekit.chrome.phone11`): its bezel and buttons.
    public var chrome: String?

    public init(id: String, screenID: Int, role: String? = nil, width: Int, height: Int, scale: Double, cornerRadii: [Double]? = nil, chrome: String? = nil) {
        self.id = id
        self.screenID = screenID
        self.role = role
        self.width = width
        self.height = height
        self.scale = scale
        self.cornerRadii = cornerRadii
        self.chrome = chrome
    }

    /// The screen in points as its picture shows it: a picture turned a
    /// quarter swaps the sides.
    public func points(rotation: Int) -> SimulatorScreenSize {
        let width = Double(self.width) / scale, height = Double(self.height) / scale
        return SimulatorDisplayRotation.isQuarterTurn(rotation)
            ? SimulatorScreenSize(width: height, height: width, scale: scale)
            : SimulatorScreenSize(width: width, height: height, scale: scale)
    }

    /// The corner radii as the turned picture shows them, clockwise from its
    /// top-left.
    public func cornerRadii(rotation: Int) -> [Double]? {
        guard let radii = cornerRadii, radii.count == 4 else { return cornerRadii }
        let steps = SimulatorDisplayRotation.normalized(rotation) / 90
        return (0..<4).map { radii[($0 - steps + 4) % 4] }
    }
}

/// The screens a device type declares: the integrated ones with a touch
/// screen and a bezel. TV-out, CarPlay and the 7680×4320 "resizable" scene
/// Device Hub may draw into are not screens of the device.
public struct SimulatorDisplayLayout: Codable, Equatable, Sendable {
    public var deviceType: String?
    public var displays: [SimulatorDisplay]
    /// The device type's product class (`V68` for the iPhone Duo): what Xcode
    /// names its 3D device model after.
    public var productClass: String?
    /// The device type's bundle (`….simdevicetype`).
    public var bundlePath: String?

    public init(deviceType: String? = nil, displays: [SimulatorDisplay], productClass: String? = nil, bundlePath: String? = nil) {
        self.deviceType = deviceType
        self.displays = displays
        self.productClass = productClass
        self.bundlePath = bundlePath
    }

    /// More than one screen: a foldable. Everything that names a screen, turns
    /// a picture or follows the fold applies to these alone; a one-screen
    /// device keeps SimTool's single-screen behaviour.
    public var isFoldable: Bool { displays.count > 1 }

    /// The touch target the simulator registers for a screen. A one-screen
    /// device takes the shared digitizer slot (0x32); a foldable registers
    /// each integrated screen under its screen number with SimulatorHID's
    /// mask, and only that target lands on that panel.
    public func touchTarget(of display: SimulatorDisplay) -> UInt32 {
        isFoldable ? 0x4000_0000 | UInt32(display.screenID) : 0x32
    }

    /// Whether Indigo touches reach a screen in every state of the boot.
    /// SimulatorHID stands its touch screens down while the simulator's HID
    /// daemon (dtuhidd) runs and revives only its main digitizer on an Indigo
    /// event — on the iPhone Duo the inner panel (Xcode 27.2: the cover's
    /// stays down, and an Indigo event dispatched into it aborts backboardd).
    /// The other panels are touched through dtuhidd, as Device Hub does.
    public func takesIndigoTouches(_ display: SimulatorDisplay) -> Bool {
        !isFoldable || display.role == "inner"
    }

    /// A screen by any of its names: simctl's (`primary-1`), its role
    /// (`inner`) or its screen number (`3`).
    public func display(named raw: String) -> SimulatorDisplay? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return nil }
        return displays.first { $0.id.lowercased() == name }
            ?? displays.first { $0.role == name }
            ?? Int(name).flatMap { number in displays.first { $0.screenID == number } }
    }

    /// The screens of `capabilities.plist`, in the order it lists them. With
    /// exactly two, the smaller is the cover.
    public static func parse(capabilities data: Data, deviceType: String? = nil) -> SimulatorDisplayLayout {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return SimulatorDisplayLayout(deviceType: deviceType, displays: [])
        }
        let root = plist["capabilities"] as? [String: Any] ?? plist
        var displays: [SimulatorDisplay] = []
        for entry in root["displays"] as? [[String: Any]] ?? [] {
            guard entry["displayType"] as? String == "integrated",
                  (entry["hasDigitizer"] as? NSNumber)?.boolValue == true,
                  let chrome = entry["chromeIdentifier"] as? String, !chrome.isEmpty,
                  let width = (entry["width"] as? NSNumber)?.intValue, width > 0,
                  let height = (entry["height"] as? NSNumber)?.intValue, height > 0 else { continue }
            let screenID = (entry["screenID"] as? NSNumber)?.intValue ?? displays.count + 1
            let radii = ["cornerRadiusUL", "cornerRadiusUR", "cornerRadiusLR", "cornerRadiusLL"].map { (entry[$0] as? NSNumber)?.doubleValue }
            displays.append(SimulatorDisplay(
                id: entry["deviceName"] as? String ?? "screen-\(screenID)",
                screenID: screenID,
                width: width,
                height: height,
                scale: (entry["scale"] as? NSNumber)?.doubleValue ?? 1,
                cornerRadii: radii.allSatisfy { $0 != nil } ? radii.compactMap { $0 } : nil,
                chrome: chrome
            ))
        }
        if displays.count == 2 {
            let coverIndex = displays[0].width * displays[0].height <= displays[1].width * displays[1].height ? 0 : 1
            displays[coverIndex].role = "cover"
            displays[1 - coverIndex].role = "inner"
        }
        return SimulatorDisplayLayout(deviceType: deviceType, displays: displays)
    }

    /// The screens of a device type bundle (`….simdevicetype`), or nil when it
    /// declares none.
    public static func load(bundlePath: String, deviceType: String? = nil) -> SimulatorDisplayLayout? {
        let resources = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Resources")
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("capabilities.plist")) else { return nil }
        var layout = parse(capabilities: data, deviceType: deviceType)
        guard !layout.displays.isEmpty else { return nil }
        layout.bundlePath = bundlePath
        if let profile = try? Data(contentsOf: resources.appendingPathComponent("profile.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: profile, format: nil) as? [String: Any] {
            layout.productClass = plist["productClass"] as? String
        }
        return layout
    }

    /// The screens of a device type, found through `simctl list devicetypes`.
    public static func load(deviceType: String) async -> SimulatorDisplayLayout? {
        guard let output = try? await ProcessRunner.runXcrun(["simctl", "list", "devicetypes", "--json"]), output.status == 0,
              let bundlePath = bundlePath(of: deviceType, inDeviceTypes: output.stdout) else { return nil }
        return load(bundlePath: bundlePath, deviceType: deviceType)
    }

    /// `simctl list devicetypes --json` → the bundle path of one device type.
    static func bundlePath(of deviceType: String, inDeviceTypes data: Data) -> String? {
        struct List: Decodable {
            struct DeviceType: Decodable {
                var identifier: String
                var bundlePath: String?
            }
            var devicetypes: [DeviceType]
        }
        return (try? JSONDecoder().decode(List.self, from: data))?.devicetypes.first { $0.identifier == deviceType }?.bundlePath
    }
}

/// Which screen of a foldable is lit, and how each one's picture is turned —
/// what folding and rotating the device change.
public struct SimulatorDisplayState: Codable, Equatable, Sendable {
    /// The lit screen's id (`primary`, `primary-1`).
    public var active: String
    /// Degrees clockwise each screen's picture is turned from its framebuffer:
    /// 0, 90, 180 or 270. The inner panel's framebuffer is portrait while it
    /// shows a landscape picture, so held upright it reads 90.
    public var rotations: [String: Int]
    /// Each screen's unique id, the one backboardd names its touch screen by.
    public var uniqueIDs: [String: String]

    public init(active: String, rotations: [String: Int] = [:], uniqueIDs: [String: String] = [:]) {
        self.active = active
        self.rotations = rotations
        self.uniqueIDs = uniqueIDs
    }

    public func rotation(of display: String) -> Int { rotations[display] ?? 0 }

    /// The state `devicectl device info displays --json-output` reports, with
    /// its screens named as `layout` names them. Nil when no screen is lit.
    public static func parse(devicectl data: Data, layout: SimulatorDisplayLayout) -> SimulatorDisplayState? {
        struct Output: Decodable {
            struct Result: Decodable { var displays: [Display]? }
            struct Display: Decodable {
                var displayId: Int?
                var active: Bool?
                var currentOrientation: String?
                var uniqueId: String?
            }
            var result: Result?
        }
        guard let displays = (try? JSONDecoder().decode(Output.self, from: data))?.result?.displays else { return nil }
        var active: String?
        var rotations: [String: Int] = [:]
        var uniqueIDs: [String: String] = [:]
        for entry in displays {
            guard let screenID = entry.displayId, let display = layout.displays.first(where: { $0.screenID == screenID }) else { continue }
            if entry.active == true, active == nil { active = display.id }
            if let orientation = entry.currentOrientation, let degrees = SimulatorDisplayRotation.degrees(devicectl: orientation) {
                rotations[display.id] = degrees
            }
            if let uniqueID = entry.uniqueId, !uniqueID.isEmpty { uniqueIDs[display.id] = uniqueID }
        }
        // A phone's one screen is lit whenever the device is; CoreDevice does not say so.
        if active == nil, layout.displays.count == 1, let only = layout.displays.first,
           displays.contains(where: { $0.displayId == only.screenID }) {
            active = only.id
        }
        guard let active else { return nil }
        return SimulatorDisplayState(active: active, rotations: rotations, uniqueIDs: uniqueIDs)
    }

    /// Reads it from the booted device. CoreDevice answers in about a tenth of
    /// a second.
    public static func read(deviceUDID: String, layout: SimulatorDisplayLayout) async throws -> SimulatorDisplayState {
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["devicectl", "device", "info", "displays", "--device", deviceUDID, "--quiet", "--json-output", "-"],
            timeoutSeconds: 10
        )
        guard output.status == 0, let state = parse(devicectl: output.stdout, layout: layout) else {
            let detail = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimToolError("Cannot tell which screen of \(deviceUDID) is lit: devicectl reported \(detail.isEmpty ? "no lit screen" : detail)")
        }
        return state
    }
}

/// A screen's picture turned on its framebuffer, and the touch coordinates
/// that follow from it.
public enum SimulatorDisplayRotation {
    public static func normalized(_ degrees: Int) -> Int { ((degrees % 360) + 360) % 360 / 90 * 90 }

    public static func isQuarterTurn(_ degrees: Int) -> Bool { normalized(degrees) % 180 == 90 }

    /// devicectl's `rot0`, `rot90`, `rot180`, `rot270`.
    static func degrees(devicectl orientation: String) -> Int? {
        guard orientation.hasPrefix("rot"), let degrees = Int(orientation.dropFirst(3)) else { return nil }
        return normalized(degrees)
    }

    /// Where a point of the picture — a fraction of the screen as it reads,
    /// 0…1 from its top-left — lies on the framebuffer, the digitizer's space.
    /// A picture turned 90° clockwise has the framebuffer's bottom-left corner
    /// at its top-left.
    public static func framebufferRatio(_ ratio: TouchRatio, rotation: Int) -> TouchRatio {
        switch normalized(rotation) {
        case 90: TouchRatio(x: ratio.y, y: 1 - ratio.x)
        case 180: TouchRatio(x: 1 - ratio.x, y: 1 - ratio.y)
        case 270: TouchRatio(x: 1 - ratio.y, y: ratio.x)
        default: ratio
        }
    }
}
