import Foundation
import ImageIO
import UniformTypeIdentifiers
import SimToolNetworkLogger

public struct CommandResultPayload: Codable, Equatable, Sendable {
    public var ok: Bool
    public var stdout: String
    public var stderr: String

    public init(ok: Bool, stdout: String, stderr: String) {
        self.ok = ok
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct LogTailPayload: Codable, Equatable, Sendable {
    public var lines: [String]

    public init(lines: [String]) {
        self.lines = lines
    }
}

public enum AxeClient {
    public static func url() async throws -> URL {
        let output = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/which"), arguments: ["axe"])
        if output.status == 0 {
            let path = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return URL(fileURLWithPath: path) }
        }
        for path in ["/opt/homebrew/bin/axe", "/usr/local/bin/axe"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw SimToolError("AXe is not installed or not in PATH. Install https://github.com/cameroncooke/AXe")
    }

    /// How long an AXe command may take before it is treated as a failure.
    ///
    /// Every one of them is a short operation — a tap, a swipe of a second or
    /// two, one read of the accessibility tree — and none has a reason to
    /// outlast a minute. Unbounded, one that wedges takes its caller with it:
    /// `await` on a child process that never exits is not a suspension point
    /// anything can cancel, so the crawl's own time budget stops applying and
    /// `POST /api/v1/explore/stop` has nothing to interrupt. A bound turns that
    /// into an error the callers already handle — a failed tree read is "not
    /// settled yet" to the crawl, and a failed tap ends the pass.
    public static let defaultTimeoutSeconds: TimeInterval = 60

    public static func run(
        _ arguments: [String],
        stdin: Data? = nil,
        timeoutSeconds: TimeInterval? = defaultTimeoutSeconds
    ) async throws -> ProcessOutput {
        let output = try await ProcessRunner.run(
            executable: try await url(),
            arguments: arguments,
            stdin: stdin,
            timeoutSeconds: timeoutSeconds
        )
        guard output.status == 0 else {
            throw SimToolError(output.stderrString.isEmpty ? "axe command failed" : output.stderrString)
        }
        return output
    }
}

public enum SimulatorInputClient {
    public static func tap(
        deviceUDID: String,
        x: Double? = nil,
        y: Double? = nil,
        id: String? = nil,
        label: String? = nil
    ) async throws -> ProcessOutput {
        var args = ["tap", "--udid", deviceUDID]
        if let x, let y { args += ["-x", "\(x)", "-y", "\(y)"] }
        if let id { args += ["--id", id] }
        if let label { args += ["--label", label] }
        return try await AxeClient.run(args)
    }

    /// AXe's `touch` command only takes coordinates, so an `id`/`label` target
    /// is resolved to its frame center through the accessibility tree first.
    public static func longPress(
        deviceUDID: String,
        x: Double? = nil,
        y: Double? = nil,
        id: String? = nil,
        label: String? = nil,
        duration: Double = 1.0
    ) async throws -> ProcessOutput {
        let point: (x: Double, y: Double)
        if let x, let y {
            point = (x, y)
        } else if id != nil || label != nil {
            point = try await frameCenter(deviceUDID: deviceUDID, id: id, label: label)
        } else {
            throw SimToolError("Long press requires x/y coordinates or an id/label target")
        }
        return try await AxeClient.run([
            "touch",
            "-x", "\(point.x)",
            "-y", "\(point.y)",
            "--down", "--up",
            "--delay", "\(max(0.1, duration))",
            "--udid", deviceUDID,
        ])
    }

    private static func frameCenter(deviceUDID: String, id: String?, label: String?) async throws -> (x: Double, y: Double) {
        let tree = try await SimulatorAccessibilityClient.normalizedTree(deviceUDID: deviceUDID)
        var queue = tree.roots
        while !queue.isEmpty {
            let node = queue.removeFirst()
            queue.append(contentsOf: node.children)
            let matches = if let id {
                node.accessibilityIdentifier == id
            } else {
                node.label == label || node.title == label
            }
            guard matches,
                  let frame = node.frame,
                  let x = frame.x, let y = frame.y,
                  let width = frame.width, let height = frame.height else { continue }
            return (x + width / 2, y + height / 2)
        }
        throw SimToolError("No element matching \(id.map { "id \"\($0)\"" } ?? "label \"\(label ?? "")\"") with a frame to long-press")
    }

    public static func typeText(_ text: String, deviceUDID: String) async throws -> ProcessOutput {
        try await AxeClient.run(["type", "--stdin", "--udid", deviceUDID], stdin: Data(text.utf8))
    }

    public static func swipe(
        deviceUDID: String,
        startX: Double,
        startY: Double,
        endX: Double,
        endY: Double,
        duration: Double? = nil
    ) async throws -> ProcessOutput {
        var args = [
            "swipe",
            "--start-x", "\(startX)",
            "--start-y", "\(startY)",
            "--end-x", "\(endX)",
            "--end-y", "\(endY)",
            "--udid", deviceUDID,
        ]
        if let duration { args += ["--duration", "\(duration)"] }
        return try await AxeClient.run(args)
    }

    public static func button(_ name: String, deviceUDID: String) async throws -> ProcessOutput {
        try await AxeClient.run(["button", name, "--udid", deviceUDID])
    }
}

public enum SimulatorAccessibilityClient {
    public static func tree(deviceUDID: String) async throws -> Data {
        let output = try await AxeClient.run(["describe-ui", "--udid", deviceUDID])
        return output.stdout
    }

