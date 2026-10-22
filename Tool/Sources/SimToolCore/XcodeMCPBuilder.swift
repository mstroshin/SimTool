import Foundation

/// One entry of `XcodeListRunDestinations`: a run destination of the active
/// scheme, as the Xcode toolbar picker shows it.
public struct XcodeRunDestination: Equatable, Sendable {
    public var displayTitle: String
    public var isActive: Bool
    public var isEligible: Bool
    public var isSimulator: Bool
    public var isGenericDevice: Bool
    public var platformIdentifier: String?
    public var osVersion: String?

    public static let simulatorPlatform = "com.apple.platform.iphonesimulator"

    public init(
        displayTitle: String,
        isActive: Bool = false,
        isEligible: Bool = true,
        isSimulator: Bool,
        isGenericDevice: Bool = false,
        platformIdentifier: String? = Self.simulatorPlatform,
        osVersion: String? = nil
    ) {
        self.displayTitle = displayTitle
        self.isActive = isActive
        self.isEligible = isEligible
        self.isSimulator = isSimulator
        self.isGenericDevice = isGenericDevice
        self.platformIdentifier = platformIdentifier
        self.osVersion = osVersion
    }

    init?(_ value: JSONValue) {
        guard let object = value.objectValue, let title = object["displayTitle"]?.stringValue else { return nil }
        self.init(
            displayTitle: title,
            isActive: object["isActive"]?.boolValue ?? false,
            isEligible: object["isEligible"]?.boolValue ?? false,
            isSimulator: object["isSimulator"]?.boolValue ?? false,
            isGenericDevice: object["isGenericDevice"]?.boolValue ?? false,
            platformIdentifier: object["platformIdentifier"]?.stringValue,
            osVersion: object["osVersion"]?.stringValue
        )
    }

    /// An iOS simulator destination the active scheme can build for.
    var isEligibleIOSSimulator: Bool {
        guard isEligible else { return false }
        if let platformIdentifier { return platformIdentifier == Self.simulatorPlatform }
        return isSimulator
    }

    /// Xcode's own entry for `device`: same name — the picker adds the OS
    /// version to tell apart simulators that share one — preferring the same
    /// iOS version. Xcode lists destinations by title, not UDID, so a device is
    /// matched by what the picker shows for it.
    public static func entry(for device: SimulatorDevice, in destinations: [XcodeRunDestination]) -> XcodeRunDestination? {
        let named = destinations.filter {
            $0.isEligibleIOSSimulator && !$0.isGenericDevice
                && ($0.displayTitle == device.name || $0.displayTitle.hasPrefix(device.name + " ("))
        }
        // simctl's runtime names no patch version (26.4) where Xcode does (26.4.1).
        let version = device.osVersion
        let sameVersion = named.filter { entry in
            guard let version, let osVersion = entry.osVersion else { return true }
            return osVersion == version || osVersion.hasPrefix(version + ".")
        }
        return sameVersion.first(where: { $0.displayTitle == device.name }) ?? sameVersion.first ?? named.first
    }

    /// The destination to build for `device`: its own entry, else any other
    /// iOS simulator, which builds the same architecture on this Mac; with no
    /// device, "Any iOS Simulator Device".
    public static func choose(from destinations: [XcodeRunDestination], for device: SimulatorDevice?) -> XcodeRunDestination? {
        let simulators = destinations.filter(\.isEligibleIOSSimulator)
        let generic = simulators.first(where: \.isGenericDevice)
        guard let device else { return generic }
        return entry(for: device, in: destinations)
            ?? simulators.first { !$0.isGenericDevice }
            ?? generic
    }

