import Foundation

/// Which way up the device is held, as Simulator.app's Rotate Left and
/// Rotate Right turn it. An app that does not support an orientation keeps
/// its interface where it was; the device still turns.
public enum SimulatorOrientation: String, CaseIterable, Codable, Sendable {
    case portrait
    case landscapeLeft = "landscape-left"
    case portraitUpsideDown = "upside-down"
    case landscapeRight = "landscape-right"

    /// UIDeviceOrientation: what the device-orientation event carries.
    var deviceOrientation: Int {
        switch self {
        case .portrait: 1
        case .portraitUpsideDown: 2
        case .landscapeLeft: 3
        case .landscapeRight: 4
        }
    }

    public var title: String {
        switch self {
        case .portrait: "portrait"
        case .landscapeLeft: "landscape left"
        case .portraitUpsideDown: "upside down"
        case .landscapeRight: "landscape right"
        }
    }

    /// Turned a quarter: Rotate Left is counter-clockwise, which brings the
    /// top of a portrait device to the left — landscape left.
    public func turned(clockwise: Bool) -> SimulatorOrientation {
        let order: [SimulatorOrientation] = [.portrait, .landscapeLeft, .portraitUpsideDown, .landscapeRight]
        let index = order.firstIndex(of: self)!
        return order[(index + (clockwise ? 3 : 1)) % 4]
    }

    /// An orientation's name, or how people say it: `landscape`
    /// (landscape left), `landscapeRight`, `upside-down`.
    public init?(parsing raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        if let orientation = Self(rawValue: name) { self = orientation; return }
        switch name {
        case "landscape", "landscapeleft": self = .landscapeLeft
        case "landscaperight": self = .landscapeRight
        case "upsidedown", "portrait-upside-down", "portraitupsidedown": self = .portraitUpsideDown
        default: return nil
        }
    }

    /// CoreDevice's name (`landscapeRight`, `portraitUpsideDown`).
    init?(devicectl name: String) {
        switch name {
        case "portrait": self = .portrait
        case "landscapeLeft": self = .landscapeLeft
        case "landscapeRight": self = .landscapeRight
        case "portraitUpsideDown": self = .portraitUpsideDown
        default: return nil
        }
    }

    /// What `devicectl device info displays` reports as the device's
    /// orientation. A device nothing has turned since it booted reads
    /// `unknown`, and one lying flat `faceUp`: then the last upright one counts.
    static func parse(devicectl data: Data) -> SimulatorOrientation? {
        struct Output: Decodable {
            struct Result: Decodable {
                struct Orientation: Decodable {
                    var currentDeviceOrientation: String?
                    var currentDeviceNonFlatOrientation: String?
                }
                var orientation: Orientation?
            }
            var result: Result?
        }
        guard let orientation = (try? JSONDecoder().decode(Output.self, from: data))?.result?.orientation else { return nil }
        return orientation.currentDeviceOrientation.flatMap(Self.init(devicectl:))
            ?? orientation.currentDeviceNonFlatOrientation.flatMap(Self.init(devicectl:))
    }

    public static func read(deviceUDID: String) async throws -> SimulatorOrientation {
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["devicectl", "device", "info", "displays", "--device", deviceUDID, "--quiet", "--json-output", "-"],
            timeoutSeconds: 10
        )
        guard output.status == 0, let orientation = parse(devicectl: output.stdout) else {
            let detail = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimToolError("CoreDevice did not say how \(deviceUDID) is held" + (detail.isEmpty ? "" : ": " + detail))
        }
        return orientation
    }

    /// A target: an orientation, or `left` / `right` — a quarter turn from
    /// where the device is now.
    public static func target(_ raw: String, deviceUDID: String) async throws -> SimulatorOrientation {
        switch raw.lowercased() {
        case "left", "right":
            return try await read(deviceUDID: deviceUDID).turned(clockwise: raw.lowercased() == "right")
        default:
            guard let orientation = SimulatorOrientation(parsing: raw) else {
                throw SimToolError("Unknown orientation \(raw): use portrait, landscape-left, landscape-right, upside-down, or left / right to turn a quarter")
            }
            return orientation
        }
    }

    /// Turns the device and waits until CoreDevice reports it turned.
    /// A foldable turns its picture with its fold instead, and refuses.
    public static func rotate(to raw: String, deviceUDID: String, layout: SimulatorDisplayLayout?) async throws -> SimulatorOrientation {
        if layout?.isFoldable == true {
            throw SimToolError("A foldable turns its picture as it folds; it takes a pose, not a rotation")
        }
        let target = try await target(raw, deviceUDID: deviceUDID)
        try await SimulatorDirectInputClient.shared.setOrientation(target, deviceUDID: deviceUDID)
        var last: SimulatorOrientation?
        for _ in 0..<12 {
            last = try? await read(deviceUDID: deviceUDID)
            if last == target { return target }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw SimToolError("The simulator did not turn \(target.title): it reports \(last?.title ?? "no orientation")")
    }
}
