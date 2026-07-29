import ArgumentParser
import Darwin
import Foundation
import Noora
import SimToolClient
import SimToolCore
import SimToolNetworkLogger
import SimToolServer

/// Core owns the model; the CLI-only ability to parse one from a flag is added
/// here so SimToolCore stays free of an ArgumentParser dependency.
extension TestEvidenceLevel: ExpressibleByArgument {}

@main
struct SimTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simtool",
        abstract: "Stream and automate Apple Simulators.",
        version: SimToolVersion.current,
        subcommands: [
            Serve.self,
            Devices.self,
            Sessions.self,
            Status.self,
            Kill.self,
            Doctor.self,
            Input.self,
            AX.self,
            Logs.self,
            Network.self,
            Mock.self,
            AppCommand.self,
            TestCommand.self,
            Run.self,
            Init.self,
            Checksum.self,
            Open.self,
            Interactive.self,
        ],
        defaultSubcommand: Interactive.self
    )
}

struct CommonJSON: ParsableArguments {
    @Flag(name: .long, help: "Print machine-readable JSON to stdout.")
    var json = false
}

struct Devices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List simulators known to xcrun simctl.")

    @OptionGroup var common: CommonJSON

    func run() async throws {
        let devices = try await SimulatorDeviceClient.listDevices()
        let payload = DeviceListPayload(
            devices: devices,
            selected: devices.first(where: { $0.state == "Booted" })?.udid
        )
        if common.json {
            try printJSON(payload)
        } else {
            makeNoora().table(
                headers: ["Name", "Runtime", "State", "UDID"],
                rows: devices.map { [$0.name, $0.runtime, $0.state, $0.udid] }
            )
        }
    }
}

struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List active SimTool sessions.")

    @OptionGroup var common: CommonJSON

    func run() throws {
        let sessions = try SessionStore.shared.list()
        if common.json {
            try printJSON(SessionListPayload(sessions: sessions))
        } else if sessions.isEmpty {
            makeNoora().info("No SimTool sessions found.")
        } else {
            makeNoora().table(
                headers: ["Session", "PID", "Device", "URL"],
                rows: sessions.map { [$0.sessionId, "\($0.pid)", $0.device.name, $0.url] }
            )
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the latest SimTool session.")

    @OptionGroup var common: CommonJSON

    func run() throws {
        let latest = try SessionStore.shared.latest()
        let payload = StatusPayload(session: latest, healthy: latest != nil, message: latest == nil ? "No sessions found" : nil)
        if common.json {
            try printJSON(payload)
        } else if let latest {
            makeNoora().success(.alert("Latest session is running", takeaways: [
                "Open \(latest.url)",
                "Device: \(latest.device.name)",
            ]))
        } else {
            makeNoora().warning("No sessions found")
        }
    }
}

struct Kill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop a SimTool session by id, or the latest session.")

    @Argument(help: "Session id. Defaults to latest session when omitted.")
    var sessionId: String?

    @OptionGroup var common: CommonJSON

    func run() async throws {
        let session: SessionInfo?
        if let sessionId {
            session = try SessionStore.shared.session(id: sessionId)
        } else {
            session = try SessionStore.shared.latest()
        }
        guard let session else { throw SimToolError("No matching session found") }

        // SIGTERM lets the server run its own graceful cleanup (including powering
        // down simulators it booted). Give it a moment; if it won't die, force it
        // and power those simulators down ourselves so a wedged or detached server
        // can't leak the simulator backend.
        Darwin.kill(session.pid, SIGTERM)
        for _ in 0..<60 where isProcessAlive(session.pid) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if isProcessAlive(session.pid) {
            Darwin.kill(session.pid, SIGKILL)
            for udid in session.bootedDevices {
                await SimulatorDeviceClient.shutdown(udid)
            }
        }
        SessionStore.shared.remove(session.sessionId)
        if common.json {
            try printJSON(["killed": session.sessionId])
        } else {
            makeNoora().success("Stopped session \(session.sessionId)")
        }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check local simulator tooling.")

    @OptionGroup var common: CommonJSON

    func run() async throws {
        async let simctl = check(executable: "/usr/bin/xcrun", arguments: ["--find", "simctl"])
        async let axe = check(executable: "/usr/bin/which", arguments: ["axe"])
        let developerDir = DeveloperFrameworks.developerDir()
        let checks = [
            ToolCheck(name: "simctl", available: await simctl.available, detail: await simctl.detail),
            ToolCheck(name: "axe", available: await axe.available, detail: await axe.detail),
            framework(named: "CoreSimulator", developerDir: developerDir),
            framework(named: "SimulatorKit", developerDir: developerDir),
        ]
        if common.json {
            try printJSON(["checks": checks])
        } else {
            makeNoora().table(headers: ["Tool", "Status", "Detail"], rows: checks.map {
                [$0.name, $0.available ? "available" : "missing", $0.detail]
            })
        }
    }

    private func framework(named name: String, developerDir: String) -> ToolCheck {
        if let path = DeveloperFrameworks.frameworkBundlePath(name, developerDir: developerDir) {
            return ToolCheck(name: name, available: true, detail: path)
        }
        let searched = DeveloperFrameworks.candidateBundlePaths(name, developerDir: developerDir).joined(separator: ", ")
        return ToolCheck(name: name, available: false, detail: "not found in: \(searched)")
    }

    private func check(executable: String, arguments: [String]) async -> (available: Bool, detail: String) {
        do {
            let output = try await ProcessRunner.run(executable: URL(fileURLWithPath: executable), arguments: arguments)
            if output.status == 0 {
                let detail = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                return (true, detail)
            }
            return (false, output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

struct ToolCheck: Codable {
    var name: String
    var available: Bool
    var detail: String
}

struct Input: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send input to a simulator.",
        subcommands: [Tap.self, LongPress.self, TypeText.self, Swipe.self, Button.self]
    )
}

extension Input {
    struct Tap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "tap", abstract: "Tap screen coordinates or an accessibility target.")

        @Option var device: String?
        @Option(help: "X coordinate in screen pixels.") var x: Double?
        @Option(help: "Y coordinate in screen pixels.") var y: Double?
        @Option(help: "Accessibility identifier.") var id: String?
        @Option(help: "Accessibility label.") var label: String?
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let device = try await resolveConfiguredDevice(device)
            let output = try await SimulatorInputClient.tap(deviceUDID: device.udid, x: x, y: y, id: id, label: label)
            try emitCommandResult(output, json: common.json)
        }
    }

    struct LongPress: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "long-press",
            abstract: "Touch down, hold, and release on screen coordinates or an accessibility target."
        )

        @Option var device: String?
        @Option(help: "X coordinate in screen pixels.") var x: Double?
        @Option(help: "Y coordinate in screen pixels.") var y: Double?
        @Option(help: "Accessibility identifier.") var id: String?
        @Option(help: "Accessibility label.") var label: String?
        @Option(help: "Hold duration in seconds.") var duration: Double = 1.0
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let device = try await resolveConfiguredDevice(device)
            let output = try await SimulatorInputClient.longPress(
                deviceUDID: device.udid,
                x: x,
                y: y,
                id: id,
                label: label,
                duration: duration
            )
            try emitCommandResult(output, json: common.json)
        }
    }

    struct TypeText: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "type", abstract: "Type text into the focused field.")

        @Argument var text: String
        @Option var device: String?
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let device = try await resolveConfiguredDevice(device)
            let output = try await SimulatorInputClient.typeText(text, deviceUDID: device.udid)
            try emitCommandResult(output, json: common.json)
        }
    }

    struct Swipe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "swipe", abstract: "Swipe from one pixel coordinate to another.")

        @Option var device: String?
        @Option var startX: Double
        @Option var startY: Double
        @Option var endX: Double
        @Option var endY: Double
        @Option(help: "Duration in seconds.") var duration: Double?
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let device = try await resolveConfiguredDevice(device)
            let output = try await SimulatorInputClient.swipe(
                deviceUDID: device.udid,
                startX: startX,
                startY: startY,
                endX: endX,
                endY: endY,
                duration: duration
            )
            try emitCommandResult(output, json: common.json)
        }
    }

    struct Button: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "button", abstract: "Press a simulator hardware button.")

        @Argument(help: "home, lock, side-button, siri, apple-pay") var name: String
        @Option var device: String?
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let device = try await resolveConfiguredDevice(device)
            let output = if name.lowercased() == "home" {
                try await ProcessRunner.runXcrun(["simctl", "launch", device.udid, "com.apple.springboard"])
            } else {
                try await SimulatorInputClient.button(name, deviceUDID: device.udid)
            }
            try emitCommandResult(output, json: common.json)
        }
    }
}

func emitCommandResult(_ output: ProcessOutput, json: Bool) throws {
    if json {
        try printJSON(CommandResultPayload(ok: true, stdout: output.stdoutString, stderr: output.stderrString))
    } else {
        let trimmed = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { makeNoora().success("ok") }
        else { print(trimmed) }
    }
}

struct AX: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ax",
        abstract: "Read simulator accessibility information through AXe.",
        subcommands: [Tree.self, Find.self]
    )
}

