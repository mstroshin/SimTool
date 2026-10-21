import Foundation
import SimToolNetworkLogger

/// Who acted on the device. `agent` is whatever drives it from outside a
/// SimTool page — the CLI, a script, the HTTP API; `test` is a YAML test run;
/// `viewer` is a person at a SimTool page.
public enum DeviceActivityActor: String, Codable, Equatable, Sendable {
    case agent
    case test
    case viewer
}

public enum DeviceActivityStatus: String, Codable, Equatable, Sendable {
    case running
    case done
    case failed
}

/// The finger an activity put on the screen, in screen points: enough for a
/// viewer to draw where it went down, where it lifted and how long it took.
public struct DeviceActivityGesture: Codable, Equatable, Sendable {
    public var from: TouchPoint
    public var to: TouchPoint
    /// Seconds the finger rested at `from` before moving.
    public var press: Double
    /// Seconds from down to up.
    public var duration: Double
    /// The screen the points are in, so a viewer can place them without
    /// knowing the device.
    public var screen: SimulatorScreenSize?

    public init(from: TouchPoint, to: TouchPoint, press: Double, duration: Double, screen: SimulatorScreenSize? = nil) {
        self.from = from
        self.to = to
        self.press = press
        self.duration = duration
        self.screen = screen
    }

    public init(stroke: TouchStroke, screen: SimulatorScreenSize?) {
        let travel = stroke.isStationary ? 0 : stroke.from.distance(to: stroke.to) / stroke.velocity
        self.init(from: stroke.from, to: stroke.to, press: stroke.press, duration: stroke.press + travel + stroke.hold, screen: screen)
    }
}

/// One thing done to the device — a tap, a scroll, a launch, a mock armed, a
/// test step — as the viewer's activity feed shows it.
public struct DeviceActivity: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    /// Bumped on every change to the entry; `since` cursors read it, so a
    /// running entry that finishes is handed out again.
    public var revision: Int
    public var actor: DeviceActivityActor
    /// How it reached the server: `cli`, `api`, `viewer`.
    public var via: String?
    /// The action: tap, long-press, swipe, drag, scroll, fling, type, paste,
    /// button, shake, launch, terminate, keyboard, photos, mock, test, step, …
    public var kind: String
    /// What happened, in words: `Tap “General”`, `Scroll up 300 pt`.
    public var title: String
    public var detail: String?
    public var at: Date
    public var endedAt: Date?
    public var status: DeviceActivityStatus
    public var error: String?
    public var gesture: DeviceActivityGesture?

    public init(
        id: Int,
        revision: Int,
        actor: DeviceActivityActor,
        via: String? = nil,
        kind: String,
        title: String,
        detail: String? = nil,
        at: Date,
        endedAt: Date? = nil,
        status: DeviceActivityStatus,
        error: String? = nil,
        gesture: DeviceActivityGesture? = nil
    ) {
        self.id = id
        self.revision = revision
        self.actor = actor
        self.via = via
        self.kind = kind
        self.title = title
        self.detail = detail
        self.at = at
        self.endedAt = endedAt
        self.status = status
        self.error = error
        self.gesture = gesture
    }

    // Times carry milliseconds: the feed orders and ages entries a few hundred
    // milliseconds apart, which whole seconds would blur together.
    private enum CodingKeys: String, CodingKey {
        case id, revision, actor, via, kind, title, detail, at, endedAt, status, error, gesture
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        revision = try container.decode(Int.self, forKey: .revision)
        actor = try container.decode(DeviceActivityActor.self, forKey: .actor)
        via = try container.decodeIfPresent(String.self, forKey: .via)
        kind = try container.decode(String.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        at = try PreciseTime.date(container.decode(String.self, forKey: .at), key: .at, in: container)
        endedAt = try container.decodeIfPresent(String.self, forKey: .endedAt).map { try PreciseTime.date($0, key: .endedAt, in: container) }
        status = try container.decode(DeviceActivityStatus.self, forKey: .status)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        gesture = try container.decodeIfPresent(DeviceActivityGesture.self, forKey: .gesture)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(revision, forKey: .revision)
        try container.encode(actor, forKey: .actor)
        try container.encodeIfPresent(via, forKey: .via)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encode(PreciseTime.string(at), forKey: .at)
        try container.encodeIfPresent(endedAt.map(PreciseTime.string), forKey: .endedAt)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(gesture, forKey: .gesture)
    }
}

/// What a client tells the server it did to the device — the CLI acts on the
/// simulator in its own process, so without this a viewer never sees it. With
/// no `id` it is a new activity; with the `id` the server handed back, it
/// finishes that one.
public struct DeviceActivityReport: Codable, Equatable, Sendable {
    public var id: Int?
    public var actor: DeviceActivityActor?
    public var via: String?
    public var kind: String?
    public var title: String?
    public var detail: String?
    public var status: DeviceActivityStatus?
    public var error: String?
    public var gesture: DeviceActivityGesture?

