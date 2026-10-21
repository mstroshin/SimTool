import Foundation

/// A privacy permission an app asks for, as the simulator stores it.
///
/// `simctl privacy` grants most of them (including `camera` and
/// `pasteboard`, which its help leaves out); Face ID, speech recognition and
/// App Tracking Transparency it refuses, so they go into the device's TCC
/// database directly; notifications are SpringBoard's own (`SimulatorNotificationPermission`).
public enum SimulatorPermission: String, CaseIterable, Codable, Sendable {
    case notifications
    case location
    case camera
    case microphone
    case photos
    case photosAdd = "photos-add"
    case contacts
    case calendar
    case reminders
    case motion
    case mediaLibrary = "media-library"
    case siri
    case speech
    case faceID = "faceid"
    case userTracking = "user-tracking"
    case pasteboard

    public var title: String {
        switch self {
        case .notifications: "Notifications"
        case .location: "Location"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .photos: "Photos"
        case .photosAdd: "Add to Photos"
        case .contacts: "Contacts"
        case .calendar: "Calendars"
        case .reminders: "Reminders"
        case .motion: "Motion & Fitness"
        case .mediaLibrary: "Media & Apple Music"
        case .siri: "Siri"
        case .speech: "Speech Recognition"
        case .faceID: "Face ID"
        case .userTracking: "Tracking (ATT)"
        case .pasteboard: "Paste from Other Apps"
        }
    }

    /// The TCC service it is stored under; nil for notifications and location,
    /// which are not TCC's.
    var tccService: String? {
        switch self {
        case .notifications, .location: nil
        case .camera: "kTCCServiceCamera"
        case .microphone: "kTCCServiceMicrophone"
        case .photos: "kTCCServicePhotos"
        case .photosAdd: "kTCCServicePhotosAdd"
        case .contacts: "kTCCServiceAddressBook"
        case .calendar: "kTCCServiceCalendar"
        case .reminders: "kTCCServiceReminders"
        case .motion: "kTCCServiceMotion"
        case .mediaLibrary: "kTCCServiceMediaLibrary"
        case .siri: "kTCCServiceSiri"
        case .speech: "kTCCServiceSpeechRecognition"
        case .faceID: "kTCCServiceFaceID"
        case .userTracking: "kTCCServiceUserTracking"
        case .pasteboard: "kTCCServicePasteboard"
        }
    }

    /// Whether `simctl privacy` takes it (as its raw value).
    var simctlTakesIt: Bool {
        switch self {
        case .notifications, .speech, .faceID, .userTracking: false
        default: true
        }
    }

    public init?(parsing raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        if let permission = Self(rawValue: name) { self = permission; return }
        switch name {
        case "notification", "push", "push-notifications": self = .notifications
        case "location-always", "location-when-in-use": self = .location
        case "mic": self = .microphone
        case "photo-library", "photo": self = .photos
        case "address-book": self = .contacts
        case "calendars", "events": self = .calendar
        case "media", "music": self = .mediaLibrary
        case "speech-recognition": self = .speech
        case "face-id": self = .faceID
        case "att", "tracking", "app-tracking": self = .userTracking
        case "paste", "clipboard": self = .pasteboard
        default: return nil
        }
    }

    public static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }
}

/// What a permission is set to: `grant`, `always` (location in the
/// background), `deny`, or `reset` — back to not asked, so the app prompts
/// again.
public enum SimulatorPermissionDecision: String, CaseIterable, Codable, Sendable {
    case grant, always, deny, reset

    public init?(parsing raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let decision = Self(rawValue: name) { self = decision; return }
        switch name {
        case "allow", "allowed", "granted", "on": self = .grant
        case "revoke", "denied", "off": self = .deny
        case "not-determined", "ask": self = .reset
        default: return nil
        }
    }
}