extension AX {
    struct Tree: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "tree", abstract: "Print the simulator accessibility tree.")

        @Option var device: String?
        @Flag(help: "Include the raw AXe payload on every node (large; it repeats each subtree).") var raw = false
        @Flag(help: "Print a flat node list instead of the nested tree.") var flat = false
        @Flag(help: "With --flat, keep only nodes that carry an identifier, label, value, or title.") var labeled = false
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let device = try await resolveConfiguredDevice(device)
            if flat {
                let tree = try await SimulatorAccessibilityClient.normalizedTree(deviceUDID: device.udid)
                try printJSON(SimulatorAccessibilityClient.flatten(tree, labeledOnly: labeled))
            } else if common.json || raw {
                try printJSON(try await SimulatorAccessibilityClient.normalizedTree(deviceUDID: device.udid, includeRaw: raw))
            } else {
                let data = try await SimulatorAccessibilityClient.tree(deviceUDID: device.udid)
                FileHandle.standardOutput.write(data)
                if data.last != UInt8(ascii: "\n") { print() }
            }
        }
    }

    struct Find: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "find", abstract: "Find raw accessibility tree lines containing text.")

        @Argument var needle: String
        @Option var device: String?
        @Flag(help: "Include the raw AXe payload on matched nodes.") var raw = false
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let device = try await resolveConfiguredDevice(device)
            let payload = try await SimulatorAccessibilityClient.findNodes(needle: needle, deviceUDID: device.udid, includeRaw: raw)
            if common.json {
                try printJSON(payload)
            } else {
                print(payload.matches.map { match in
                    let node = match.node
                    return [
                        match.path.map(String.init).joined(separator: "."),
                        node.role ?? node.type ?? "node",
                        node.label ?? node.accessibilityIdentifier ?? node.title ?? "",
                    ].joined(separator: "\t")
                }.joined(separator: "\n"))
            }
        }
    }
}

struct Network: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Read simulator network-related diagnostics.",
        subcommands: [Snapshot.self, Events.self]
    )
}

extension Network {
    struct Snapshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "snapshot", abstract: "Collect recent network-related simulator log events.")

        @Option var device: String?
        @Option(help: "Seconds to collect from log stream.") var seconds: Double = 2
        @Option(help: "Maximum number of events to return.") var limit: Int = 200
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let device = try await resolveConfiguredDevice(device)
            let payload = try await SimulatorNetworkClient.snapshot(deviceUDID: device.udid, seconds: seconds, limit: limit)
            if common.json {
                try printJSON(payload)
            } else if payload.events.isEmpty {
                makeNoora().info("No network-related events captured in \(payload.collectedSeconds)s.")
            } else {
                makeNoora().table(headers: ["Time", "Process", "Subsystem", "Message"], rows: payload.events.map {
                    [$0.timestamp ?? "", $0.process ?? "", $0.subsystem ?? "", $0.eventMessage ?? ""]
                })
            }
        }
    }

    struct Events: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "events", abstract: "Read app-emitted HTTP and gRPC network logger events.")

        @Option(help: "Simulator UDID or name for app-container reads.") var device: String?
        @Option(help: "Bundle identifier for app-container reads or server-side filtering.") var app: String?
        @Option(name: .customLong("protocol"), help: "Filter by http or grpc.") var protocolFilter: String?
        @Option(help: "Return events at or after this ISO-8601 timestamp.") var since: String?
        @Option(help: "Maximum number of events to return.") var limit: Int = 200
        @Option(help: "SimTool server URL for live event queries, for example http://127.0.0.1:3200.") var server: String?
        @Option(help: "SimTool server host for live event queries.") var host: String?
        @Option(help: "SimTool server port for live event queries.") var port: UInt16?
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let networkProtocol = try parsedProtocol()
            let payload: NetworkLoggerEventsPayload
            if let serverURL = try serverBaseURL() {
                let client = SimToolClient(baseURL: serverURL)
                payload = try await client.networkLoggerEvents(
                    app: app,
                    networkProtocol: networkProtocol,
                    since: since,
                    limit: limit
                )
            } else {
                guard let app, !app.isEmpty else {
                    throw SimToolError("App-container mode requires --app <bundle-id>; pass --server, --host, or --port for live server mode.")
                }
                let device = try await resolveConfiguredDevice(device)
                payload = try await SimulatorNetworkLoggerClient.events(
                    deviceUDID: device.udid,
                    appBundleID: app,
                    filter: NetworkLoggerEventFilter(networkProtocol: networkProtocol, since: since, limit: limit)
                )
            }

            if common.json {
                try printJSON(payload)
            } else if payload.events.isEmpty {
                makeNoora().info("No app-emitted network logger events captured.")
            } else {
                makeNoora().table(
                    headers: ["Time", "App", "Protocol", "Request", "Status", "Duration", "Error"],
                    rows: payload.events.map { event in
                        [
                            event.timestamp,
                            event.displayApp,
                            event.networkProtocol.rawValue,
                            event.displayRequest,
                            event.displayStatus,
                            event.displayDuration,
                            event.error?.message ?? "",
                        ]
                    }
                )
            }
        }

        private func parsedProtocol() throws -> NetworkLoggerProtocol? {
            guard let protocolFilter, !protocolFilter.isEmpty else { return nil }
            guard let parsed = NetworkLoggerProtocol(rawValue: protocolFilter.lowercased()) else {
                throw SimToolError("Unsupported network logger protocol: \(protocolFilter). Use http or grpc.")
            }
            return parsed
        }

        private func serverBaseURL() throws -> URL? {
            if let server, !server.isEmpty {
                guard let url = URL(string: server) else { throw SimToolError("Invalid server URL: \(server)") }
                return url
            }
            guard host != nil || port != nil else { return nil }
            let host = host ?? "127.0.0.1"
            let port = port ?? 3200
            guard let url = URL(string: "http://\(host):\(port)") else {
                throw SimToolError("Invalid server host or port: \(host):\(port)")
            }
            return url
        }

    }
}

// MARK: - Mock

