import ArgumentParser
import Foundation
import SimToolCore
import SimToolNetworkLogger

// The simulator's settings and debug switches from the command line — what
// Simulator.app kept in its menus and Device Hub dropped. Each command reads
// the setting back without a value and changes it with one; a change is
// reported to the viewers watching the device, as `simtool input` is.

/// Performs one device request and prints what the device reports afterwards.
func runDeviceControl(_ control: DeviceControlPayload, device: SimulatorDevice, app: String? = nil, json: Bool) async throws {
    let result = try await ActivityReporter(device: device).control(control) {
        try await SimulatorDeviceControl.perform(control, deviceUDID: device.udid, app: app)
    }
    if json { try printJSON(CommandResultPayload(ok: true, stdout: result, stderr: "")) } else { print(result) }
}

/// Prints part of the device's settings: JSON, or one aligned line per setting.
func printDeviceSettings(_ settings: SimulatorSettings, json: Bool, lines: [(String, String?)]) throws {
    if json { try printJSON(settings); return }
    let width = lines.map(\.0.count).max() ?? 0
    for (name, value) in lines {
        print(name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + (value ?? "unknown"))
    }
    for (name, reason) in (settings.unavailable ?? [:]).sorted(by: { $0.key < $1.key }) {
        FileHandle.standardError.write(Data("warning: cannot read \(name): \(reason)\n".utf8))
    }
}

private func onOff(_ value: Bool?) -> String? { value.map { $0 ? "on" : "off" } }

private func accessibilityLines(_ settings: SimulatorSettings) -> [(String, String?)] {
    SimulatorAccessibilitySetting.allCases.compactMap { setting in
        let value = settings.accessibility?.value(of: setting)
        // Liquid Glass is absent before iOS 26: no line rather than "unknown".
        if value == nil, setting == .liquidGlass, settings.accessibility != nil { return nil }
        return (setting.rawValue, value)
    }
}

private func parseOnOff(_ raw: String, _ what: String) throws -> Bool {
    switch raw.lowercased() {
    case "on", "true", "yes", "1", "enabled": return true
    case "off", "false", "no", "0", "disabled": return false
    default: throw ValidationError("\(what) takes on or off, not \(raw)")
    }
}

/// The app a command acts on: `--app`, else the project's `bundleId`.
private func configuredApp(_ app: String?) -> String? {
    if let app, !app.isEmpty { return app }
    return (try? ProjectConfigLoader.loadIfPresent())?.bundleId
}

struct UI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "Read or change the appearance, the text size, and the accessibility settings: contrast, motion, transparency, VoiceOver, color filters, Liquid Glass.",
        discussion: """
        `simtool ui` prints them all; `simtool ui <setting>` prints one and \
        `simtool ui <setting> <value>` changes it:

          appearance           light|dark
          text-size            extra-small … extra-extra-extra-large, accessibility-medium … \
        accessibility-extra-extra-extra-large (or xs … xxxl, ax1 … ax5, default, bigger, smaller)
          contrast             on|off   (Increase Contrast)
          reduce-motion        on|off
          reduce-transparency  on|off
          button-shapes        on|off
          voiceover            on|off   (the first time, iOS shows its VoiceOver Gestures sheet)
          color-filter         none|grayscale|protanopia|deuteranopia|tritanopia
          liquid-glass         clear|tinted   (iOS 26 and later)

        Color filters change the setting apps read; the simulator's screen, \
        and so screenshots and the stream, show no filter.
        """
    )

    @Argument(help: "A setting from the list below. Omit it to print every setting.") var setting: String?
    @Argument(help: "The new value. Omit it to print the setting.") var value: String?
    @Option var device: String?
    @OptionGroup var common: CommonJSON

    func run() async throws {
        let device = try await resolveDeviceToDrive(device)
        guard let setting else {
            let settings = await SimulatorDeviceControl.read(deviceUDID: device.udid, parts: [.appearance, .contentSize, .increaseContrast, .accessibility])
            try printDeviceSettings(settings, json: common.json, lines: [
                ("appearance", settings.appearance),
                ("text-size", settings.contentSize.map { "\($0) (\(SimulatorContentSize.short($0)))" }),
                ("contrast", onOff(settings.increaseContrast)),
            ] + accessibilityLines(settings))
            return
        }
        if let accessibility = SimulatorAccessibilitySetting(parsing: setting) {
            guard let value else {
                let settings = await SimulatorDeviceControl.read(deviceUDID: device.udid, parts: [.accessibility])
                try printDeviceSettings(settings, json: common.json, lines: [(accessibility.rawValue, settings.accessibility?.value(of: accessibility))])
                return
            }
            try await runDeviceControl(DeviceControlPayload(action: "accessibility", option: accessibility.rawValue, value: value), device: device, json: common.json)
            return
        }
        let (action, part): (String, SimulatorSettings.Part) = switch setting.lowercased() {
        case "appearance": ("appearance", .appearance)
        case "text-size", "content-size", "textsize": ("content-size", .contentSize)
        case "contrast", "increase-contrast": ("increase-contrast", .increaseContrast)
        default: throw ValidationError("Unknown setting \(setting): use appearance, text-size, contrast or \(SimulatorAccessibilitySetting.names)")
        }
        guard let value else {
            let settings = await SimulatorDeviceControl.read(deviceUDID: device.udid, parts: [part])
            let shown: String? = switch part {
            case .appearance: settings.appearance
            case .contentSize: settings.contentSize
            default: onOff(settings.increaseContrast)
            }
            try printDeviceSettings(settings, json: common.json, lines: [(setting.lowercased(), shown)])
            return
        }
        let control = action == "increase-contrast"
            ? DeviceControlPayload(action: action, enabled: try parseOnOff(value, "contrast"))
            : DeviceControlPayload(action: action, value: value)
        try await runDeviceControl(control, device: device, json: common.json)
    }
}