public enum SimulatorPermissionClient {
    /// What each permission of `bundleId` is set to: `granted`, `always`,
    /// `limited`, `provisional`, `denied` or `not-determined`, keyed by
    /// `SimulatorPermission` name.
    public static func read(bundleId: String, deviceUDID: String) async throws -> [String: String] {
        try check(bundleId)
        var states = Dictionary(uniqueKeysWithValues: SimulatorPermission.allCases.map { ($0.rawValue, "not-determined") })
        let database = deviceLibrary(deviceUDID).appendingPathComponent("TCC/TCC.db")
        if FileManager.default.fileExists(atPath: database.path) {
            let rows = try await sqlite(database, "SELECT service, auth_value FROM access WHERE client='\(bundleId)' AND client_type=0;", readOnly: true)
            for row in rows.split(separator: "\n") {
                let fields = row.split(separator: "|")
                guard fields.count == 2, let value = Int(fields[1]),
                      let permission = SimulatorPermission.allCases.first(where: { $0.tccService == String(fields[0]) }) else { continue }
                states[permission.rawValue] = switch value {
                case 0: "denied"
                case 2: "granted"
                case 3: "limited"
                default: "value \(value)"
                }
            }
        }
        states[SimulatorPermission.location.rawValue] = locationState(bundleId: bundleId, deviceUDID: deviceUDID)
        states[SimulatorPermission.notifications.rawValue] = SimulatorNotificationPermission.state(bundleId: bundleId, deviceUDID: deviceUDID)
        return states
    }

    /// Sets one permission and returns what it reads afterwards. A changed
    /// permission may terminate the app if it runs (as `simctl privacy` says
    /// of its own); notifications respring the simulator, since SpringBoard
    /// reads them only as it starts.
    public static func set(_ permission: SimulatorPermission, to decision: SimulatorPermissionDecision, bundleId: String, deviceUDID: String) async throws -> String {
        try check(bundleId)
        if decision == .always, permission != .location {
            throw SimToolError("Only location takes always; \(permission.title) takes grant, deny or reset")
        }
        switch permission {
        case .notifications:
            try await SimulatorNotificationPermission.set(decision, bundleId: bundleId, deviceUDID: deviceUDID)
        case .location:
            let (action, service) = switch decision {
            case .grant: ("grant", "location")
            case .always: ("grant", "location-always")
            case .deny: ("revoke", "location")
            case .reset: ("reset", "location")
            }
            try await privacy(action, service, bundleId: bundleId, deviceUDID: deviceUDID)
        default:
            if permission.simctlTakesIt {
                try await privacy(decision == .deny ? "revoke" : decision.rawValue, permission.rawValue, bundleId: bundleId, deviceUDID: deviceUDID)
            } else {
                try await setTCC(permission, decision, bundleId: bundleId, deviceUDID: deviceUDID)
            }
        }
        return try await read(bundleId: bundleId, deviceUDID: deviceUDID)[permission.rawValue] ?? "not-determined"
    }

    // MARK: - stores

    private static func privacy(_ action: String, _ service: String, bundleId: String, deviceUDID: String) async throws {
        try SimulatorDeviceControl.check(await ProcessRunner.runXcrun(["simctl", "privacy", deviceUDID, action, service, bundleId]), what: "simctl privacy \(action) \(service)")
    }

    /// A TCC entry written as Settings writes one (auth_reason 2: by the user).
    private static func setTCC(_ permission: SimulatorPermission, _ decision: SimulatorPermissionDecision, bundleId: String, deviceUDID: String) async throws {
        guard let service = permission.tccService else { return }
        let database = deviceLibrary(deviceUDID).appendingPathComponent("TCC/TCC.db")
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw SimToolError("No TCC database for \(deviceUDID) — boot the simulator once first")
        }
        let statement = decision == .reset
            ? "DELETE FROM access WHERE service='\(service)' AND client='\(bundleId)' AND client_type=0;"
            : "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version) VALUES ('\(service)','\(bundleId)',0,\(decision == .deny ? 0 : 2),2,1);"
        _ = try await sqlite(database, statement, readOnly: false)
    }

    private static func sqlite(_ database: URL, _ statement: String, readOnly: Bool) async throws -> String {
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: (readOnly ? ["-readonly"] : []) + ["-cmd", ".timeout 5000", database.path, statement],
            timeoutSeconds: 30
        )
        return try SimulatorDeviceControl.check(output, what: "TCC.db")
    }

    /// locationd's own record (`i<bundle>:` in its clients.plist), which
    /// `simctl privacy` writes: 2 while in use, 4 always, 1 denied.
    static func locationState(bundleId: String, deviceUDID: String) -> String {
        let url = deviceLibrary(deviceUDID).appendingPathComponent("Caches/locationd/clients.plist")
        guard let data = try? Data(contentsOf: url),
              let clients = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let client = clients["i\(bundleId):"] as? [String: Any],
              let value = (client["Authorization"] as? NSNumber)?.intValue else { return "not-determined" }
        return switch value {
        case 1: "denied"
        case 2: "granted"
        case 3, 4: "always"
        default: "not-determined"
        }
    }

    static func deviceLibrary(_ deviceUDID: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices")
            .appendingPathComponent(deviceUDID)
            .appendingPathComponent("data/Library")
    }

    /// A bundle id goes into SQL and plist keys: letters, digits, dots and dashes only.
    static func check(_ bundleId: String) throws {
        guard !bundleId.isEmpty, bundleId.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*$"#, options: .regularExpression) != nil else {
            throw SimToolError("\(bundleId.isEmpty ? "An empty bundle id" : bundleId) is not a bundle identifier")
        }
    }
}