struct Mock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mock",
        abstract: "Configure mocked backend responses served to the app.",
        subcommands: [Set.self, List.self, Remove.self, Clear.self]
    )

    struct ServerOptions: ParsableArguments {
        @Option(help: "SimTool server URL, for example http://127.0.0.1:3200.") var server: String?
        @Option(help: "SimTool server host.") var host: String?
        @Option(help: "SimTool server port.") var port: UInt16?

        func baseURL() throws -> URL {
            if let server, !server.isEmpty {
                guard let url = URL(string: server) else { throw SimToolError("Invalid server URL: \(server)") }
                return url
            }
            let host = host ?? "127.0.0.1"
            let port = port ?? 3200
            guard let url = URL(string: "http://\(host):\(port)") else {
                throw SimToolError("Invalid server host or port: \(host):\(port)")
            }
            return url
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Add a mock rule.")

        static let knownGRPCStatuses: Swift.Set<String> = [
            "ok", "cancelled", "unknown", "invalidArgument", "deadlineExceeded",
            "notFound", "alreadyExists", "permissionDenied", "resourceExhausted",
            "failedPrecondition", "aborted", "outOfRange", "unimplemented",
            "internal", "unavailable", "dataLoss", "unauthenticated",
        ]

        @Option(help: "gRPC full-method or HTTP path to match. Supports * globbing.") var method: String
        @Option(name: .customLong("match-header"), help: "Header/metadata equality constraint key=value (repeatable).") var matchHeader: [String] = []
        @Option(name: .customLong("match-body"), help: "JSON subset the request must contain.") var matchBody: String?
        @Option(help: "Success response body as JSON (mutually exclusive with --error).") var body: String?
        @Option(help: "gRPC error status name, e.g. unavailable (mutually exclusive with --body).") var error: String?
        @Option(help: "Error status message.") var message: String?
        @Option(help: "Artificial delay before responding, milliseconds.") var delay: Int = 0
        @Option(help: "Skip the first N matches before firing.") var skip: Int = 0
        @Option(help: "Fire at most M times after skip.") var times: Int?
        @OptionGroup var server: ServerOptions
        @OptionGroup var common: CommonJSON

        func makeDraft() throws -> MockRuleDraft {
            var headerMatch: [String: String] = [:]
            for pair in matchHeader {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { throw SimToolError("Invalid --match-header '\(pair)'; expected key=value.") }
                headerMatch[parts[0]] = parts[1]
            }
            let bodyMatch = try matchBody.map { try NetworkLoggerJSON.decoder.decode(NetworkLoggerJSONValue.self, from: Data($0.utf8)) }
            let response: MockResponse
            switch (body, error) {
            case let (body?, nil):
                response = MockResponse(kind: .success, bodyJSON: body)
            case let (nil, error?):
                guard Mock.Set.knownGRPCStatuses.contains(error) else {
                    let known = Mock.Set.knownGRPCStatuses.sorted().joined(separator: ", ")
                    throw SimToolError("Unknown gRPC status '\(error)'. Expected one of: \(known)")
                }
                response = MockResponse(kind: .error, grpcStatus: error, message: message)
            default:
                throw SimToolError("Provide exactly one of --body or --error.")
            }
            return MockRuleDraft(
                match: MockMatch(method: method, headerMatch: headerMatch.isEmpty ? nil : headerMatch, bodyMatch: bodyMatch, skip: skip, times: times),
                response: response,
                delayMs: delay
            )
        }

        func run() async throws {
            let client = SimToolClient(baseURL: try server.baseURL())
            let created = try await client.setMock(try makeDraft())
            if common.json { try printJSON(created) } else { makeNoora().info("Added mock \(created.id) (generation \(created.generation)).") }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List active mock rules.")
        @OptionGroup var server: ServerOptions
        @OptionGroup var common: CommonJSON
        func run() async throws {
            let client = SimToolClient(baseURL: try server.baseURL())
            let payload = try await client.mocks(since: nil)
            if common.json { try printJSON(payload) }
            else if payload.rules.isEmpty { makeNoora().info("No mock rules configured.") }
            else {
                makeNoora().table(
                    headers: ["ID", "Method", "Kind", "Status/Body", "Delay"],
                    rows: payload.rules.map { rule in
                        [rule.id, rule.match.method, rule.response.kind.rawValue,
                         rule.response.kind == .error ? (rule.response.grpcStatus ?? "") : (rule.response.bodyJSON ?? ""),
                         "\(rule.delayMs)ms"]
                    }
                )
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a mock rule by id.")
        @Argument(help: "Mock rule id, e.g. mock-1.") var id: String
        @OptionGroup var server: ServerOptions
        func run() async throws {
            _ = try await SimToolClient(baseURL: try server.baseURL()).removeMock(id: id)
            makeNoora().info("Removed mock \(id).")
        }
    }

    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "clear", abstract: "Remove all mock rules.")
        @OptionGroup var server: ServerOptions
        func run() async throws {
            _ = try await SimToolClient(baseURL: try server.baseURL()).clearMocks()
            makeNoora().info("Cleared all mock rules.")
        }
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Read simulator logs.",
        subcommands: [Tail.self]
    )
}

extension Logs {
    struct Tail: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "tail", abstract: "Print recent simulator logs.")

        @Option var device: String?
        @Option(help: "Bundle id/subsystem prefix filter.") var app: String?
        @Option(help: "Maximum number of lines to print.") var lines: Int = 200
        @Option(help: "Seconds to collect from log stream.") var seconds: Double = 2
        @Flag(name: .customLong("stdout"), help: "Also capture the app's stdout/print output via --console-pty. Requires --app <bundle-id> and terminates and relaunches the app.")
        var captureStdout = false
        @OptionGroup var common: CommonJSON

        func validate() throws {
            if captureStdout && (app?.isEmpty ?? true) {
                throw ValidationError("--stdout capture requires --app <bundle-id> to launch the app's console.")
            }
        }

        func run() async throws {
            let device = try await resolveConfiguredDevice(device)
            if captureStdout {
                try await runCapture(deviceUDID: device.udid)
            } else {
                let tail = try await SimulatorLogsClient.tail(deviceUDID: device.udid, app: app, lines: lines, seconds: seconds)
                if common.json { try printJSON(LogTailPayload(lines: tail)) }
                else { print(tail.joined(separator: "\n")) }
            }
        }

        private func runCapture(deviceUDID: String) async throws {
            guard let app, !app.isEmpty else {
                throw SimToolError("--stdout capture requires --app <bundle-id> to launch the app's console.")
            }
            if !common.json {
                FileHandle.standardError.write(Data("Capturing OSLog + stdout for \(app); the app is terminated and relaunched to attach its console.\n".utf8))
            }
            let store = LogEntryStore(capacity: max(1, lines))
            let capture = SimulatorLogCapture(
                options: SimulatorLogCapture.Options(deviceUDID: deviceUDID, app: app, captureStdout: true, bundleID: app)
            ) { draft in
                store.append(draft)
            }
            try capture.start()
            try? await Task.sleep(for: .seconds(max(0.25, seconds)))
            capture.stop()

            let payload = store.query(since: nil, limit: lines)
            if common.json {
                try printJSON(payload)
            } else if payload.entries.isEmpty {
                print("No log lines captured in \(seconds)s.")
            } else {
                makeNoora().table(
                    headers: ["Time", "Source", "Level", "Message"],
                    rows: payload.entries.map { entry in
                        [entry.timestamp, entry.source.rawValue, entry.level ?? "", entry.message]
                    }
                )
            }
        }
    }
}

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Build, install, and launch simulator apps.",
        subcommands: [Build.self, Launch.self, Test.self]
    )
}

struct AppBuildOptions: ParsableArguments {
    @Option(help: "Xcode workspace path. Mutually exclusive with --project.")
    var workspace: String?

    @Option(help: "Xcode project path. Mutually exclusive with --workspace.")
    var project: String?

    @Option(help: "Xcode scheme to build.")
    var scheme: String?

    @Option(help: "Build configuration. Defaults to Debug.")
    var configuration: String?

    @Option(name: .customLong("derived-data-path"), help: "DerivedData path for xcodebuild products.")
    var derivedDataPath: String?

    @Flag(help: "Force a new xcodebuild run even when the checksum cache is valid.")
    var force = false

    func selection() throws -> SimulatorAppBuildSelection {
        try SimulatorAppBuildSelection.validated(
            workspacePath: workspace,
            projectPath: project,
            scheme: scheme,
            configuration: configuration,
            derivedDataPath: derivedDataPath
        )
    }
}

struct AppTestOptions: ParsableArguments {
    @Option(help: "Xcode workspace path. Mutually exclusive with --project.")
    var workspace: String?

    @Option(help: "Xcode project path. Mutually exclusive with --workspace.")
    var project: String?

    @Option(help: "Xcode scheme to test.")
    var scheme: String?

    @Option(help: "Build configuration. Defaults to Debug.")
    var configuration: String?

    @Option(name: .customLong("derived-data-path"), help: "DerivedData path for xcodebuild products.")
    var derivedDataPath: String?

    func selection() throws -> SimulatorAppBuildSelection {
        try SimulatorAppBuildSelection.validated(
            workspacePath: workspace,
            projectPath: project,
            scheme: scheme,
            configuration: configuration,
            derivedDataPath: derivedDataPath
        )
    }
}

/// Noora keys interactive rendering off stdin (and NO_TTY), but the animated
/// spinner writes ANSI erase codes to stdout. Render interactively only when
/// both agree, so redirected stdout gets plain stage lines without live spam.
private func interactiveProgressTerminal() -> (noora: Noora, isInteractive: Bool) {
    let isInteractive = Terminal.isInteractive() && isatty(STDOUT_FILENO) == 1
    return (makeNoora(isInteractive: isInteractive), isInteractive)
}

private func liveStatusForwarder(
    stage: String,
    isInteractive: Bool,
    updateMessage: @escaping @Sendable (String) -> Void
) -> (@Sendable (String) -> Void)? {
    guard isInteractive else { return nil }
    let relay = ProgressStatusRelay(prefix: stage, update: updateMessage)
    return { relay.send($0) }
}

/// Resolves the simulator a command should drive, defaulting to the project's
/// configured one. Every command that takes `--device` goes through here, so a
/// checkout with a `simulator:` never has to repeat it — and a machine with
/// several booted simulators gets an error instead of a coin flip.
///
/// A config that exists but does not parse is an error worth surfacing: silently
/// falling back to "first booted" is how a command ends up driving the wrong
/// simulator.
func resolveConfiguredDevice(_ value: String?) async throws -> SimulatorDevice {
    let configured = try ProjectConfigLoader.loadIfPresent()?.simulator
    return try await SimulatorDeviceClient.resolve(value, configuredSimulator: configured)
}

func resolveSimulatorWithProgress(_ nameOrUDID: String?) async throws -> SimulatorDevice {
    let (noora, _) = interactiveProgressTerminal()
    return try await noora.progressStep(
        message: "Resolving simulator",
        successMessage: "Resolved simulator",
        errorMessage: "Failed to resolve simulator",
        showSpinner: true
    ) { _ in
        try await resolveConfiguredDevice(nameOrUDID)
    }
}

func bootSimulatorWithProgress(_ device: SimulatorDevice) async throws -> SimulatorDevice {
    let (noora, _) = interactiveProgressTerminal()
    return try await noora.progressStep(
        message: "Booting \(device.name)",
        successMessage: "Booted \(device.name)",
        errorMessage: "Failed to boot \(device.name)",
        showSpinner: true
    ) { _ in
        try await SimulatorDeviceClient.ensureBooted(device)
    }
}

func buildAppWithProgress(
    selection: SimulatorAppBuildSelection,
    force: Bool,
    cache: SimulatorAppBuildCache
) async throws -> SimulatorAppBuildPayload {
    let scheme = selection.identity.scheme
    let configuration = selection.identity.configuration

    // Checksum stage: fingerprint the sources and resolve the cache. Kept
    // separate from the build so a slow fingerprint on a large project reads as
    // its own step rather than stalling silently under "Building".
    let (checksumNoora, _) = interactiveProgressTerminal()
    let plan = try await checksumNoora.progressStep(
        message: "Checking sources",
        successMessage: "Checked sources",
        errorMessage: "Failed to checksum sources",
        showSpinner: true
    ) { _ in
        try SimulatorAppLifecycleClient.plan(selection: selection, force: force, cache: cache)
    }

    let stage = "Building \(scheme) (\(configuration))"
    let (noora, interactive) = interactiveProgressTerminal()
    return try await noora.progressStep(
        message: plan.isCacheHit ? "Reusing cached build" : stage,
        successMessage: plan.isCacheHit ? "Reused cached build (checksum match)" : "Built \(scheme) (\(configuration))",
        errorMessage: "Build failed for \(scheme)",
        showSpinner: true
    ) { updateMessage in
        return try await SimulatorAppLifecycleClient.build(
            plan: plan,
            cache: cache,
            progress: liveStatusForwarder(stage: stage, isInteractive: interactive, updateMessage: updateMessage)
        )
    }
}