    public init(
        id: Int? = nil,
        actor: DeviceActivityActor? = nil,
        via: String? = nil,
        kind: String? = nil,
        title: String? = nil,
        detail: String? = nil,
        status: DeviceActivityStatus? = nil,
        error: String? = nil,
        gesture: DeviceActivityGesture? = nil
    ) {
        self.id = id
        self.actor = actor
        self.via = via
        self.kind = kind
        self.title = title
        self.detail = detail
        self.status = status
        self.error = error
        self.gesture = gesture
    }
}

/// `GET /api/v1/activity`: the entries changed after `since`, the revision to
/// pass next time, and the test run driving the device, if one is.
public struct DeviceActivityPayload: Codable, Equatable, Sendable {
    public var entries: [DeviceActivity]
    public var revision: Int
    public var run: TestRunStatusPayload?

    public init(entries: [DeviceActivity], revision: Int, run: TestRunStatusPayload? = nil) {
        self.entries = entries
        self.revision = revision
        self.run = run
    }
}

/// The activity feed's words for a device input, shared by the server (which
/// performs API input) and the CLI (which performs its own and reports it), so
/// a tap reads the same whichever way it arrived.
public enum DeviceActivityWording {
    /// `action` is the input's lowercased action; `stroke` the touch it played.
    public static func describe(_ input: SimulatorInputPayload, action: String, stroke: TouchStroke? = nil) -> (kind: String, title: String, detail: String?) {
        let target = named(input.target) ?? named(input.label) ?? named(input.id)
        let at = stroke.map { "at " + point($0.from) }
        switch action {
        case "tap":
            return ("tap", target.map { "Tap " + quoted($0) } ?? "Tap " + (stroke.map { point($0.from) } ?? "?"), target != nil ? at : nil)
        case "longpress", "long-press":
            let held = (input.duration ?? stroke?.press).map { seconds($0) }
            let title = target.map { "Long press " + quoted($0) } ?? "Long press " + (stroke.map { point($0.from) } ?? "?")
            return ("long-press", title, [target != nil ? at : nil, held.map { "held " + $0 }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
        case "swipe", "drag":
            let verb = action == "drag" ? "Drag" : "Swipe"
            let path = stroke.map { point($0.from) + " → " + point($0.to) }
            return (action, target.map { verb + " " + quoted($0) } ?? verb + " " + (path ?? ""), target != nil ? path : nil)
        case "scroll", "fling":
            let direction = input.direction?.lowercased() ?? ""
            var title = (action == "fling" ? "Fling " : "Scroll ") + direction
            if action == "scroll", let distance = input.distance { title += " " + number(distance) + " pt" }
            if let target { title += " on " + quoted(target) }
            return (action, title, stroke.map { point($0.from) + " → " + point($0.to) })
        case "type", "typetext", "text":
            let text = input.text ?? ""
            return ("type", text.isEmpty ? "Type" : "Type " + quoted(excerpt(text)), nil)
        case "paste":
            let text = input.text ?? ""
            return ("paste", text.isEmpty ? "Paste" : "Paste " + quoted(excerpt(text)), text.count > excerptLength ? "\(text.count) characters" : nil)
        case "shake":
            return ("shake", "Shake", nil)
        case "pose":
            let pose = input.angle.map { SimulatorFoldState.degrees($0) } ?? named(input.name)
            return ("pose", pose.map { "Fold to " + $0 } ?? "Fold", nil)
        case "rotate", "orientation":
            let name = input.name?.lowercased() ?? ""
            if name == "left" || name == "right" { return ("rotate", "Rotate " + name, nil) }
            return ("rotate", "Rotate to " + (SimulatorOrientation(parsing: name)?.title ?? named(input.name) ?? "?"), nil)
        case "terminate":
            return ("terminate", "Terminate " + (named(input.name) ?? "the app"), nil)
        case "launch", "relaunch":
            return ("launch", "Launch " + (named(input.name) ?? "the app"), nil)
        case "software-keyboard":
            let verb = input.visible.map { $0 ? "Show" : "Hide" } ?? "Toggle"
            return ("keyboard", verb + " the software keyboard", nil)
        case "hardware-keyboard":
            return ("keyboard", (input.enabled == false ? "Disconnect" : "Connect") + " the hardware keyboard", nil)
        case "button":
            let name = input.name ?? ""
            if name.lowercased() == "app-switcher" { return ("button", "Open the app switcher", nil) }
            return ("button", "Press " + (name.lowercased() == "home" ? "Home" : name), nil)
        default:
            return (action.isEmpty ? "input" : action, action.isEmpty ? "Input" : action.prefix(1).uppercased() + action.dropFirst(), nil)
        }
    }

    /// The words for a change to the device's settings or a debug action
    /// (`DeviceControlPayload`); what the device reported afterwards goes in
    /// the entry's detail once it is done.
    public static func describe(control: DeviceControlPayload) -> (kind: String, title: String, detail: String?) {
        let action = control.action.lowercased()
        let clear = control.value?.lowercased() == "clear"
        func onOff(_ enabled: Bool?) -> String { enabled == false ? " off" : " on" }
        switch action {
        case "appearance":
            return ("appearance", (control.value?.lowercased() == "dark" ? "Dark" : control.value?.lowercased() == "light" ? "Light" : "Change") + " appearance", nil)
        case "content-size", "text-size":
            let size = control.value.flatMap(SimulatorContentSize.parse) ?? control.value ?? ""
            let title = switch size {
            case "increment": "Larger text"
            case "decrement": "Smaller text"
            default: "Text size " + SimulatorContentSize.short(size)
            }
            return ("text-size", title, nil)
        case "increase-contrast", "contrast":
            return ("contrast", "Increase Contrast" + onOff(control.enabled), nil)
        case "debug":
            let option = control.option.flatMap(SimulatorDebugOption.init(parsing:))
            return ("debug", (option?.title ?? named(control.option) ?? "Debug option") + onOff(control.enabled), nil)
        case "memory-warning":
            return ("memory-warning", "Simulate a memory warning", nil)
        case "biometrics":
            let title = switch control.value.flatMap(SimulatorBiometricAction.init(parsing:)) {
            case .enroll: "Enroll Face ID / Touch ID"
            case .unenroll: "Unenroll Face ID / Touch ID"
            case .match: "Matching face or finger"
            case .nomatch: "Non-matching face or finger"
            case nil: "Biometrics"
            }
            return ("biometrics", title, nil)
        case "push":
            return ("push", "Push to " + (named(control.bundleId) ?? "the app"), control.payload.flatMap(pushAlert).map { quoted(excerpt($0)) })
        case "status-bar":
            return ("status-bar", clear ? "Clear the status bar" : "Status bar " + (control.statusBar?.summary ?? ""), nil)
        case "location":
            if clear { return ("location", "Clear the location", nil) }
            return ("location", "Location " + (control.location?.summary ?? ""), nil)
        case "accessibility":
            let setting = control.option.flatMap(SimulatorAccessibilitySetting.init(parsing:))
            let title = setting?.title ?? named(control.option) ?? "Accessibility"
            let value = control.value.map { setting?.value(parsing: $0) ?? $0 } ?? (control.enabled == false ? "off" : "on")
            return ("accessibility", title + " " + value, nil)
        case "permission":
            let permission = control.option.flatMap(SimulatorPermission.init(parsing:))
            let what = permission?.title ?? named(control.option) ?? "a permission"
            let verb = switch control.value.flatMap(SimulatorPermissionDecision.init(parsing:)) {
            case .grant: "Grant "
            case .always: "Always allow "
            case .deny: "Deny "
            case .reset: "Reset "
            case nil: "Change "
            }
            return ("permission", verb + what, named(control.bundleId).map { "for " + $0 })
        case "keychain":
            let title = switch control.value?.lowercased() {
            case "reset": "Reset the keychain"
            case "add-root-cert": "Trust a root certificate"
            case "add-cert": "Add a certificate to the keychain"
            default: "Keychain"
            }
            return ("keychain", title, nil)
        default:
            return (action.isEmpty ? "device" : action, action.isEmpty ? "Device" : action.prefix(1).uppercased() + action.dropFirst(), nil)
        }
    }

    /// Whether what the device reports afterwards says more than the title:
    /// the size a step landed on, Face ID or Touch ID, every status bar
    /// override in force.
    public static func reportsResult(of control: DeviceControlPayload) -> Bool {
        switch control.action.lowercased() {
        case "content-size", "text-size", "biometrics", "permission": true
        case "status-bar": control.value?.lowercased() != "clear"
        default: false
        }
    }

    /// A push's alert text: `aps.alert` as a string, or its title and body.
    static func pushAlert(_ payload: NetworkLoggerJSONValue) -> String? {
        guard case .object(let root) = payload, case .object(let aps)? = root["aps"] else { return nil }
        switch aps["alert"] {
        case .string(let text)?: return text
        case .object(let alert)?:
            let parts = ["title", "body"].compactMap { key -> String? in
                if case .string(let text)? = alert[key] { return text }
                return nil
            }
            return parts.isEmpty ? nil : parts.joined(separator: " — ")
        default: return nil
        }
    }

    static let excerptLength = 40

    static func excerpt(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        return line.count > excerptLength ? String(line.prefix(excerptLength - 1)) + "…" : line
    }

    static func quoted(_ text: String) -> String { "“" + text + "”" }

    static func point(_ point: TouchPoint) -> String { "\(Int(point.x.rounded())), \(Int(point.y.rounded()))" }

    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func seconds(_ value: Double) -> String { String(format: "%g s", (value * 100).rounded() / 100) }

    private static func named(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