/// Notification permission. No simctl verb sets it: SpringBoard's bulletin
/// board keeps it per app, as a keyed archive of the app's section, in
/// `BulletinBoard/VersionedSectionInfo.plist`; its settings connection takes
/// only entitled callers, and the simulator will not run an ad-hoc-signed
/// helper with that entitlement. So the file is changed and SpringBoard,
/// which reads it once, starts again — with backboardd: a SpringBoard
/// restarted on its own stops turning its interface with the device until the
/// simulator reboots (iOS 26.4), and backboardd brings a whole new one.
public enum SimulatorNotificationPermission {
    static func url(deviceUDID: String) -> URL {
        SimulatorPermissionClient.deviceLibrary(deviceUDID).appendingPathComponent("BulletinBoard/VersionedSectionInfo.plist")
    }

    /// BBSectionInfoSettings' authorizationStatus: 0 not determined, 1 denied,
    /// 2 authorized, 3 provisional, 4 ephemeral.
    static func state(bundleId: String, deviceUDID: String) -> String {
        guard let section = try? sections(deviceUDID: deviceUDID)[bundleId] as? Data,
              let status = authorizationStatus(inSection: section) else { return "not-determined" }
        return switch status {
        case 1: "denied"
        case 2: "granted"
        case 3: "provisional"
        case 4: "ephemeral"
        default: "not-determined"
        }
    }

    static func set(_ decision: SimulatorPermissionDecision, bundleId: String, deviceUDID: String) async throws {
        let file = url(deviceUDID: deviceUDID)
        guard let data = try? Data(contentsOf: file),
              var root = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil) as? [String: Any] else {
            throw SimToolError("SpringBoard has not written its notification settings yet — wait for the simulator to finish booting")
        }
        var sections = root["sectionInfo"] as? [String: Any] ?? [:]
        switch decision {
        case .reset:
            sections[bundleId] = nil
        case .grant, .deny, .always:
            let status = decision == .deny ? 1 : 2
            if let existing = sections[bundleId] as? Data {
                sections[bundleId] = try updated(existing, authorizationStatus: status)
            } else {
                sections[bundleId] = try newSection(bundleId: bundleId, name: await appName(bundleId: bundleId, deviceUDID: deviceUDID), authorizationStatus: status)
            }
        }
        root["sectionInfo"] = sections
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: file, options: .atomic)
        try await respring(deviceUDID: deviceUDID)
    }

    private static func sections(deviceUDID: String) throws -> [String: Any] {
        let data = try Data(contentsOf: url(deviceUDID: deviceUDID))
        let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return root?["sectionInfo"] as? [String: Any] ?? [:]
    }

    /// The archive's settings object is the one dictionary that carries
    /// `authorizationStatus`.
    static func authorizationStatus(inSection data: Data) -> Int? {
        guard let archive = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = archive["$objects"] as? [Any] else { return nil }
        return objects.lazy.compactMap { ($0 as? [String: Any])?["authorizationStatus"] as? NSNumber }.first?.intValue
    }

    /// The section as it was, its status changed: the archive's object
    /// references survive the round trip untouched.
    static func updated(_ data: Data, authorizationStatus status: Int) throws -> Data {
        guard var archive = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil) as? [String: Any],
              var objects = archive["$objects"] as? [Any],
              let index = objects.firstIndex(where: { ($0 as? [String: Any])?["authorizationStatus"] != nil }),
              var settings = objects[index] as? [String: Any] else {
            throw SimToolError("SpringBoard's notification settings for this app are not in a form SimTool knows")
        }
        settings["authorizationStatus"] = status
        objects[index] = settings
        archive["$objects"] = objects
        return try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
    }

    /// A section for an app that never asked: what SpringBoard stores for an
    /// app whose user allowed notifications (banners, sounds, badges,
    /// Notification Center, lock screen) — or denied them.
    static func newSection(bundleId: String, name: String, authorizationStatus status: Int) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("BBSectionInfo", for: BulletinSectionArchive.self)
        archiver.setClassName("BBSectionInfoSettings", for: BulletinSettingsArchive.self)
        archiver.encode(BulletinSectionArchive(bundleId: bundleId, name: name, settings: BulletinSettingsArchive(status: status)), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func appName(bundleId: String, deviceUDID: String) async -> String {
        (try? await SimulatorAppInfoClient.read(bundleId: bundleId, deviceUDID: deviceUDID).name) ?? bundleId
    }

    /// Restarts backboardd, which takes SpringBoard down with it before it can
    /// write its own settings over the file, and waits for launchd to bring a
    /// new SpringBoard up. Running apps end, as on a device that resprings.
    static func respring(deviceUDID: String) async throws {
        let before = await springBoardPID(deviceUDID: deviceUDID)
        try SimulatorDeviceControl.check(
            await ProcessRunner.runXcrun(["simctl", "spawn", deviceUDID, "launchctl", "kill", "SIGTERM", "system/com.apple.backboardd"]),
            what: "Restarting SpringBoard"
        )
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(250))
            if let now = await springBoardPID(deviceUDID: deviceUDID), now != before {
                // Up is not ready: its home screen and services follow.
                try? await Task.sleep(for: .seconds(3))
                return
            }
        }
        throw SimToolError("SpringBoard did not come back within 20 s after the respring")
    }

    private static func springBoardPID(deviceUDID: String) async -> Int? {
        guard let output = try? await ProcessRunner.runXcrun(["simctl", "spawn", deviceUDID, "launchctl", "list"]), output.status == 0 else { return nil }
        for line in output.stdoutString.split(separator: "\n") where line.hasSuffix("\tcom.apple.SpringBoard") {
            return Int(line.split(separator: "\t").first ?? "")
        }
        return nil
    }
}