func installAndLaunchAppWithProgress(
    build buildPayload: SimulatorAppBuildPayload,
    device: SimulatorDevice,
    launchEnvironment: [String: String] = [:],
    launchArguments: [String] = [],
    force: Bool,
    cache: SimulatorAppBuildCache
) async throws -> SimulatorAppLaunchPayload {
    let stage = "Launching \(buildPayload.identity.scheme)"
    let (noora, interactive) = interactiveProgressTerminal()
    return try await noora.progressStep(
        message: stage,
        successMessage: "Launched \(buildPayload.bundleIdentifier)",
        errorMessage: "Launch failed for \(buildPayload.bundleIdentifier)",
        showSpinner: true
    ) { updateMessage in
        return try await SimulatorAppLifecycleClient.installAndLaunch(
            build: buildPayload,
            device: device,
            launchEnvironment: launchEnvironment,
            launchArguments: launchArguments,
            force: force,
            cache: cache,
            progress: liveStatusForwarder(stage: stage, isInteractive: interactive, updateMessage: updateMessage)
        )
    }
}

extension AppCommand {
    struct Build: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "build", abstract: "Build an iOS simulator app with checksum caching.")

        @OptionGroup var buildOptions: AppBuildOptions
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let selection = try buildOptions.selection()
            let buildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve())
            if common.json {
                let payload = try await SimulatorAppLifecycleClient.build(
                    selection: selection,
                    force: buildOptions.force,
                    cache: buildCache
                )
                try printJSON(payload)
                return
            }
            let payload = try await buildAppWithProgress(selection: selection, force: buildOptions.force, cache: buildCache)
            if payload.cacheHit {
                makeNoora().success(.alert("Reused cached build", takeaways: [
                    "Scheme: \(payload.identity.scheme)",
                    "Bundle: \(payload.bundleIdentifier)",
                    "App: \(payload.appBundlePath)",
                    "Checksum: \(payload.checksum)",
                ]))
            } else {
                makeNoora().success(.alert("Built app", takeaways: [
                    "Scheme: \(payload.identity.scheme)",
                    "Bundle: \(payload.bundleIdentifier)",
                    "App: \(payload.appBundlePath)",
                    "Checksum: \(payload.checksum)",
                ]))
            }
        }
    }

    struct Launch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "launch", abstract: "Build if needed, install if needed, and launch an app on a simulator.")

        @Option(name: .shortAndLong, help: "Simulator UDID or name. Defaults to the first booted simulator.")
        var device: String?

        @Option(name: .customLong("env"), help: "Runtime environment entry for the app process, in KEY=VALUE format. Repeatable.")
        var environment: [String] = []

        @Argument(parsing: .postTerminator, help: "Launch arguments forwarded verbatim to the app after the bundle id (everything after `--`). Reach the app via CommandLine.arguments, e.g. `-- -DebugFlag 1234`.")
        var launchArguments: [String] = []

        @OptionGroup var buildOptions: AppBuildOptions
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let launchEnvironment = try SimulatorAppLifecycleClient.parseLaunchEnvironment(environment)
            let selection = try buildOptions.selection()
            let buildCache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve())
            if common.json {
                let resolved = try await resolveConfiguredDevice(device)
                let payload = try await SimulatorAppLifecycleClient.launch(
                    selection: selection,
                    device: resolved,
                    launchEnvironment: launchEnvironment,
                    launchArguments: launchArguments,
                    force: buildOptions.force,
                    cache: buildCache
                )
                try printJSON(payload)
                return
            }
            let resolved = try await resolveSimulatorWithProgress(device)
            let buildPayload = try await buildAppWithProgress(selection: selection, force: buildOptions.force, cache: buildCache)
            let payload = try await installAndLaunchAppWithProgress(
                build: buildPayload,
                device: resolved,
                launchEnvironment: launchEnvironment,
                launchArguments: launchArguments,
                force: buildOptions.force,
                cache: buildCache
            )
            let buildAction = payload.build.xcodebuildRan ? "built" : "reused"
            let installAction = payload.installRan ? "installed" : "already installed"
            var takeaways: [TerminalText] = [
                "Device: \(payload.device.name)",
                "Bundle: \(payload.build.bundleIdentifier)",
                "Build: \(buildAction)",
                "Install: \(installAction)",
            ]
            if !payload.launchArguments.isEmpty {
                takeaways.append("Launch args: \(payload.launchArguments.joined(separator: " "))")
            }
            makeNoora().success(.alert("Launched app", takeaways: takeaways))
        }
    }

    struct Test: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "test", abstract: "Run XCTest or UI test schemes on a simulator.")

        @Option(name: .shortAndLong, help: "Simulator UDID or name. Defaults to the first booted simulator.")
        var device: String?

        @OptionGroup var testOptions: AppTestOptions
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let resolved = try await resolveConfiguredDevice(device)
            let payload = try await SimulatorAppLifecycleClient.test(
                selection: try testOptions.selection(),
                device: resolved
            )
            if common.json {
                try printJSON(payload)
            } else if payload.passed {
                makeNoora().success(.alert("Tests passed", takeaways: [
                    "Device: \(payload.device.name)",
                    "Scheme: \(payload.identity.scheme)",
                ]))
            } else {
                makeNoora().warning("Tests failed for scheme \(payload.identity.scheme) on \(payload.device.name). Status: \(payload.xcodebuild.status ?? -1)")
            }
        }
    }
}

struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run declarative YAML UI tests on the served simulator, recorded as test sessions.",
        subcommands: [Run.self, List.self]
    )

    struct ServerOptions: ParsableArguments {
        @Option(help: "SimTool server URL. Defaults to the latest running session's API.")
        var server: String?

        func client() throws -> SimToolClient {
            if let server, !server.isEmpty {
                guard let url = URL(string: server) else { throw SimToolError("Invalid server URL: \(server)") }
                return SimToolClient(baseURL: url)
            }
            guard let session = try SessionStore.shared.latest(), let url = URL(string: session.api) else {
                throw SimToolError("No running SimTool server found. Start one with `simtool serve` or pass --server.")
            }
            return SimToolClient(baseURL: url)
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a declarative YAML UI test on the served simulator, recorded as a test session.",
            discussion: """
            Test file format:

              name: Settings flow
              kind: feature                   # optional; bug | feature — makes this a verifying test
              reference: "PROJ-42"            # optional; free-form, stored but never parsed
              description: >                  # optional; what is tested and the expected result
                Opening Settings displays the preferences screen and
                lets the user enable an option.
              app: com.example.demo           # optional; relaunched before steps
              variables:                      # optional; values for the ${VAR} below
                ACCOUNT: "+34600000000"       #   the account this test runs as
              launch:                         # optional; how to launch it
                profile: staging-account1     #   a `profiles:` entry from .simtool/config.yml
                arguments: [-UITesting]       #   appended after the profile's arguments
                env: { SOME_FLAG: "1" }       #   exported to the app as SIMCTL_CHILD_*
                deeplink: myapp://settings    #   opened once the app is running
              reset:                          # optional; simulator state, before launch
                defaults: true                #   clear the app's UserDefaults
                container: false              #   wipe the app's data container
                permissions: { att: deny, location: grant }
                locale: es_ES                 #   as -AppleLocale / -AppleLanguages
                language: es
              mocks:                          # optional; backend answers, before launch
                - method: "*/GetSettings"     #   gRPC full-method or HTTP path, `*` globs
                  body: { items: [] }         #   YAML or a JSON string (or `error: unavailable`)
                  strict: true                #   must fire, or the run is reported as infra
              setup:                          # optional; shell commands run before launch,
                - xcrun simctl spawn {udid} … #   {udid}/{app} substituted, failures recorded
              timeout: 10                     # default per-step wait, seconds
              steps:
                - waitFor: { id: settingsButton, timeout: 20 }
                - tap: { id: settingsButton }
                - longPress: { id: optionToggle, duration: 1.5 }
                - type: "hello"
                - swipe: up
                - assertVisible: { text: "Welcome", criterion: AC-1 }
                - assertHidden: { label: "Loading" }
                - wait: 2

            Every step polls the accessibility tree until its target appears (or
            disappears for assertHidden), so tests need no explicit sleeps.
            Setup commands reset persisted state; their exit codes are recorded
            in the session but never fail the test.

            `${VAR}` in a launch profile, in this test's own arguments or in a
            setup command is resolved from `variables:` first, then from the
            environment; `--var NAME=value` overrides both. A reference nothing
            defines fails the run before the simulator is touched. Writing the
            account under `variables:` is what makes a test say which account it
            runs as and travel ready-to-run — at the cost of carrying that value
            in the file. Leave it out of `variables:` to keep it in the shell
            instead.

            An assertion carrying `criterion:` is part of the claim the test
            verifies; every other step merely stages it. That is what lets a run
            report a verdict instead of a bare pass/fail:

              satisfied    (exit 0)  every criterion held — the bug does not
                                     reproduce, or the feature is confirmed
              unsatisfied  (exit 1)  a criterion did not hold — the bug
                                     reproduces, or the feature is not done
              inconclusive (exit 2)  the run never reached a criterion, so the
                                     claim was not tested; fix the test
              infra        (exit 3)  the run cannot be trusted: a strict mock
                                     never fired, the app never picked up its
                                     mock rules, `reset:` failed

            A `kind: bug` run stops at the first unmet criterion; a
            `kind: feature` run reports all of them. Tests with no `kind:` keep
            the old behaviour: pass (0) or fail (1).
            """
        )

        @Argument(help: "Path to a YAML test file.")
        var test: String

        @Option(help: "Test session title. Defaults to the test's `name`, then the file name.")
        var title: String?

        @Flag(help: "Run the test without recording a session.")
        var noSession = false

        @Option(help: "Evidence to collect alongside the run: none, failure or full.")
        var evidence: TestEvidenceLevel = .failure

        @Option(name: .customLong("repeat"), help: "Run the test this many times; the report says how many runs held the claim.")
        var repeatCount: Int = 1

        @Option(help: "Path to .simtool/config.yml, for launch profiles and the default app.")
        var config: String?

        @Option(name: .customLong("var"), help: "Override a ${VAR} as NAME=value. Wins over the test's `variables:` and over the environment; repeatable.")
        var variables: [String] = []

        @OptionGroup var serverOptions: ServerOptions
        @OptionGroup var common: CommonJSON

        func run() async throws {
            guard repeatCount >= 1 else { throw SimToolError("--repeat must be at least 1.") }
            let overrides = try Self.parseVariableOverrides(variables)
            let projectConfig = try ProjectConfigLoader.loadIfPresent(explicitPath: config)
            let testURL = URL(fileURLWithPath: test)
            let parsed = try TestDefinitionParser.load(contentsOf: testURL)
            let missing = Self.unresolvedVariables(
                test: parsed,
                profiles: projectConfig?.profiles ?? [],
                environment: ProcessInfo.processInfo.environment,
                overrides: overrides
            )
            if !missing.isEmpty {
                let one = missing.count == 1
                throw SimToolError("""
                    This test refers to \(missing.joined(separator: ", ")) without defining \(one ? "it" : "them") — \
                    usually the account it runs as. Export \(one ? "it" : "them"), pass `--var \(missing[0])=…`, \
                    or add \(one ? "it" : "them") under `variables:` in the test.
                    """)
            }
            if !common.json, let description = parsed.description {
                print(description)
            }
            let client = try serverOptions.client()

            var results: [TestRunResult] = []
            for attempt in 1...repeatCount {
                if repeatCount > 1, !common.json {
                    print("Run \(attempt)/\(repeatCount)")
                }
                let executor = TestRunExecutor(
                    client: client,
                    options: TestRunOptions(
                        title: title,
                        testFile: testURL,
                        recordSession: !noSession,
                        evidence: evidence,
                        profiles: projectConfig?.profiles ?? [],
                        defaultApp: projectConfig?.bundleId,
                        appFacingServerURL: projectConfig?.appFacingServerURL,
                        projectRoot: projectConfig?.simtoolDirectory.deletingLastPathComponent(),
                        variableOverrides: overrides
                    )
                )
                if !common.json {
                    executor.onNarration = { print($0) }
                }
                results.append(await executor.run(parsed))
                // A run that cannot be trusted will not become trustworthy by
                // being repeated, and repeating a reproduction that already
                // succeeded only costs minutes.
                if let last = results.last, last.verdict == .infra || last.cancelled { break }
            }

            let report = Self.report(for: results, test: parsed, file: testURL)
            if common.json {
                try printJSON(report)
            } else {
                Self.printReport(report)
            }
            let code = report.verdict.exitCode
            if code != 0 { throw ExitCode(code) }
        }

        static func parseVariableOverrides(_ raw: [String]) throws -> [String: String] {
            var overrides: [String: String] = [:]
            for entry in raw {
                guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else {
                    throw SimToolError("--var expects NAME=value, got \"\(entry)\".")
                }
                overrides[String(entry[entry.startIndex..<separator])] = String(entry[entry.index(after: separator)...])
            }
            return overrides
        }

        /// `${VAR}` the test refers to and nothing supplies: not its own
        /// `variables:`, not the environment, not `--var`.
        ///
        /// Checked before the run touches the simulator, because that is where
        /// this fails for the person a test was handed to: `expand` would report
        /// it too, but only after the boot, the reset and the mocks — and a name
        /// referenced only from `setup:` would never be reported at all, since
        /// the shell expands an unset variable to nothing.
        static func unresolvedVariables(
            test: TestDefinition,
            profiles: [LaunchProfile],
            environment: [String: String],
            overrides: [String: String]
        ) -> [String] {
            let profile = profiles.first { $0.name == test.launch.profile }
            let launch = test.launch.resolved(profile: profile)
            let available = test.resolvedVariables(environment: environment, overrides: overrides)
            return LaunchVariables.names(in: launch, setup: test.setup)
                .filter { (available[$0] ?? "").isEmpty }
        }

        /// Aggregates one or more runs. The worst answer wins, in the order
        /// infra → unsatisfied → inconclusive → satisfied: a run that saw the
        /// claim fail outranks one that learned nothing, and an untrustworthy
        /// run outranks both.
        static func report(for results: [TestRunResult], test: TestDefinition, file: URL) -> TestRunReport {
            let ranking: [TestVerdict] = [.infra, .unsatisfied, .inconclusive, .satisfied]
            let verdict = ranking.first { verdict in results.contains { $0.verdict == verdict } } ?? .inconclusive
            let last = results.last
            let satisfiedRuns = results.filter { $0.verdict == .satisfied }.count
            return TestRunReport(
                verdict: verdict,
                headline: verdict.headline(for: test.kind),
                kind: test.kind,
                reference: test.reference,
                name: test.name,
                file: file.lastPathComponent,
                criteria: last?.criteria ?? [],
                failures: results.flatMap(\.failures),
                mocks: last?.mocks ?? [],
                completedSteps: last?.completedSteps ?? 0,
                totalSteps: test.steps.count,
                runs: results.count > 1 ? TestRunReport.Runs(total: results.count, satisfied: satisfiedRuns) : nil,
                sessions: results.compactMap { $0.session?.id },
                evidence: last?.evidence ?? [],
                infraReason: results.compactMap(\.infraReason).first
            )
        }

        static func printReport(_ report: TestRunReport) {
            var takeaways: [String] = []
            if let runs = report.runs {
                takeaways.append("Claim held in \(runs.satisfied)/\(runs.total) runs" + (runs.isFlaky ? " — intermittent" : ""))
            }
            for criterion in report.criteria {
                let mark = switch criterion.status {
                case .met: "✓"
                case .unmet: "✗"
                case .unchecked: "–"
                }
                let detail = criterion.detail.map { ": \($0)" } ?? ""
                takeaways.append("\(mark) \(criterion.label)\(detail)")
            }
            if let reason = report.infraReason { takeaways.append(reason) }
            for mock in report.mocks where mock.hits == 0 {
                takeaways.append("Mock \(mock.method) never fired")
            }
            takeaways += report.sessions.map { "Session: \($0)" }
            let rendered = takeaways.map { TerminalText("\($0)") }
            if report.verdict == .satisfied {
                makeNoora().success(.alert(TerminalText("\(report.headline)"), takeaways: rendered))
            } else {
                makeNoora().error(.alert(TerminalText("\(report.headline)"), takeaways: rendered))
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List recorded test sessions.")

        @OptionGroup var serverOptions: ServerOptions
        @OptionGroup var common: CommonJSON

        func run() async throws {
            let payload = try await serverOptions.client().testSessions()
            if common.json {
                try printJSON(payload)
            } else if payload.sessions.isEmpty {
                makeNoora().info("No test sessions recorded.")
            } else {
                makeNoora().table(
                    headers: ["Session", "Title", "Status", "Verdict", "Entries"],
                    rows: payload.sessions.map {
                        [$0.id, $0.title, $0.status.rawValue, $0.verdict?.rawValue ?? "—", "\($0.entries.count)"]
                    }
                )
            }
        }
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start a local simulator stream server.")

    @Option(name: .shortAndLong, help: "Simulator UDID or name. Defaults to `simulator:` from .simtool/config.yml, else the first booted simulator.")
    var device: String?

    @Option(help: "App bundle id to scope log capture to by default (enables stdout/print capture, restarts the app).")
    var app: String?

    @Option(name: .shortAndLong, help: "HTTP port. Defaults to `server.port` from .simtool/config.yml, else 3200.")
    var port: UInt16?

    @Option(help: "Host to bind. Defaults to `server.host` from .simtool/config.yml, else 127.0.0.1.")
    var host: String?

    @Option(help: "Path to the project config supplying the defaults above. Defaults to .simtool/config.yml discovered from the working directory upward; serve also works without one.")
    var config: String?

    @Flag(help: "Start in the background and print session details.")
    var detach = false

    @Flag(help: "Open the browser viewer automatically. The server always starts and prints its URL.")
    var web = false

    @Flag(help: "Deprecated no-op: the browser is no longer opened automatically; pass --web to open it.")
    var noOpen = false

    @Flag(name: .long, help: "Print verbose diagnostic output to stderr.")
    var verbose = false

    @Option(help: .hidden)
    var sessionId: String?

    @Flag(help: .hidden)
    var detachedChild = false

    @OptionGroup var common: CommonJSON

    func run() async throws {
        DebugLog.isEnabled = verbose
        let parameters = try resolveParameters()
        if detach {
            try await runDetached(parameters)
            return
        }
        // Boot via simctl when needed: the web viewer streams the framebuffer
        // directly, so serving never requires the Simulator.app window.
        let booted: SimulatorDevice
        if common.json || detachedChild {
            let resolved = try await SimulatorDeviceClient.resolve(parameters.device)
            booted = try await SimulatorDeviceClient.ensureBooted(resolved)
        } else {
            let resolved = try await resolveSimulatorWithProgress(parameters.device)
            booted = try await bootSimulatorWithProgress(resolved)
        }
        try await runViewer(
            device: booted,
            host: parameters.host,
            port: parameters.port,
            defaultLogApp: app.flatMap { $0.isEmpty ? nil : $0 },
            testSessionsRoot: SimToolDirectory.testSessionsDirectory(in: SimToolDirectory.resolve()),
            testsRoot: SimToolDirectory.testsDirectory(in: SimToolDirectory.resolve()),
            printSessionJSON: common.json || detachedChild,
            openBrowser: shouldOpenBrowser(webRequested: web, json: common.json, detachedChild: detachedChild),
            sessionId: sessionId,
            // Re-read rather than thread through ServeParameters: the viewer
            // needs the launch profiles, which are not part of the serve target.
            projectConfig: try? ProjectConfigLoader.loadIfPresent(explicitPath: config)
        )
    }

    private func resolveParameters() throws -> ServeParameters {
        // Load the config only when a flag is missing (or --config was given):
        // a fully explicit invocation must not fail on an unrelated broken config.
        let projectConfig: ProjectConfig?
        if config != nil || device == nil || host == nil || port == nil {
            projectConfig = try ProjectConfigLoader.loadIfPresent(explicitPath: config)
        } else {
            projectConfig = nil
        }
        return ServeParameters.resolve(device: device, host: host, port: port, config: projectConfig)
    }

    private func runDetached(_ parameters: ServeParameters) async throws {
        try await launchDetachedServer(parameters: parameters, app: app, verbose: verbose, json: common.json)
    }
}

/// The effective `serve` target: explicit flags win, then `.simtool/config.yml`
/// (`simulator:`, `server.host`, `server.port`), then built-in defaults.
struct ServeParameters: Equatable {
    var device: String?
    var host: String
    var port: UInt16

    static func resolve(device: String?, host: String?, port: UInt16?, config: ProjectConfig?) -> ServeParameters {
        ServeParameters(
            device: device ?? config?.simulator,
            host: host ?? config?.server.host ?? "127.0.0.1",
            port: port ?? config?.server.port ?? 3200
        )
    }
}

/// Spawns a background `serve --detached-child` process (inheriting this
/// process's environment, including the `SIMCTL_CHILD_` logger exports), waits
/// for it to report a session, and prints the session with its viewer URL.
func launchDetachedServer(parameters: ServeParameters, app: String?, verbose: Bool, json: Bool) async throws {
    let id = UUID().uuidString
    try SessionStore.shared.ensureRoot()
    let logPath = SessionStore.shared.logPath(for: id)
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let process = Process()
    process.executableURL = executable
    var args = ["serve", "--port", "\(parameters.port)", "--host", parameters.host, "--session-id", id, "--detached-child"]
    if let device = parameters.device { args += ["--device", device] }
    if let app, !app.isEmpty { args += ["--app", app] }
    if verbose { args += ["--verbose"] }
    process.arguments = args
    let log = try FileHandle(forWritingTo: logPath.creatingFileIfNeeded())
    process.standardOutput = log
    process.standardError = log
    try process.run()

    // The child may have to boot the simulator first (up to ensureBooted's
    // 300-second budget), so poll generously but fail as soon as it dies.
    let deadline = Date().addingTimeInterval(330)
    while Date() < deadline {
        if let session = try SessionStore.shared.session(id: id) {
            if json { try printJSON(session) }
            else { makeNoora().success(.alert("SimTool server started", takeaways: ["Open \(session.url)"])) }
            return
        }
        if !process.isRunning {
            throw SimToolError("Detached server exited before reporting a session. See \(logPath.path)")
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw SimToolError("Detached server did not report a session within 330 seconds. See \(logPath.path)")
}

/// The browser viewer is opt-in: it opens only when the user passes `--web`, and
/// never for machine-facing invocations (JSON output, detached children). The
/// server starts and prints its URL regardless.
func shouldOpenBrowser(webRequested: Bool, json: Bool, detachedChild: Bool) -> Bool {
    webRequested && !json && !detachedChild
}

/// Shared simulator-stream viewer bootstrap used by both `serve` and `run`:
/// start the server (reclaiming the port if needed), persist the session,
/// install signal handlers, report it, optionally open the browser, and block
/// in the foreground until interrupted.
func runViewer(
    device: SimulatorDevice,
    host: String,
    port: UInt16,
    defaultLogApp: String?,
    testSessionsRoot: URL,
    testsRoot: URL,
    printSessionJSON: Bool,
    openBrowser: Bool,
    sessionId: String?,
    projectConfig: ProjectConfig? = nil
) async throws {
    let id = sessionId ?? UUID().uuidString
    // Power down simulators left booted by earlier SimTool runs that were
    // SIGKILLed or crashed before they could clean up after themselves.
    await reapDeadSessions()
    let config = StreamServerConfig(
        host: host,
        port: port,
        device: device,
        captureEnabled: true,
        defaultLogApp: defaultLogApp,
        testSessionsRoot: testSessionsRoot,
        testsRoot: testsRoot,
        // Web-triggered runs stage a scenario exactly like the CLI does, so the
        // server needs the same launch profiles and logger wiring.
        profiles: projectConfig?.profiles ?? [],
        appFacingServerURL: projectConfig?.appFacingServerURL,
        projectRoot: projectConfig?.simtoolDirectory.deletingLastPathComponent()
    )
    let server = try await startStreamServer(config: config)
    let session = SessionInfo(
        sessionId: id,
        pid: getpid(),
        device: device,
        url: server.baseURL,
        api: server.apiURL,
        startedAt: Date(),
        bootedDevices: BootedSimulatorRegistry.shared.all()
    )
    try SessionStore.shared.write(session)
    installSignalTrap(sessionId: id, server: server)
    if printSessionJSON {
        try printJSON(session)
    } else if isatty(STDOUT_FILENO) == 1 {
        makeNoora().success(.alert("SimTool server started", takeaways: [
            "Open \(server.baseURL)",
            "Device: \(device.name)",
        ]))
    } else {
        // Noora suppresses alerts when stdout is not a terminal; scripts that
        // pipe `simtool run`/`serve` still need the viewer URL to automate
        // opening it, so report it as plain text.
        FileHandle.standardOutput.write(Data("SimTool server started\nOpen \(server.baseURL)\nDevice: \(device.name)\n".utf8))
    }
    if openBrowser {
        _ = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: [server.baseURL])
    }
    while !Task.isCancelled {
        try await Task.sleep(for: .seconds(3600))
    }
}

func startStreamServer(config: StreamServerConfig) async throws -> StreamServer {
    if let pids = try? await PortReclaimer.listeningPIDs(port: config.port), !pids.isEmpty {
        emitPortReclaimMessage(port: config.port, pids: pids)
        let result = try await PortReclaimer.reclaim(port: config.port)
        cleanupSessions(for: result.pids)
    }

    do {
        let server = StreamServer(config: config)
        try server.start()
        return server
    } catch {
        guard PortReclaimer.isAddressInUse(error) else { throw error }
        let pids = (try? await PortReclaimer.listeningPIDs(port: config.port)) ?? []
        emitPortReclaimMessage(port: config.port, pids: pids)
        let result = try await PortReclaimer.reclaim(port: config.port)
        cleanupSessions(for: result.pids)
        guard !result.pids.isEmpty else {
            throw SimToolError("Port \(config.port) is already in use, but no listening process could be found to stop.")
        }
        let server = StreamServer(config: config)
        try server.start()
        return server
    }
}

func emitPortReclaimMessage(port: UInt16, pids: [Int32]) {
    let detail = pids.isEmpty ? "unknown listener" : "PID(s) \(pids.map(String.init).joined(separator: ", "))"
    let message = "Port \(port) is already in use; stopping \(detail) and retrying."
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func cleanupSessions(for pids: [Int32]) {
    guard !pids.isEmpty, let sessions = try? SessionStore.shared.list() else { return }
    for session in sessions where pids.contains(session.pid) {
        SessionStore.shared.remove(session.sessionId)
    }
}

func installSignalTrap(sessionId: String, server: StreamServer) {
    SignalTrap.shared.installCleanup {
        await gracefulShutdown(sessionId: sessionId, server: server)
    }
}

/// Tears the session down in dependency order: stop the server (which kills the
/// log-stream/recorder children it spawned), then power down any simulators this
/// process booted, then drop the session file. Safe to call more than once.
func gracefulShutdown(sessionId: String, server: StreamServer) async {
    server.stop()
    await shutdownBootedSimulators()
    SessionStore.shared.remove(sessionId)
}

/// Shuts down every simulator this process booted itself, then forgets them so a
/// second pass (e.g. repeated signal cleanup) is a no-op.
func shutdownBootedSimulators() async {
    for udid in BootedSimulatorRegistry.shared.all() {
        await SimulatorDeviceClient.shutdown(udid)
        BootedSimulatorRegistry.shared.forget(udid)
    }
}

/// True if a process with this PID still exists (EPERM means it exists but is
/// owned by someone else — still alive for our purposes).
func isProcessAlive(_ pid: Int32) -> Bool {
    if Darwin.kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

/// SIGKILL and crashes skip the signal cleanup above, leaving the simulators a
/// now-dead session booted. On the next `serve`/`run` we sweep those orphans:
/// shut down devices booted only by dead sessions (never one a live session or
/// this process still uses) and delete the stale session files.
func reapDeadSessions() async {
    guard let sessions = try? SessionStore.shared.list() else { return }
    let dead = sessions.filter { !isProcessAlive($0.pid) }
    guard !dead.isEmpty else { return }
    let live = sessions.filter { isProcessAlive($0.pid) }
    let protectedByUs = Set(BootedSimulatorRegistry.shared.all())
    let toShutDown = SessionReaper.devicesToReap(dead: dead, live: live)
        .filter { !protectedByUs.contains($0) }
    for udid in toShutDown {
        await SimulatorDeviceClient.shutdown(udid)
    }
    for session in dead {
        SessionStore.shared.remove(session.sessionId)
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read .simtool/config.yml, launch the configured app, and start the web viewer server."
    )

    @Flag(help: "Open the browser viewer automatically. The server always starts and prints its URL.")
    var web = false

    @Flag(help: "Return once the app is launched, leaving the viewer server running in the background (build/launch still report in the foreground; the session URL is printed).")
    var detach = false

    @Flag(name: .long, help: "Disable the SimTool network logger for the launched app (enabled by default).")
    var noNetwork = false

    @Flag(name: .long, help: "Disable the SimTool state logger for the launched app (enabled by default).")
    var noState = false

    @Flag(help: "Force a new xcodebuild run and reinstall even when the checksum cache is valid.")
    var force = false

    @Flag(name: .long, help: "Print verbose diagnostic output to stderr.")
    var verbose = false

    @Option(name: .shortAndLong, help: "Simulator UDID or name to run on, overriding `simulator:` in the config. Pass 'booted' for the first booted simulator.")
    var device: String?

    @Option(help: "Path to the project config. Defaults to .simtool/config.yml discovered from the working directory upward.")
    var config: String?

    @OptionGroup var common: CommonJSON

    func run() async throws {
        DebugLog.isEnabled = verbose
        let projectConfig = try ProjectConfigLoader.load(explicitPath: config)
        let buildCache = SimulatorAppBuildCache(simtoolDirectory: projectConfig.simtoolDirectory)

        // Enable the app-side SimTool network and state loggers by default. Set
        // them on this process via the SIMCTL_CHILD_ prefix so simctl forwards
        // them to the app on both the initial launch and the server's
        // stdout-capture relaunch. They are inert for apps that do not link the
        // corresponding logger package and are compiled out of Release builds.
        let networkLoggerEnabled = projectConfig.networkLogger && !noNetwork
        let stateLoggerEnabled = projectConfig.stateLogger && !noState
        if networkLoggerEnabled {
            setenv("SIMCTL_CHILD_SIMTOOL_NETWORK_LOGGER", "1", 1)
        }
        if stateLoggerEnabled {
            setenv("SIMCTL_CHILD_SIMTOOL_STATE_LOGGER", "1", 1)
        }
        if networkLoggerEnabled || stateLoggerEnabled {
            setenv("SIMCTL_CHILD_SIMTOOL_SERVER_URL", projectConfig.appFacingServerURL, 1)
        }

        // `--device` overrides `simulator:` from the config when provided.
        let simulatorSelector = device ?? projectConfig.simulator
        let booted: SimulatorDevice
        let launch: SimulatorAppLaunchPayload
        if common.json {
            let resolved = try await SimulatorDeviceClient.resolve(simulatorSelector)
            booted = try await SimulatorDeviceClient.ensureBooted(resolved)
            launch = try await SimulatorAppLifecycleClient.launch(
                selection: try projectConfig.buildSelection(),
                device: booted,
                force: force,
                cache: buildCache
            )
        } else {
            let resolved = try await resolveSimulatorWithProgress(simulatorSelector)
            booted = try await bootSimulatorWithProgress(resolved)
            let buildPayload = try await buildAppWithProgress(
                selection: try projectConfig.buildSelection(),
                force: force,
                cache: buildCache
            )
            launch = try await installAndLaunchAppWithProgress(
                build: buildPayload,
                device: booted,
                force: force,
                cache: buildCache
            )
            let buildAction = launch.build.cacheHit ? "reused (checksum cache)" : "built"
            makeNoora().success(.alert("Launched \(launch.build.bundleIdentifier)", takeaways: [
                "Device: \(booted.name)",
                "Build: \(buildAction)",
                "Network logger: \(networkLoggerEnabled ? "on → \(projectConfig.appFacingServerURL)" : "off")",
                "State logger: \(stateLoggerEnabled ? "on → \(projectConfig.appFacingServerURL)" : "off")",
            ]))
        }
        if detach {
            // The device is already booted, so the child reports quickly. It
            // inherits the SIMCTL_CHILD_ logger exports set above, keeping the
            // Network/State panels armed across the stdout-capture relaunch.
            try await launchDetachedServer(
                parameters: ServeParameters(device: booted.udid, host: projectConfig.server.host, port: projectConfig.server.port),
                app: projectConfig.bundleId,
                verbose: verbose,
                json: common.json
            )
            return
        }
        try await runViewer(
            device: booted,
            host: projectConfig.server.host,
            port: projectConfig.server.port,
            defaultLogApp: projectConfig.bundleId,
            testSessionsRoot: SimToolDirectory.testSessionsDirectory(in: projectConfig.simtoolDirectory),
            testsRoot: SimToolDirectory.testsDirectory(in: projectConfig.simtoolDirectory),
            printSessionJSON: common.json,
            openBrowser: shouldOpenBrowser(webRequested: web, json: common.json, detachedChild: false),
            sessionId: nil,
            projectConfig: projectConfig
        )
    }
}

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Scaffold a starter .simtool/config.yml in the current directory, detecting the workspace/scheme where possible, and optionally install the simtool agent skill."
    )

    @Flag(name: .long, help: "Overwrite an existing .simtool/config.yml (and a modified installed skill).")
    var force = false

    @Option(
        name: .long,
        help: "Install the agent skill: `local` (this project, .claude/skills/simtool), `global` (all projects, ~/.claude/skills/simtool), or `none`. Omit to be asked interactively; non-interactive runs default to `none`."
    )
    var skill: AgentSkill.Scope?

    @OptionGroup var common: CommonJSON

    struct InitResult: Encodable {
        var configPath: String
        var workspace: String?
        var project: String?
        var scheme: String?
        var created: Bool
        var skill: AgentSkill.Installation
    }

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let simtoolDir = cwd.appendingPathComponent(SimToolDirectory.directoryName, isDirectory: true)
        let configURL = simtoolDir.appendingPathComponent(SimToolDirectory.configFileName)
        let alreadyExists = FileManager.default.fileExists(atPath: configURL.path)
        // Re-running `init` purely to install the skill is legitimate, so an
        // existing config only aborts when there is nothing else to do.
        let writesConfig = !alreadyExists || force
        if !writesConfig, skill == nil || skill == AgentSkill.Scope.none {
            throw SimToolError("\(ProjectConfigLoader.displayPath) already exists. Edit it, pass --force to overwrite, or pass --skill <local|global> to just install the agent skill.")
        }

        let detected = ProjectConfigTemplate.detect(in: cwd)
        if writesConfig {
            // Creates `.simtool/` and its self-ignoring `.gitignore` (never clobbered).
            try SimToolDirectory.ensure(simtoolDir)
            try Data(ProjectConfigTemplate.render(detected).utf8).write(to: configURL, options: [.atomic])
        }

        let installation = try AgentSkill.install(scope: resolveSkillScope(), projectDirectory: cwd, force: force)

        let result = InitResult(
            configPath: configURL.standardizedFileURL.path,
            workspace: detected.workspace,
            project: detected.project,
            scheme: detected.scheme,
            created: writesConfig && !alreadyExists,
            skill: installation
        )
        if common.json {
            try printJSON(result)
            return
        }

        var todos: [TerminalText] = []
        if writesConfig {
            todos.append("Set `bundleId` to the app's bundle identifier.")
            if detected.scheme == nil { todos.append("Set `build.scheme` to the app scheme.") }
            if detected.workspace == nil && detected.project == nil {
                todos.append("Set `build.workspace` or `build.project`.")
            }
        }
        if installation.outcome == .created || installation.outcome == .updated {
            todos.append("Fill in the skill's project options and launch-argument catalog for this app.")
        }
        let detail = [detected.workspace.map { "Workspace: \($0)" }, detected.project.map { "Project: \($0)" }, detected.scheme.map { "Scheme: \($0)" }]
            .compactMap { $0 }
        let headline = writesConfig
            ? "\(alreadyExists ? "Overwrote" : "Created") \(ProjectConfigLoader.displayPath)"
            : "Installed the simtool agent skill"
        let configLine = writesConfig ? ["Config: \(result.configPath)"] : []
        makeNoora().success(.alert(
            TerminalText(stringLiteral: headline),
            takeaways: (configLine + (writesConfig ? detail : []) + skillTakeaway(installation)).map { TerminalText(stringLiteral: $0) } + todos
        ))
    }

    /// The explicit `--skill`, else an interactive pick. Non-interactive runs
    /// install nothing: `init` is scriptable, and `global` writes outside the
    /// project, which must never happen without the user saying so.
    private func resolveSkillScope() -> AgentSkill.Scope {
        if let skill { return skill }
        guard !common.json, isatty(STDIN_FILENO) != 0 else { return .none }
        return makeNoora().singleChoicePrompt(
            title: "Agent skill",
            question: "Install the simtool agent skill?",
            options: SkillChoice.allCases,
            description: "Teaches a coding agent to build, launch, drive, mock, and UI-test your app with simtool."
        ).scope
    }

    private func skillTakeaway(_ installation: AgentSkill.Installation) -> [String] {
        guard let path = installation.path else { return ["Skill: not installed"] }
        switch installation.outcome {
        case .created: return ["Skill: installed at \(path)"]
        case .updated: return ["Skill: updated at \(path)"]
        case .upToDate: return ["Skill: already up to date at \(path)"]
        case .conflict: return ["Skill: kept your edited \(path) (pass --force to replace it)"]
        case .skipped: return ["Skill: not installed"]
        }
    }

    /// Prompt-facing wrapper: Noora renders `description`, and the raw scope
    /// names alone ("local"/"global") don't say where the file lands.
    private enum SkillChoice: CaseIterable, CustomStringConvertible, Equatable {
        case local, global, skip

        var scope: AgentSkill.Scope {
            switch self {
            case .local: return .local
            case .global: return .global
            case .skip: return .none
            }
        }

        var description: String {
            switch self {
            case .local: return "This project only (.claude/skills/simtool)"
            case .global: return "All projects (~/.claude/skills/simtool)"
            case .skip: return "Don't install"
            }
        }
    }
}

extension AgentSkill.Scope: ExpressibleByArgument {}

struct Checksum: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record the source checksum for an externally built app so a later `simtool run` reuses it. Intended for an Xcode post-build phase."
    )

    @Option(help: "Path to the project config. Defaults to .simtool/config.yml discovered from the working directory upward.")
    var config: String?

    @Option(name: .customLong("app-path"), help: "Path to the built .app. Defaults to $BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME (set by Xcode build phases).")
    var appPath: String?

    @OptionGroup var common: CommonJSON

    func run() async throws {
        let projectConfig = try ProjectConfigLoader.load(explicitPath: config)
        let buildCache = SimulatorAppBuildCache(simtoolDirectory: projectConfig.simtoolDirectory)
        let payload = try SimulatorAppLifecycleClient.recordExternalBuild(
            selection: try projectConfig.buildSelection(),
            appBundleURL: try resolveAppBundleURL(),
            cache: buildCache
        )
        if common.json {
            try printJSON(payload)
            return
        }
        makeNoora().success(.alert("Recorded build checksum", takeaways: [
            "Scheme: \(payload.identity.scheme)",
            "Bundle: \(payload.bundleIdentifier)",
            "App: \(payload.appBundlePath)",
            "Checksum: \(payload.checksum)",
        ]))
    }

    /// Resolves the built `.app`: an explicit `--app-path`, else the standard
    /// Xcode build-phase pair `$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME`.
    private func resolveAppBundleURL() throws -> URL {
        if let appPath, !appPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: NSString(string: appPath).expandingTildeInPath)
        }
        let environment = ProcessInfo.processInfo.environment
        if let productsDir = environment["BUILT_PRODUCTS_DIR"], !productsDir.isEmpty,
           let productName = environment["FULL_PRODUCT_NAME"], !productName.isEmpty {
            return URL(fileURLWithPath: productsDir).appendingPathComponent(productName)
        }
        throw SimToolError("Pass --app-path <path-to-.app>, or run inside an Xcode build phase where BUILT_PRODUCTS_DIR and FULL_PRODUCT_NAME are set.")
    }
}