struct Debug: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Simulator.app's Debug menu: slow animations, the render server's debug colours, a memory warning.",
        discussion: """
        `simtool debug` prints every switch; `simtool debug <option>` prints one and \
        `simtool debug <option> on|off` flips it. Options: slow-animations, \
        color-blended, color-copies, color-misaligned, color-offscreen. \
        `simtool debug memory-warning` sends a memory warning to every app. \
        The colours stay on until turned off (or the simulator reboots).
        """
    )

    @Argument(help: "An option, or memory-warning. Omit it to print every switch.") var option: String?
    @Argument(help: "on or off. Omit it to print the option.") var state: String?
    @Option var device: String?
    @OptionGroup var common: CommonJSON

    func run() async throws {
        let device = try await resolveDeviceToDrive(device)
        if option?.lowercased() == "memory-warning" {
            guard state == nil else { throw ValidationError("memory-warning takes no value") }
            try await runDeviceControl(DeviceControlPayload(action: "memory-warning"), device: device, json: common.json)
            return
        }
        guard let raw = option else {
            let settings = await SimulatorDeviceControl.read(deviceUDID: device.udid, parts: [.debug])
            try printDeviceSettings(settings, json: common.json, lines: SimulatorDebugOption.allCases.map { ($0.rawValue, onOff(settings.debug?[$0.rawValue])) })
            return
        }
        guard let option = SimulatorDebugOption(parsing: raw) else {
            throw ValidationError("Unknown debug option \(raw): use \(SimulatorDebugOption.names) or memory-warning")
        }
        guard let state else {
            let settings = await SimulatorDeviceControl.read(deviceUDID: device.udid, parts: [.debug])
            try printDeviceSettings(settings, json: common.json, lines: [(option.rawValue, onOff(settings.debug?[option.rawValue]))])
            return
        }
        let control = DeviceControlPayload(action: "debug", option: option.rawValue, enabled: try parseOnOff(state, option.rawValue))
        try await runDeviceControl(control, device: device, json: common.json)
    }
}