    /// Parses the complete list `XcodeListRunDestinations` writes to
    /// `fullRunDestinationListPath`: blocks of `KEY: value` lines, one block per
    /// destination, opened by `DESTINATION_INDEX`. The inline answer stops at
    /// 40 entries; a machine with many simulators needs this one.
    public static func parseList(_ text: String) -> [XcodeRunDestination] {
        var blocks: [[String: String]] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "DESTINATION_INDEX" {
                blocks.append([:])
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1][key] = value
            }
        }
        return blocks.compactMap { fields in
            guard let title = fields["DISPLAY_TITLE"] else { return nil }
            let platform = fields["PLATFORM_IDENTIFIER"].flatMap { $0 == "(none)" ? nil : $0 }
            let version = fields["OS_VERSION"].flatMap { $0 == "(none)" ? nil : $0 }
            return XcodeRunDestination(
                displayTitle: title,
                isActive: fields["IS_ACTIVE"] == "true",
                isEligible: fields["IS_ELIGIBLE"] == "true",
                isSimulator: fields["IS_SIMULATOR"] == "true",
                isGenericDevice: fields["IS_GENERIC_DEVICE"] == "true",
                platformIdentifier: platform,
                osVersion: version
            )
        }
    }
}

extension SimulatorDevice {
    /// The OS version of the runtime, as Xcode prints it: `26.4` for
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-4`.
    var osVersion: String? {
        guard let last = runtime.split(separator: ".").last, let dash = last.firstIndex(of: "-") else { return nil }
        let version = last[last.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
        return version.isEmpty ? nil : version
    }
}

/// Builds in Xcode itself, through the MCP tools Xcode serves over
/// `xcrun mcpbridge`: opens the workspace or project, makes the scheme and a
/// run destination for the simulator active, runs `BuildProject`, and asks
/// Xcode where the `.app` landed. A warm Xcode keeps the workspace loaded,
/// so it often finishes far sooner than a cold `xcodebuild`.
///
/// Xcode decides the rest: it builds the scheme's Run configuration with the
/// project's own settings, into the DerivedData it would use for a build from
/// its UI. Xcode also has to let SimTool in — on first use it asks the user to
/// approve the agent and the project's folder.
public enum XcodeMCPBuilder {
    public struct Outcome: Equatable, Sendable {
        public var appBundleURL: URL
        public var destination: String
        public var buildResult: String
        public var elapsedSeconds: Double?
        public var fullLogPath: String?
        public var configuration: String?

        /// The build step as a build payload's `xcodebuild` field reports it.
        public var stepSummary: SimulatorAppProcessStepSummary {
            var lines = [buildResult, "Destination: \(destination)"]
            if let elapsedSeconds { lines.append(String(format: "Elapsed: %.1f s", elapsedSeconds)) }
            if let fullLogPath { lines.append("Log: \(fullLogPath)") }
            return SimulatorAppProcessStepSummary(name: "Xcode BuildProject", ran: true, status: 0, stdout: lines.joined(separator: "\n"))
        }
    }

    /// How long Xcode may take to open a workspace, which includes waiting for
    /// the user to approve SimTool the first time.
    static let openTimeoutSeconds: TimeInterval = 600
    static let toolTimeoutSeconds: TimeInterval = 120

    /// Every tool a build calls, checked up front so an older Xcode fails with
    /// one clear message instead of halfway through.
    static let requiredTools = [
        "XcodeOpenWorkspace", "XcodeSwitchScheme", "XcodeListRunDestinations", "XcodeSwitchRunDestination",
        "BuildProject", "XcodeListTargets", "GetTargetBuildSettings",
    ]

    /// Launches `xcrun mcpbridge` and builds through it.
    public static func build(
        selection: SimulatorAppBuildSelection,
        device: SimulatorDevice?,
        timeoutSeconds: TimeInterval?,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Outcome {
        let client = try MCPStdioClient.launch(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["mcpbridge"]
        )
        defer { client.close() }
        client.onProgress(progress)
        let available: Set<String>
        do {
            try await client.initialize(clientName: "simtool", clientVersion: SimToolVersion.base)
            available = try await client.toolNames()
        } catch {
            throw SimToolError("Unable to reach Xcode's MCP tools through `xcrun mcpbridge`: \(error.localizedDescription)")
        }
        let missing = requiredTools.filter { !available.contains($0) }
        guard missing.isEmpty else {
            throw SimToolError("This Xcode's MCP tools lack \(missing.joined(separator: ", ")), which building with xcode-mcp needs; Xcode 27 or later has them.")
        }
        return try await build(selection: selection, device: device, tools: client, timeoutSeconds: timeoutSeconds, progress: progress)
    }

    /// The build itself, over any `MCPToolCalling` — unit tests pass a stand-in.
    public static func build(
        selection: SimulatorAppBuildSelection,
        device: SimulatorDevice?,
        tools: MCPToolCalling,
        timeoutSeconds: TimeInterval?,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Outcome {
        let scheme = selection.identity.scheme
        let source = selection.sourceURL
        progress?("Opening \(source.lastPathComponent) in Xcode…")
        let opened = try await call(tools, "XcodeOpenWorkspace", ["path": .string(source.path)], timeoutSeconds: openTimeoutSeconds)
        guard let workspace = opened["workspaceIdentifier"]?.stringValue, !workspace.isEmpty else {
            throw SimToolError("Xcode opened \(source.path) but returned no workspace identifier.")
        }
        let target: [String: JSONValue] = ["workspaceIdentifier": .string(workspace)]

        if opened["activeScheme"]?.stringValue != scheme {
            progress?("Selecting scheme \(scheme)…")
            let switched = try await call(tools, "XcodeSwitchScheme", target.merging(["schemeName": .string(scheme)]) { $1 })
            let active = switched["activeSchemeName"]?.stringValue
            guard active == nil || active == scheme || active?.hasPrefix(scheme + " (") == true else {
                throw SimToolError("Xcode did not switch \(source.lastPathComponent) to scheme \(scheme); the active scheme is \(active ?? "none").")
            }
        }

        let listed = try await call(tools, "XcodeListRunDestinations", target)
        var destinations = (listed["destinations"]?.arrayValue ?? []).compactMap(XcodeRunDestination.init)
        // The inline list stops at 40 entries — before "Any iOS Simulator
        // Device", and before a simulator of its own on a busy machine.
        if listed["truncated"]?.boolValue == true,
           let path = listed["fullRunDestinationListPath"]?.stringValue,
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let complete = XcodeRunDestination.parseList(text)
            if !complete.isEmpty { destinations = complete }
        }
        guard let destination = XcodeRunDestination.choose(from: destinations, for: device) else {
            let eligible = destinations.filter(\.isEligible).map(\.displayTitle)
            let shown = eligible.prefix(10).joined(separator: ", ") + (eligible.count > 10 ? ", …" : "")
            throw SimToolError("Scheme \(scheme) has no iOS simulator run destination in Xcode. Eligible: \(eligible.isEmpty ? "none" : shown).")
        }
        if listed["activeDestinationDisplayTitle"]?.stringValue != destination.displayTitle {
            progress?("Selecting \(destination.displayTitle)…")
            _ = try await call(tools, "XcodeSwitchRunDestination", target.merging(["displayTitle": .string(destination.displayTitle)]) { $1 })
        }

        progress?("Building \(scheme) in Xcode…")
        let built = try await call(tools, "BuildProject", target, timeoutSeconds: timeoutSeconds)
        let buildResult = built["buildResult"]?.stringValue ?? ""
        let errors = buildErrors(built)
        let fullLogPath = built["fullLogPath"]?.stringValue
        guard errors.isEmpty, !buildFailed(buildResult) else {
            var detail = errors.prefix(10).joined(separator: "\n")
            if detail.isEmpty { detail = buildResult }
            if let fullLogPath { detail += "\nFull log: \(fullLogPath)" }
            throw SimToolError("Xcode failed to build scheme \(scheme): \(detail)")
        }

        let product = try await builtProduct(
            scheme: scheme,
            configuration: selection.identity.configuration,
            target: target,
            logPath: fullLogPath,
            tools: tools
        )
        let appBundleURL = product.appBundleURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appBundleURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SimToolError("Xcode reported a successful build of scheme \(scheme), but \(appBundleURL.path) does not exist.")
        }
        return Outcome(
            appBundleURL: appBundleURL,
            destination: destination.displayTitle,
            buildResult: buildResult,
            elapsedSeconds: built["elapsedTime"]?.doubleValue,
            fullLogPath: fullLogPath,
            configuration: product.configuration
        )
    }

    /// The error lines of a `BuildProject` result, as `path:line: message`.
    static func buildErrors(_ result: [String: JSONValue]) -> [String] {
        (result["errors"]?.arrayValue ?? []).compactMap { entry in
            guard let object = entry.objectValue, let message = object["message"]?.stringValue else { return nil }
            let classification = object["classification"]?.stringValue?.lowercased() ?? "error"
            guard classification.contains("error") else { return nil }
            var location = object["filePath"]?.stringValue ?? ""
            if let line = object["lineNumber"]?.doubleValue, !location.isEmpty { location += ":\(Int(line))" }
            return location.isEmpty ? message : "\(location): \(message)"
        }
    }

    /// Whether `buildResult` says the build did not succeed — not merely that
    /// it mentions errors, as a count of zero would.
    static func buildFailed(_ buildResult: String) -> Bool {
        let text = buildResult.lowercased()
        return text.contains("fail") || text.contains("cancel")
    }

    /// Finds the `.app` Xcode just built. Xcode's target settings name the
    /// products root (`SYMROOT`, inside whatever DerivedData Xcode uses) and
    /// the product, but not the configuration directory: that comes from the
    /// build log, which signs and validates the app on every build. A log
    /// that names no app leaves `configuration` to assume; the configuration
    /// returned is the one the log shows, if any.
    static func builtProduct(
        scheme: String,
        configuration expected: String,
        target: [String: JSONValue],
        logPath: String?,
        tools: MCPToolCalling
    ) async throws -> (appBundleURL: URL, configuration: String?) {
        let listed = try await call(tools, "XcodeListTargets", target.merging(["productTypeFilter": .array([.string("application")])]) { $1 })
        let apps = (listed["targets"]?.arrayValue ?? []).compactMap { entry -> (name: String, project: String?)? in
            guard let object = entry.objectValue, let name = object["name"]?.stringValue else { return nil }
            if object["isTestTarget"]?.boolValue == true { return nil }
            return (name, object["containingProjectPath"]?.stringValue)
        }
        guard let app = apps.first(where: { $0.name == scheme }) ?? (apps.count == 1 ? apps.first : nil) else {
            let names = apps.map(\.name).joined(separator: ", ")
            throw SimToolError("Unable to tell which app target scheme \(scheme) builds: Xcode lists \(names.isEmpty ? "no application targets" : names).")
        }
        var arguments = target
        arguments["targetName"] = .string(app.name)
        if let project = app.project, apps.filter({ $0.name == app.name }).count > 1 {
            arguments["projectPath"] = .string(project)
        }
        let settings = buildSettings(try await call(tools, "GetTargetBuildSettings", arguments))
        guard let products = settings["SYMROOT"], !products.isEmpty, let name = productName(settings) else {
            throw SimToolError("Xcode's build settings for \(app.name) name no products directory or .app product.")
        }
        let log = logPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let logged = loggedApps(in: log, productsRoot: products)
        let product = logged.first { $0.name == name } ?? (logged.count == 1 ? logged.first : nil)
        let directory = product?.directory ?? "\(expected)-iphonesimulator"
        let url = URL(fileURLWithPath: products)
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(product?.name ?? name, isDirectory: true)
        let configuration = product.map { String($0.directory.dropLast("-iphonesimulator".count)) }
        return (url, configuration)
    }

    /// The app's bundle name from Xcode's target settings.
    static func productName(_ settings: [String: String]) -> String? {
        if let wrapper = settings["WRAPPER_NAME"] ?? settings["FULL_PRODUCT_NAME"], wrapper.hasSuffix(".app") {
            return wrapper
        }
        guard let name = settings["PRODUCT_NAME"], !name.isEmpty, (settings["WRAPPER_EXTENSION"] ?? "app") == "app" else { return nil }
        return name + ".app"
    }

    /// The top-level `.app` bundles a build log names under `productsRoot`, as
    /// `<Configuration>-iphonesimulator` directory and bundle name, in order of
    /// first mention.
    static func loggedApps(in log: String, productsRoot: String) -> [(directory: String, name: String)] {
        let prefix = productsRoot.hasSuffix("/") ? productsRoot : productsRoot + "/"
        var found: [(directory: String, name: String)] = []
        for line in log.split(whereSeparator: \.isNewline) {
            var rest = Substring(line)
            while let range = rest.range(of: prefix) {
                rest = rest[range.upperBound...]
                guard let slash = rest.firstIndex(of: "/") else { break }
                let directory = rest[..<slash]
                let tail = rest[rest.index(after: slash)...]
                guard directory.hasSuffix("-iphonesimulator"), !directory.contains(" "),
                      let app = tail.range(of: ".app"),
                      !tail[..<app.lowerBound].contains("/")
                else { continue }
                let next = tail[app.upperBound...].first
                guard next == nil || next == "/" || next == " " || next == "\"" || next == "'" else { continue }
                // Command lines escape spaces; the task titles do not.
                let name = tail[..<app.upperBound].replacingOccurrences(of: "\\ ", with: " ")
                let entry = (directory: String(directory), name: name)
                if !found.contains(where: { $0 == entry }) { found.append(entry) }
            }
        }
        return found
    }

    /// Flattens `GetTargetBuildSettings` output — `{macroName, value,
    /// evaluatedValue}` entries — into `NAME: evaluated value`.
    static func buildSettings(_ result: [String: JSONValue]) -> [String: String] {
        var settings: [String: String] = [:]
        for entry in result["buildSettings"]?.arrayValue ?? [] {
            guard let object = entry.objectValue, let name = object["macroName"]?.stringValue else { continue }
            if let value = object["evaluatedValue"]?.stringValue ?? object["value"]?.stringValue {
                settings[name] = value
            }
        }
        return settings
    }

    /// Calls a tool and returns its structured output; a tool error throws,
    /// with a hint when Xcode has not approved SimTool yet.
    static func call(
        _ tools: MCPToolCalling,
        _ name: String,
        _ arguments: [String: JSONValue],
        timeoutSeconds: TimeInterval? = toolTimeoutSeconds
    ) async throws -> [String: JSONValue] {
        let result: MCPToolResult
        do {
            result = try await tools.callTool(name, arguments: arguments, timeoutSeconds: timeoutSeconds)
        } catch {
            throw SimToolError("Xcode MCP \(name) failed: \(error.localizedDescription)")
        }
        DebugLog.write("xcode-mcp", "\(name) → \(result.isError ? "error: " : "")\(result.text.prefix(2_000))")
        guard !result.isError else {
            throw SimToolError(failureMessage(tool: name, text: result.text))
        }
        return result.structured ?? [:]
    }

    static func failureMessage(tool: String, text: String) -> String {
        let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = "Xcode MCP \(tool) failed: \(detail.isEmpty ? "no detail" : detail)"
        if detail.lowercased().contains("approve") {
            message += "\nXcode has to approve SimTool first: allow it where Xcode asks, or approve the pending request listed by `xcrun mcp-server status` with `sudo xcrun mcp-server approve <id>`. Then run again."
        }
        return message
    }
}