struct Open: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a configured deeplink on the simulator. With no name, choose interactively."
    )

    @Argument(help: "Name of the deeplink to open. Omit to choose interactively.")
    var name: String?

    @Option(help: "Path to the project config. Defaults to .simtool/config.yml discovered from the working directory upward.")
    var config: String?

    @OptionGroup var common: CommonJSON

    func run() async throws {
        let projectConfig = try ProjectConfigLoader.load(explicitPath: config)
        guard !projectConfig.deeplinks.isEmpty else {
            throw SimToolError("No deeplinks configured in \(projectConfig.sourcePath). Add a `deeplinks:` list to use `simtool open`.")
        }
        let deeplink = try selectDeeplink(in: projectConfig)
        let resolved = try await SimulatorDeviceClient.resolve(projectConfig.simulator)
        let booted = try await SimulatorDeviceClient.ensureBooted(resolved)
        let payload = try await SimulatorDeeplinkClient.open(
            name: deeplink.name,
            url: deeplink.url,
            device: booted
        )
        if common.json {
            try printJSON(payload)
        } else {
            makeNoora().success(.alert("Opened deeplink", takeaways: [
                "Name: \(payload.name)",
                "URL: \(payload.url)",
                "Device: \(booted.name)",
            ]))
        }
    }

    private func selectDeeplink(in config: ProjectConfig) throws -> ProjectConfig.Deeplink {
        if let name {
            return try config.deeplink(named: name)
        }
        guard !common.json, isatty(STDIN_FILENO) != 0 else {
            throw SimToolError("No deeplink name given and no interactive terminal is available. Pass a deeplink name, e.g. `simtool open <name>`.")
        }
        return makeNoora().singleChoicePrompt(
            title: "Deeplinks",
            question: "Which deeplink do you want to open?",
            options: config.deeplinks
        )
    }
}