struct Biometrics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "biometrics",
        abstract: "Enroll Face ID or Touch ID, or answer the prompt on screen with a matching or non-matching face or finger.",
        discussion: """
        `match` and `nomatch` answer a Face ID or Touch ID prompt the app has \
        up — the sensor is the device type's. Enrollment is what \
        LAContext.canEvaluatePolicy reads; without an action it is printed.
        """
    )

    @Argument(help: "enroll, unenroll, match or nomatch. Omit it to print the sensor and whether it is enrolled.") var action: String?
    @Option var device: String?
    @OptionGroup var common: CommonJSON

    func run() async throws {
        let device = try await resolveDeviceToDrive(device)
        guard let action else {
            let settings = await SimulatorDeviceControl.read(deviceUDID: device.udid, deviceType: device.deviceTypeIdentifier, parts: [.biometrics])
            let state = settings.biometrics
            try printDeviceSettings(settings, json: common.json, lines: [
                ("sensor", state.map { $0.kind?.title ?? "none" }),
                ("enrolled", state.map { $0.enrolled ? "yes" : "no" }),
            ])
            return
        }
        guard let parsed = SimulatorBiometricAction(parsing: action) else {
            throw ValidationError("Unknown action \(action): use enroll, unenroll, match or nomatch")
        }
        try await runDeviceControl(DeviceControlPayload(action: "biometrics", value: parsed.rawValue), device: device, json: common.json)
    }
}

struct Push: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Send a push notification to an app (simctl push).",
        discussion: """
        The payload is a JSON object with an `aps` dictionary, at most 4096 bytes: \
        a file, `-` for stdin, or --payload. `--alert` builds a plain one. The \
        app is --app, else the project's bundleId.

          simtool push --alert "Your order shipped"
          simtool push payload.json --app com.example.app
        """
    )

    @Argument(help: "A JSON payload file, or - to read it from stdin.") var file: String?
    @Option(help: "The payload as JSON text.") var payload: String?
    @Option(help: "Send a payload with just this alert text.") var alert: String?
    @Option(help: "The app's bundle identifier.") var app: String?
    @Option var device: String?
    @OptionGroup var common: CommonJSON

    func validate() throws {
        guard [file != nil, payload != nil, alert != nil].filter({ $0 }).count == 1 else {
            throw ValidationError("Give exactly one of a payload file, --payload or --alert")
        }
    }

    func run() async throws {
        let device = try await resolveDeviceToDrive(device)
        guard let bundleId = configuredApp(app) else { throw ValidationError("Pass --app <bundle-id>, or run inside a project whose config names bundleId") }
        let data: Data
        if let alert {
            data = try JSONSerialization.data(withJSONObject: ["aps": ["alert": alert, "sound": "default"]])
        } else if let payload {
            data = Data(payload.utf8)
        } else if file == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: file!))
        }
        let value: NetworkLoggerJSONValue
        do { value = try JSONDecoder().decode(NetworkLoggerJSONValue.self, from: data) } catch {
            throw ValidationError("The payload is not JSON: \(error.localizedDescription)")
        }
        try await runDeviceControl(DeviceControlPayload(action: "push", bundleId: bundleId, payload: value), device: device, json: common.json)
    }
}

struct StatusBar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status-bar",
        abstract: "Override the status bar — time, network, battery — or clear the overrides.",
        discussion: """
        Without arguments it prints the overrides in force. `clean` sets the \
        9:41, full-signal, full-battery bar of a screenshot; `clear` removes \
        every override. Flags override single fields and leave the rest:

          simtool status-bar --time 9:41 --battery-level 20 --battery-state discharging
        """
    )

    @Argument(help: "clean or clear. Omit it to print the overrides, or to override the fields given as flags.") var preset: String?
    @Option(help: "The time (or an ISO date and time).") var time: String?
    @Option(help: "hide, wifi, 3g, 4g, lte, lte-a, lte+, 5g, 5g+, 5g-uwb, 5g-uc.") var dataNetwork: String?
    @Option(help: "searching, failed or active.") var wifiMode: String?
    @Option(help: "0 to 3.") var wifiBars: Int?
    @Option(help: "notSupported, searching, failed or active.") var cellularMode: String?
    @Option(help: "0 to 4.") var cellularBars: Int?
    @Option(help: "The carrier name; empty hides it.") var operatorName: String?
    @Option(help: "charging, charged or discharging.") var batteryState: String?
    @Option(help: "0 to 100.") var batteryLevel: Int?
    @Option var device: String?
    @OptionGroup var common: CommonJSON

    var fields: SimulatorStatusBar {
        SimulatorStatusBar(
            time: time, dataNetwork: dataNetwork, wifiMode: wifiMode, wifiBars: wifiBars, cellularMode: cellularMode,
            cellularBars: cellularBars, operatorName: operatorName, batteryState: batteryState, batteryLevel: batteryLevel
        )
    }

    func validate() throws {
        if let preset, !["clean", "clear"].contains(preset.lowercased()) { throw ValidationError("Unknown preset \(preset): use clean or clear") }
        if preset != nil, !fields.isEmpty { throw ValidationError("Give a preset or fields to override, not both") }
    }

    func run() async throws {
        let device = try await resolveDeviceToDrive(device)
        let control: DeviceControlPayload
        switch preset?.lowercased() {
        case "clear": control = DeviceControlPayload(action: "status-bar", value: "clear")
        case "clean": control = DeviceControlPayload(action: "status-bar", statusBar: .clean)
        default:
            guard !fields.isEmpty else {
                let settings = await SimulatorDeviceControl.read(deviceUDID: device.udid, parts: [.statusBar])
                try printDeviceSettings(settings, json: common.json, lines: [("status bar", settings.statusBar?.summary)])
                return
            }
            control = DeviceControlPayload(action: "status-bar", statusBar: fields)
        }
        try await runDeviceControl(control, device: device, json: common.json)
    }
}