    public static func normalizedTree(deviceUDID: String, includeRaw: Bool = false) async throws -> AccessibilityTreePayload {
        try parseTree(try await tree(deviceUDID: deviceUDID), includeRaw: includeRaw)
    }

    public static func find(needle: String, deviceUDID: String) async throws -> [String] {
        let output = try await AxeClient.run(["describe-ui", "--udid", deviceUDID])
        let lower = needle.lowercased()
        return output.stdoutString
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.lowercased().contains(lower) }
    }

    public static func findNodes(needle: String, deviceUDID: String, includeRaw: Bool = false) async throws -> AccessibilityFindPayload {
        try findNodes(needle: needle, in: try await normalizedTree(deviceUDID: deviceUDID, includeRaw: includeRaw))
    }

    public static func parseTree(_ data: Data, includeRaw: Bool = false) throws -> AccessibilityTreePayload {
        let value = try JSON.decoder.decode(JSONValue.self, from: data)
        let roots: [AccessibilityNode]
        switch value {
        case let .array(values):
            roots = values.enumerated().map { normalize($0.element, path: [$0.offset], includeRaw: includeRaw) }
        default:
            roots = [normalize(value, path: [0], includeRaw: includeRaw)]
        }
        return AccessibilityTreePayload(roots: roots)
    }

    /// Collapses the tree into a depth-annotated list of the fields agents act
    /// on. `labeledOnly` keeps just the nodes carrying an identifier, label,
    /// value, or title.
    public static func flatten(_ tree: AccessibilityTreePayload, labeledOnly: Bool = false) -> AccessibilityFlatTreePayload {
        var nodes: [AccessibilityFlatNode] = []
        func visit(_ node: AccessibilityNode, depth: Int) {
            let flat = AccessibilityFlatNode(
                id: node.accessibilityIdentifier,
                label: node.label,
                value: node.value,
                title: node.title,
                type: node.type ?? node.role,
                subrole: node.subrole,
                depth: depth,
                frame: node.frame.flatMap(cornerArray),
                enabled: node.enabled == false ? false : nil
            )
            if !labeledOnly || flat.id != nil || flat.label != nil || flat.value != nil || flat.title != nil {
                nodes.append(flat)
            }
            for child in node.children { visit(child, depth: depth + 1) }
        }
        for root in tree.roots { visit(root, depth: 0) }
        return AccessibilityFlatTreePayload(nodeCount: tree.nodeCount, nodes: nodes)
    }

    private static func cornerArray(_ frame: AccessibilityFrame) -> [Int]? {
        guard let x = frame.x, let y = frame.y, let width = frame.width, let height = frame.height else { return nil }
        return [Int(x.rounded()), Int(y.rounded()), Int(width.rounded()), Int(height.rounded())]
    }