/// Stand-ins archived under SpringBoard's class names, with the keys it reads.
@objc(SimToolBulletinSection) private final class BulletinSectionArchive: NSObject, NSCoding {
    let bundleId: String
    let name: String
    let settings: BulletinSettingsArchive

    init(bundleId: String, name: String, settings: BulletinSettingsArchive) {
        self.bundleId = bundleId
        self.name = name
        self.settings = settings
    }

    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode(bundleId, forKey: "sectionID")
        coder.encode(name, forKey: "displayName")
        coder.encode(name, forKey: "appName")
        coder.encode(settings, forKey: "sectionInfoSettings")
        coder.encode(NSNumber(value: 0), forKey: "version")
        for key in ["sectionType", "sectionCategory", "subsectionPriority", "suppressedSettings"] { coder.encode(0, forKey: key) }
        for key in ["suppressFromSettings", "isRestricted", "isModificationAllowed", "isAppClip", "hideWeeApp"] { coder.encode(false, forKey: key) }
    }
}

@objc(SimToolBulletinSettings) private final class BulletinSettingsArchive: NSObject, NSCoding {
    let status: Int

    init(status: Int) { self.status = status }

    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        let allowed = status != 1
        coder.encode(status, forKey: "authorizationStatus")
        coder.encode(allowed ? 1 : 0, forKey: "alertType")
        coder.encode(allowed ? 63 : 0, forKey: "pushSettings")
        for key in ["lockScreenSetting", "notificationCenterSetting", "remoteNotificationsSetting", "prioritizationSetting", "summarizationSetting"] { coder.encode(allowed ? 2 : 1, forKey: key) }
        for key in ["announceSetting", "scheduledDeliverySetting"] { coder.encode(1, forKey: key) }
        for key in ["carPlaySetting", "bulletinGroupingSetting", "contentPreviewSetting", "criticalAlertSetting", "timeSensitiveSetting", "announcePriority", "directMessagesSettingKey"] { coder.encode(0, forKey: key) }
        for key in ["showsInLockScreen", "showsInNotificationCenter", "showsOnExternalDevices"] { coder.encode(allowed, forKey: key) }
        for key in ["userConfiguredTimeSensitiveSetting", "userConfiguredDirectMessagesSetting", "showsCustomSettingsLink"] { coder.encode(false, forKey: key) }
    }
}