struct Location: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "location",
        abstract: "Set the simulated location, move along a route, or clear it.",
        discussion: """
        Points are latitude,longitude with a dot for decimals:

          simtool location set 37.3349,-122.0090
          simtool location route 37.3349,-122.0090 37.3318,-122.0312 --speed 15
          simtool location clear

        Without an action it prints the location SimTool last set — simctl \
        cannot read one back.
        """
    )

    @Argument(help: "set, route or clear. Omit it to print the location SimTool set.") var action: String?
    @Argument(help: "One point for set; two or more for route.") var points: [String] = []
    @Option(help: "Metres per second along a route (simctl's default: 20).") var speed: Double?
    @Option(help: "Seconds between updates along a route.") var interval: Double?
    @Option(help: "Metres between updates along a route.") var distance: Double?
    @Option var device: String?
    @OptionGroup var common: CommonJSON

    func run() async throws {
        let device = try await resolveDeviceToDrive(device)
        guard let action else {
            let settings = await SimulatorDeviceControl.read(deviceUDID: device.udid, parts: [.location])
            try printDeviceSettings(settings, json: common.json, lines: [("location", settings.location?.summary ?? "none set by SimTool")])
            return
        }
        let waypoints = try points.map { raw -> SimulatorCoordinate in
            guard let point = SimulatorCoordinate(parsing: raw) else { throw ValidationError("\(raw) is not a latitude,longitude pair like 37.3349,-122.0090") }
            return point
        }
        let control: DeviceControlPayload
        switch action.lowercased() {
        case "clear":
            guard waypoints.isEmpty else { throw ValidationError("clear takes no points") }
            control = DeviceControlPayload(action: "location", value: "clear")
        case "set":
            guard waypoints.count == 1 else { throw ValidationError("set takes one point; route takes two or more") }
            control = DeviceControlPayload(action: "location", location: SimulatorLocation(waypoints: waypoints))
        case "route", "start":
            guard waypoints.count >= 2 else { throw ValidationError("A route takes two or more points") }
            control = DeviceControlPayload(action: "location", location: SimulatorLocation(waypoints: waypoints, speed: speed, interval: interval, distance: distance))
        default:
            throw ValidationError("Unknown action \(action): use set, route or clear")
        }
        try await runDeviceControl(control, device: device, json: common.json)
    }
}

struct Settings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "Print every setting `simtool ui`, `debug`, `biometrics`, `status-bar`, `location` and `input rotate` change, as the device reports it."
    )

    @Option var device: String?
    @OptionGroup var common: CommonJSON

    func run() async throws {
        let device = try await resolveDeviceToDrive(device)
        let settings = await SimulatorDeviceControl.read(deviceUDID: device.udid, deviceType: device.deviceTypeIdentifier)
        var lines: [(String, String?)] = [
            ("appearance", settings.appearance),
            ("text-size", settings.contentSize.map { "\($0) (\(SimulatorContentSize.short($0)))" }),
            ("contrast", onOff(settings.increaseContrast)),
        ]
        lines += accessibilityLines(settings)
        lines += SimulatorDebugOption.allCases.map { ($0.rawValue, onOff(settings.debug?[$0.rawValue])) }
        lines += [
            ("biometrics", settings.biometrics.map { ($0.kind?.title ?? "no sensor") + ($0.enrolled ? ", enrolled" : ", not enrolled") }),
            ("status bar", settings.statusBar?.summary),
            ("location", settings.location?.summary ?? "none set by SimTool"),
            ("orientation", settings.orientation?.rawValue),
        ]
        try printDeviceSettings(settings, json: common.json, lines: lines)
    }
}