    public static func findNodes(needle: String, in tree: AccessibilityTreePayload) throws -> AccessibilityFindPayload {
        let lower = needle.lowercased()
        var matches: [AccessibilityMatch] = []
        for (index, root) in tree.roots.enumerated() {
            collectMatches(root, query: lower, path: [index], matches: &matches)
        }
        return AccessibilityFindPayload(query: needle, matches: matches)
    }

    private static func normalize(_ value: JSONValue, path: [Int], includeRaw: Bool = false) -> AccessibilityNode {
        guard let object = value.objectValue else {
            return AccessibilityNode(id: path.map(String.init).joined(separator: "."), raw: includeRaw ? value : nil)
        }
        let childrenValues = object["children"]?.arrayValue ?? []
        let children = childrenValues.enumerated().map { index, child in
            normalize(child, path: path + [index], includeRaw: includeRaw)
        }
        let frame = frame(from: object["frame"]?.objectValue)
        let accessibilityIdentifier = object["AXUniqueId"]?.stringValue
        let stableID = [
            accessibilityIdentifier,
            object["AXLabel"]?.stringValue,
            object["role"]?.stringValue,
            path.map(String.init).joined(separator: "."),
        ].compactMap { $0?.nilIfEmpty }.joined(separator: "|")
        return AccessibilityNode(
            id: stableID.nilIfEmpty ?? path.map(String.init).joined(separator: "."),
            accessibilityIdentifier: accessibilityIdentifier,
            label: object["AXLabel"]?.stringValue,
            value: object["AXValue"]?.stringValue,
            title: object["title"]?.stringValue,
            role: object["role"]?.stringValue,
            roleDescription: object["role_description"]?.stringValue,
            subrole: object["subrole"]?.stringValue,
            type: object["type"]?.stringValue,
            enabled: object["enabled"]?.boolValue,
            pid: object["pid"]?.doubleValue.map(Int.init),
            frame: frame,
            children: children,
            raw: includeRaw ? value : nil
        )
    }

    private static func frame(from object: [String: JSONValue]?) -> AccessibilityFrame? {
        guard let object else { return nil }
        return AccessibilityFrame(
            x: object["x"]?.doubleValue,
            y: object["y"]?.doubleValue,
            width: object["width"]?.doubleValue,
            height: object["height"]?.doubleValue
        )
    }

    private static func collectMatches(
        _ node: AccessibilityNode,
        query: String,
        path: [Int],
        matches: inout [AccessibilityMatch]
    ) {
        let haystack = [
            node.accessibilityIdentifier,
            node.label,
            node.value,
            node.title,
            node.role,
            node.roleDescription,
            node.type,
        ].compactMap { $0?.lowercased() }.joined(separator: " ")
        if haystack.contains(query) {
            matches.append(AccessibilityMatch(
                id: path.map(String.init).joined(separator: "."),
                path: path,
                node: node
            ))
        }
        for (index, child) in node.children.enumerated() {
            collectMatches(child, query: query, path: path + [index], matches: &matches)
        }
    }
}

public enum SimulatorLogsClient {
    public static func tail(
        deviceUDID: String,
        app: String? = nil,
        lines: Int = 200,
        seconds: Double = 2
    ) async throws -> [String] {
        var args = ["simctl", "spawn", deviceUDID, "log", "stream", "--style", "ndjson", "--level", "info"]
        if let appLogPredicate = appLogPredicate(app: app) {
            args += ["--predicate", appLogPredicate]
        }
        let output = try await ProcessRunner.runFor(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: args,
            durationSeconds: max(0.25, seconds)
        )
        let items = output.stdoutString
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Array(items.suffix(max(0, lines)))
    }

    static func appLogPredicate(app: String?) -> String? {
        guard let app else { return nil }
        let trimmed = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidates = appProcessCandidates(app: app)
        guard !candidates.isEmpty else { return nil }
        var clauses = appSubsystemCandidates(app: app).map {
            "subsystem BEGINSWITH '\(escapeForPredicateLiteral($0))'"
        }
        for candidate in candidates {
            let escaped = escapeForPredicateLiteral(candidate)
            clauses.append("process == '\(escaped)'")
            clauses.append("processImagePath ENDSWITH '/\(escaped)'")
        }
        return clauses.joined(separator: " OR ")
    }