struct Interactive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "interactive",
        abstract: "Interactively open configured deeplinks in a loop. Runs when `simtool` is invoked without a subcommand."
    )

    @Option(help: "Path to the project config. Defaults to .simtool/config.yml discovered from the working directory upward.")
    var config: String?

    @OptionGroup var common: CommonJSON

    func run() async throws {
        guard !common.json, isatty(STDIN_FILENO) != 0 else {
            throw SimToolError("Interactive mode needs a terminal. Use `simtool open <name>` to open a deeplink non-interactively, or `simtool --help` for other commands.")
        }
        let projectConfig = try ProjectConfigLoader.load(explicitPath: config)
        guard !projectConfig.deeplinks.isEmpty else {
            throw SimToolError("No deeplinks configured in \(projectConfig.sourcePath). Add a `deeplinks:` list to use interactive mode.")
        }
        var device: SimulatorDevice?
        while true {
            let choice = makeNoora().singleChoicePrompt(
                title: "Deeplinks",
                question: "Which deeplink do you want to open?",
                options: InteractiveDeeplinkChoice.choices(for: projectConfig)
            )
            guard case .deeplink(let link) = choice else { return }
            do {
                let booted: SimulatorDevice
                if let cached = device {
                    booted = cached
                } else {
                    let resolved = try await SimulatorDeviceClient.resolve(projectConfig.simulator)
                    if resolved.state != "Booted" {
                        makeNoora().info("Booting \(resolved.name)…")
                    }
                    booted = try await SimulatorDeviceClient.ensureBooted(resolved)
                    device = booted
                    // simctl boots are headless; surface the simulator window.
                    await SimulatorDeviceClient.revealSimulatorApp()
                }
                let payload = try await SimulatorDeeplinkClient.open(
                    name: link.name,
                    url: link.url,
                    device: booted
                )
                makeNoora().success(.alert("Opened deeplink", takeaways: [
                    "Name: \(payload.name)",
                    "URL: \(payload.url)",
                    "Device: \(booted.name)",
                ]))
            } catch {
                // Drop the cached device so the next attempt re-resolves and re-boots.
                device = nil
                makeNoora().error(.alert("Failed to open '\(link.name)': \(error.localizedDescription)"))
            }
        }
    }
}

private extension URL {
    func creatingFileIfNeeded() throws -> URL {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        return self
    }
}