struct Permissions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "Read an app's privacy permissions, or grant, deny or reset one — notifications included.",
        discussion: """
        `simtool permissions` prints every permission of the app (--app, else the \
        project's bundleId). `grant`, `deny` and `reset` change one; `reset` \
        puts it back to not asked, so the app prompts again; `always` is \
        location in the background. `reset all` resets every one.

          simtool permissions grant camera
          simtool permissions deny notifications
          simtool permissions always location

        Permissions: notifications, location, camera, microphone, photos, \
        photos-add, contacts, calendar, reminders, motion, media-library, siri, \
        speech, faceid, user-tracking, pasteboard. A change may terminate the \
        app if it runs; a notifications change resprings the simulator — \
        SpringBoard reads it only as it starts — which ends running apps.
        """
    )

    @Argument(help: "grant, deny, reset or always. Omit it to print every permission.") var decision: String?
    @Argument(help: "The permission, or all (with reset).") var permission: String?
    @Option(help: "The app's bundle identifier.") var app: String?
    @Option var device: String?
    @OptionGroup var common: CommonJSON

    func run() async throws {
        let device = try await resolveDeviceToDrive(device)
        guard let bundleId = configuredApp(app) else { throw ValidationError("Pass --app <bundle-id>, or run inside a project whose config names bundleId") }
        guard let decision else {
            let states = try await SimulatorPermissionClient.read(bundleId: bundleId, deviceUDID: device.udid)
            if common.json { try printJSON(states); return }
            let width = SimulatorPermission.allCases.map(\.rawValue.count).max() ?? 0
            for permission in SimulatorPermission.allCases {
                print(permission.rawValue.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + (states[permission.rawValue] ?? "unknown"))
            }
            return
        }
        guard let parsed = SimulatorPermissionDecision(parsing: decision) else { throw ValidationError("Unknown decision \(decision): use grant, deny, reset or always") }
        guard let permission else { throw ValidationError("Name the permission: \(SimulatorPermission.names)") }
        if permission.lowercased() == "all" {
            guard parsed == .reset else { throw ValidationError("Only reset takes all") }
            for each in SimulatorPermission.allCases {
                try await runDeviceControl(DeviceControlPayload(action: "permission", option: each.rawValue, value: "reset", bundleId: bundleId), device: device, json: common.json)
            }
            return
        }
        guard let known = SimulatorPermission(parsing: permission) else { throw ValidationError("Unknown permission \(permission): use \(SimulatorPermission.names)") }
        try await runDeviceControl(DeviceControlPayload(action: "permission", option: known.rawValue, value: parsed.rawValue, bundleId: bundleId), device: device, json: common.json)
    }
}

struct Keychain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keychain",
        abstract: "Reset the simulator's keychain, or add a certificate — a proxy's root CA to trust its TLS.",
        discussion: """
          simtool keychain add-root-cert ~/Downloads/proxy-ca.pem   # trusted as a root (Proxyman, Charles, mitmproxy)
          simtool keychain add-cert client.cer
          simtool keychain reset                                     # every item and certificate, gone
        """
    )

    @Argument(help: "reset, add-root-cert or add-cert.") var action: String
    @Argument(help: "The certificate file (PEM or DER).") var file: String?
    @Option var device: String?
    @OptionGroup var common: CommonJSON

    func validate() throws {
        switch action.lowercased() {
        case "reset": if file != nil { throw ValidationError("reset takes no file") }
        case "add-root-cert", "add-cert": if file == nil { throw ValidationError("\(action) takes a certificate file") }
        default: throw ValidationError("Unknown action \(action): use reset, add-root-cert or add-cert")
        }
    }

    func run() async throws {
        let device = try await resolveDeviceToDrive(device)
        let certificate = try file.map { try Data(contentsOf: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)).base64EncodedString() }
        try await runDeviceControl(DeviceControlPayload(action: "keychain", value: action.lowercased(), certificate: certificate), device: device, json: common.json)
    }
}