    static func appProcessCandidates(app: String) -> [String] {
        let trimmed = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var candidates: [String] = [trimmed]
        if let finalComponent = trimmed.split(separator: ".").last.map(String.init), finalComponent != trimmed {
            candidates.append(finalComponent)
        }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }

    /// Bundle-id suffixes commonly appended to a Debug/Beta build while the app keeps logging under
    /// its base subsystem (e.g. bundle `com.example.MyApp.debug` logs under subsystem `com.example.MyApp`).
    static let buildVariantSuffixes: Set<String> = [
        "debug", "beta", "dev", "development", "staging", "stage", "qa",
        "adhoc", "internal", "enterprise", "alpha", "rc",
        "release", "prod", "production", "test", "testing", "nightly", "canary",
    ]

    /// Subsystem prefixes to scope OSLog capture to: the app id and, when its final dot-component is
    /// a known build variant and a multi-component base remains, that base id. Lets capture match an
    /// app that logs under its base subsystem while shipping under a variant-suffixed bundle id.
    static func appSubsystemCandidates(app: String) -> [String] {
        let trimmed = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var candidates: [String] = [trimmed]
        let components = trimmed.split(separator: ".").map(String.init)
        if components.count >= 3, let last = components.last,
           buildVariantSuffixes.contains(last.lowercased()) {
            candidates.append(components.dropLast().joined(separator: "."))
        }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }

    // Escape a value for a single-quoted os_log predicate literal: drop control characters
    // (including newlines) and backslash-escape `\` and `'` so a supplied value cannot terminate
    // the literal or inject extra clauses. Every other character, including spaces, is preserved.
    static func escapeForPredicateLiteral(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) { continue }
            switch scalar {
            case "\\":
                scalars.append("\\")
                scalars.append("\\")
            case "'":
                scalars.append("\\")
                scalars.append("'")
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

public enum SimulatorScreenshotClient {
    /// How long one `simctl io … screenshot` may take before it is a failure.
    ///
    /// A screenshot is a fraction of a second's work, and this is not a limit on
    /// a slow machine so much as on a wedged one: CoreSimulator's `simctl io`
    /// does sometimes stop returning, and it took a whole crawl with it — every
    /// screen the crawl reaches is photographed, `await` on a child that never
    /// exits cannot be cancelled, so the run's minute budget stopped applying
    /// and `POST /api/v1/explore/stop` had nothing to interrupt. Killing the
    /// child by hand was the only way out. Bounded, the crawl loses one
    /// screenshot and walks on.
    ///
    /// Two minutes, the same threshold `simctl launch` is given, and deliberately
    /// far above anything healthy: the number's job is to tell a hang from work,
    /// not to police a slow machine. A CoreSimulator left with stale display
    /// objects answered every screenshot in a steady 60 seconds — miserable, and
    /// still a machine doing its job, which a tighter bound would have called
    /// broken.
    public static let defaultTimeoutSeconds: TimeInterval = 120

    public static func png(
        deviceUDID: String,
        maxDimension: Int? = nil,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds
    ) async throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-screenshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "io", deviceUDID, "screenshot", "--type=png", url.path],
            timeoutSeconds: timeoutSeconds
        )
        guard output.status == 0 else {
            throw SimToolError(output.stderrString.isEmpty ? "simctl screenshot failed" : output.stderrString)
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw SimToolError("simctl screenshot returned an empty PNG") }
        guard let maxDimension else { return data }
        return try downscaled(pngData: data, maxDimension: maxDimension)
    }

    /// Scales the PNG down so its longest edge is at most `maxDimension`,
    /// preserving aspect ratio. Images already within bounds pass through
    /// unchanged.
    public static func downscaled(pngData: Data, maxDimension: Int) throws -> Data {
        guard maxDimension > 0 else { throw SimToolError("maxDimension must be positive") }
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw SimToolError("Screenshot is not a decodable image")
        }
        guard max(width, height) > maxDimension else { return pngData }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw SimToolError("Failed to downscale screenshot")
        }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
            throw SimToolError("Failed to create PNG encoder")
        }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SimToolError("Failed to encode downscaled screenshot")
        }
        return buffer as Data
    }
}