extension AppCommand {
    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "An installed app's card: version and build, minimum iOS, whether it runs, where its bundle and its data live, its permissions.",
            discussion: "--reveal bundle|data shows the bundle or the data container in the Finder."
        )

        @Option(help: "The app's bundle identifier (default: the project's bundleId).") var app: String?
        @Option(help: "bundle or data: show it in the Finder.") var reveal: String?
        @Option var device: String?
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let device = try await resolveDeviceToDrive(device)
            guard let bundleId = configuredApp(app) else { throw ValidationError("Pass --app <bundle-id>, or run inside a project whose config names bundleId") }
            if let reveal {
                let path = try await SimulatorAppInfoClient.reveal(reveal, bundleId: bundleId, deviceUDID: device.udid)
                if common.json { try printJSON(CommandResultPayload(ok: true, stdout: path, stderr: "")) } else { print(path) }
                return
            }
            let info = try await SimulatorAppInfoClient.read(bundleId: bundleId, deviceUDID: device.udid, permissions: true)
            if common.json { try printJSON(info); return }
            guard info.installed else { print("\(bundleId) is not installed on \(device.name)"); return }
            let lines: [(String, String?)] = [
                ("app", [info.name, bundleId].compactMap { $0 }.joined(separator: " — ")),
                ("version", [info.version, info.build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")),
                ("minimum iOS", info.minimumOS),
                ("running", info.pid.map { "pid \($0)" } ?? "no"),
                ("bundle", info.bundlePath),
                ("data", info.dataContainer),
            ]
            let width = lines.map(\.0.count).max() ?? 0
            for (name, value) in lines { print(name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + (value ?? "unknown")) }
            let granted = (info.permissions ?? [:]).filter { $0.value != "not-determined" }.sorted { $0.key < $1.key }
            print("permissions".padding(toLength: width, withPad: " ", startingAt: 0) + "  " + (granted.isEmpty ? "none asked" : granted.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install a built app on the simulator: a .app bundle, an .ipa, or a tar of a .app."
        )

        @Argument(help: "The .app, .ipa or .tar.") var path: String
        @Option var device: String?
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let device = try await resolveDeviceToDrive(device)
            let installed = try await SimulatorAppInstaller.install(URL(fileURLWithPath: (path as NSString).expandingTildeInPath), deviceUDID: device.udid)
            await ActivityReporter(device: device).done(kind: "install", title: "Install " + installed.name, detail: installed.bundleId)
            if common.json { try printJSON(installed) } else { print("Installed \(installed.name) (\(installed.bundleId))") }
        }
    }
}

extension Input {
    struct Rotate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rotate",
            abstract: "Turn the device — portrait, landscape-left, landscape-right, upside-down, or left / right a quarter — or show how it is held.",
            discussion: """
            As Simulator.app's Rotate Left (⌘←) and Rotate Right (⌘→): the device \
            turns and the app follows if it supports the orientation. The command \
            returns once the device reports the turn. Touches, the accessibility \
            tree and screenshots then read the picture as it is turned.
            """
        )

        @Argument(help: "portrait, landscape-left, landscape-right, upside-down, left or right. Omit it to read the orientation.") var orientation: String?
        @Option var device: String?
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let device = try await resolveDeviceToDrive(device)
            guard let orientation else {
                let now = try await SimulatorOrientation.read(deviceUDID: device.udid)
                if common.json { try printJSON(["orientation": now.rawValue]) } else { print(now.rawValue) }
                return
            }
            let layout = await device.deviceTypeIdentifier.asyncFlatMap { await SimulatorDisplayLayout.load(deviceType: $0) }
            let output = try await ActivityReporter(device: device).command(SimulatorInputPayload(action: "rotate", name: orientation)) {
                let reached = try await SimulatorOrientation.rotate(to: orientation, deviceUDID: device.udid, layout: layout)
                return ProcessOutput(status: 0, stdout: Data(reached.title.utf8))
            }
            await SimulatorDirectInputClient.shared.close()
            try emitCommandResult(output, json: common.json)
        }
    }
}

private extension Optional {
    func asyncFlatMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