public enum SimulatorNetworkClient {
    public static func snapshot(deviceUDID: String, seconds: Double = 2, limit: Int = 200) async throws -> NetworkSnapshotPayload {
        let predicate = "subsystem BEGINSWITH 'com.apple.network' OR subsystem BEGINSWITH 'com.apple.CFNetwork' OR subsystem CONTAINS 'Network' OR category CONTAINS 'Network'"
        let output = try await ProcessRunner.runFor(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "simctl", "spawn", deviceUDID,
                "log", "stream",
                "--style", "ndjson",
                "--level", "info",
                "--predicate", predicate,
            ],
            durationSeconds: max(0.25, seconds)
        )
        let events = parseNetworkEvents(output.stdoutString)
        let warnings = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? []
            : [output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)]
        return NetworkSnapshotPayload(
            supported: true,
            deviceUDID: deviceUDID,
            collectedSeconds: max(0.25, seconds),
            events: Array(events.prefix(max(0, limit))),
            warnings: warnings
        )
    }

    public static func parseNetworkEvents(_ text: String) -> [NetworkEvent] {
        text.split(separator: "\n", omittingEmptySubsequences: true).enumerated().compactMap { index, line in
            guard let data = String(line).data(using: .utf8),
                  let value = try? JSON.decoder.decode(JSONValue.self, from: data),
                  let object = value.objectValue else { return nil }
            return NetworkEvent(
                id: object["traceID"]?.stringValue ?? object["machTimestamp"]?.stringValue ?? "event-\(index)",
                timestamp: object["timestamp"]?.stringValue,
                process: object["processImagePath"]?.stringValue?.split(separator: "/").last.map(String.init),
                processID: object["processID"]?.doubleValue.map(Int.init),
                subsystem: object["subsystem"]?.stringValue,
                category: object["category"]?.stringValue,
                messageType: object["messageType"]?.stringValue,
                eventMessage: object["eventMessage"]?.stringValue,
                raw: value
            )
        }
    }
}

public enum SimulatorNetworkLoggerClient {
    public static func events(
        deviceUDID: String,
        appBundleID: String,
        filter: NetworkLoggerEventFilter = NetworkLoggerEventFilter()
    ) async throws -> NetworkLoggerEventsPayload {
        let container = try await appDataContainer(deviceUDID: deviceUDID, appBundleID: appBundleID)
        let fileURL = container.appendingPathComponent(NetworkLoggerFileSink.appContainerRelativePath, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return NetworkLoggerEventsPayload(events: [])
        }
        return try readEvents(fileURL: fileURL, filter: filter)
    }

    public static func readEvents(
        fileURL: URL,
        filter: NetworkLoggerEventFilter = NetworkLoggerEventFilter()
    ) throws -> NetworkLoggerEventsPayload {
        try NetworkLoggerJSONL.readEvents(from: fileURL, filter: filter)
    }

    public static func parseEvents(
        _ text: String,
        filter: NetworkLoggerEventFilter = NetworkLoggerEventFilter()
    ) -> NetworkLoggerEventsPayload {
        let events = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> NetworkLoggerEvent? in
            try? NetworkLoggerJSON.decoder.decode(NetworkLoggerEvent.self, from: Data(line.utf8))
        }
        return NetworkLoggerEventsPayload(events: filter.apply(to: events))
    }

    private static func appDataContainer(deviceUDID: String, appBundleID: String) async throws -> URL {
        let output = try await ProcessRunner.runXcrun([
            "simctl",
            "get_app_container",
            deviceUDID,
            appBundleID,
            "data",
        ])
        guard output.status == 0 else {
            let detail = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimToolError("Unable to resolve app data container for \(appBundleID): \(detail.isEmpty ? "simctl get_app_container failed" : detail)")
        }
        let path = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw SimToolError("Unable to resolve app data container for \(appBundleID): simctl returned an empty path")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
