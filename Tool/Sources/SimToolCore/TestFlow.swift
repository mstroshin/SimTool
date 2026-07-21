import Foundation
import Yams

/// A declarative UI test flow: launch configuration plus a list of steps
/// executed sequentially against the served simulator. Parsed from YAML:
///
/// ```yaml
/// name: Tab bar badge
/// description: >                  # what is tested and the expected result
///   Settings state: Settings shows the current value, Settings shows the
///   red dot, and selecting Settings updates it.
/// app: com.example.demo        # when present, the app is relaunched before steps
/// environment:                    # rendered into app launch arguments
///   sampleAccount: "sample-user"   # -SampleAccount (Debug/Beta builds)
///   country: sample-region               # -SampleRegion
///   env: stable                   # -UITesting -Environment stable
/// setup:                          # shell commands run before launch; {udid} and
///   - xcrun simctl spawn {udid} … # {app} are substituted; failures are recorded
/// launchArguments: [-SampleMode, "1"]
/// timeout: 10                     # default per-step wait, seconds
/// steps:
///   - waitFor: { id: settingsButton, timeout: 20 }
///   - tap: { id: settingsButton }
///   - type: "hello"
///   - swipe: up
///   - assertVisible: { text: "Welcome" }
///   - assertHidden: { label: "Badge" }
///   - wait: 2
/// ```
public struct TestFlow: Equatable, Sendable {
    public var name: String?
    public var description: String?
    public var app: String?
    public var environment: TestFlowEnvironment?
    public var setup: [String]
    public var launchArguments: [String]
    public var stepTimeout: Double
    public var steps: [TestFlowStep]

    public init(
        name: String? = nil,
        description: String? = nil,
        app: String? = nil,
        environment: TestFlowEnvironment? = nil,
        setup: [String] = [],
        launchArguments: [String] = [],
        stepTimeout: Double = 10,
        steps: [TestFlowStep]
    ) {
        self.name = name
        self.description = description
        self.app = app
        self.environment = environment
        self.setup = setup
        self.launchArguments = launchArguments
        self.stepTimeout = stepTimeout
        self.steps = steps
    }

    /// `launchArguments` plus the arguments rendered from `environment`,
    /// without duplicating `-UITesting` when the flow already passes it.
    public var effectiveLaunchArguments: [String] {
        var arguments = launchArguments
        for argument in environment?.launchArguments ?? [] {
            if argument == "-UITesting", arguments.contains("-UITesting") { continue }
            arguments.append(argument)
        }
        return arguments
    }
}

/// Account and backend selection for the app under test, rendered into the
/// SampleApp debug launch arguments (`-SampleAccount`, `-SampleRegion`,
/// `-UITesting -Environment`).
public struct TestFlowEnvironment: Equatable, Sendable {
    public var sampleAccount: String?
    public var env: String?
    public var country: String?

    public init(sampleAccount: String? = nil, env: String? = nil, country: String? = nil) {
        self.sampleAccount = sampleAccount
        self.env = env
        self.country = country
    }

    public var launchArguments: [String] {
        var arguments: [String] = []
        if let sampleAccount { arguments += ["-SampleAccount", sampleAccount] }
        if let country { arguments += ["-SampleRegion", country] }
        // -Environment is only parsed by the app when -UITesting is present.
        if let env { arguments += ["-UITesting", "-Environment", env] }
        return arguments
    }
}

public struct TestFlowTarget: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Equatable, Sendable {
        case id
        case label
        case text
    }

    public var kind: Kind
    public var query: String

    public init(kind: Kind, query: String) {
        self.kind = kind
        self.query = query
    }

    public var description: String {
        switch kind {
        case .id: "id \"\(query)\""
        case .label: "label \"\(query)\""
        case .text: "\"\(query)\""
        }
    }

    public func matches(_ node: AccessibilityNode) -> Bool {
        switch kind {
        case .id:
            node.accessibilityIdentifier == query
        case .label:
            node.label == query || node.title == query
        case .text:
            [node.accessibilityIdentifier, node.label, node.title, node.value]
                .contains { $0?.localizedCaseInsensitiveContains(query) == true }
        }
    }
}

public enum TestFlowSwipeDirection: String, Equatable, Sendable {
    case up, down, left, right
}

public enum TestFlowStep: Equatable, Sendable, CustomStringConvertible {
    case tap(TestFlowTarget, timeout: Double?)
    case type(String)
    case swipe(TestFlowSwipeDirection)
    case waitFor(TestFlowTarget, timeout: Double?)
    case assertHidden(TestFlowTarget, timeout: Double?)
    case pause(Double)

    public var description: String {
        switch self {
        case .tap(let target, _): "Tap \(target)"
        case .type(let text): "Type \"\(text)\""
        case .swipe(let direction): "Swipe \(direction.rawValue)"
        case .waitFor(let target, _): "Wait for \(target)"
        case .assertHidden(let target, _): "Assert hidden \(target)"
        case .pause(let seconds): "Pause \(seconds.formatted())s"
        }
    }
}

public struct FlowSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String { file }
    public var file: String
    public var name: String?
    public var description: String?
    public var stepCount: Int
    public var parseError: String?

    public init(file: String, name: String? = nil, description: String? = nil, stepCount: Int = 0, parseError: String? = nil) {
        self.file = file
        self.name = name
        self.description = description
        self.stepCount = stepCount
        self.parseError = parseError
    }
}

public struct FlowListPayload: Codable, Equatable, Sendable {
    public var flows: [FlowSummary]
    public init(flows: [FlowSummary]) { self.flows = flows }
}

public struct FlowRunRequest: Codable, Equatable, Sendable {
    public var file: String
    public init(file: String) { self.file = file }
}

public struct FlowRunStatusPayload: Codable, Equatable, Sendable {
    public var active: Bool
    public var file: String?
    public var name: String?
    public var sessionId: String?
    public var completedSteps: Int
    public var totalSteps: Int
    /// running | passed | failed; nil when no flow has run yet.
    public var status: String?
    public var error: String?

    public init(
        active: Bool = false,
        file: String? = nil,
        name: String? = nil,
        sessionId: String? = nil,
        completedSteps: Int = 0,
        totalSteps: Int = 0,
        status: String? = nil,
        error: String? = nil
    ) {
        self.active = active
        self.file = file
        self.name = name
        self.sessionId = sessionId
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.status = status
        self.error = error
    }
}

public enum TestFlowParser {
    public static func load(contentsOf url: URL) throws -> TestFlow {
        let yaml: String
        do {
            yaml = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SimToolError("Cannot read flow file \(url.path): \(error.localizedDescription)")
        }
        return try parse(yaml)
    }

    public static func parse(_ yaml: String) throws -> TestFlow {
        let root: Any?
        do {
            root = try Yams.load(yaml: yaml)
        } catch {
            throw SimToolError("Invalid YAML: \(error.localizedDescription)")
        }
        guard let dictionary = root as? [String: Any] else {
            throw SimToolError("Flow must be a YAML mapping with a `steps` list.")
        }

        let knownKeys: Set<String> = ["name", "description", "app", "environment", "setup", "launchArguments", "timeout", "steps"]
        if let unknown = dictionary.keys.first(where: { !knownKeys.contains($0) }) {
            throw SimToolError("Unknown flow key `\(unknown)`. Known keys: \(knownKeys.sorted().joined(separator: ", ")).")
        }

        guard let rawSteps = dictionary["steps"] as? [Any], !rawSteps.isEmpty else {
            throw SimToolError("Flow must contain a non-empty `steps` list.")
        }

        let launchArguments: [String]
        if let rawArguments = dictionary["launchArguments"] {
            guard let list = rawArguments as? [Any] else {
                throw SimToolError("`launchArguments` must be a list.")
            }
            launchArguments = list.map(scalarString)
        } else {
            launchArguments = []
        }

        let setup: [String]
        if let rawSetup = dictionary["setup"] {
            guard let list = rawSetup as? [Any] else {
                throw SimToolError("`setup` must be a list of shell commands.")
            }
            setup = list.map(scalarString)
        } else {
            setup = []
        }

        return TestFlow(
            name: dictionary["name"].map(scalarString),
            description: dictionary["description"].map { scalarString($0).trimmingCharacters(in: .whitespacesAndNewlines) },
            app: dictionary["app"].map(scalarString),
            environment: try dictionary["environment"].map(parseEnvironment),
            setup: setup,
            launchArguments: launchArguments,
            stepTimeout: try dictionary["timeout"].map { try seconds($0, context: "timeout") } ?? 10,
            steps: try rawSteps.enumerated().map { try parseStep($1, index: $0) }
        )
    }

    private static func parseEnvironment(_ value: Any) throws -> TestFlowEnvironment {
        guard let dictionary = value as? [String: Any] else {
            throw SimToolError("`environment` must be a mapping with `sampleAccount`, `env` and/or `country`.")
        }
        let knownKeys: Set<String> = ["sampleAccount", "env", "country"]
        if let unknown = dictionary.keys.first(where: { !knownKeys.contains($0) }) {
            throw SimToolError("environment: unknown key `\(unknown)`. Known keys: \(knownKeys.sorted().joined(separator: ", ")).")
        }
        guard !dictionary.isEmpty else {
            throw SimToolError("`environment` must set at least one of `sampleAccount`, `env`, `country`.")
        }
        return TestFlowEnvironment(
            sampleAccount: dictionary["sampleAccount"].map(scalarString),
            env: dictionary["env"].map(scalarString),
            country: dictionary["country"].map(scalarString)
        )
    }

    private static func parseStep(_ raw: Any, index: Int) throws -> TestFlowStep {
        guard let dictionary = raw as? [String: Any], dictionary.count == 1,
              let (keyword, value) = dictionary.first else {
            throw SimToolError("Step \(index + 1) must be a single-key mapping like `- tap: {id: someId}`.")
        }
        let context = "step \(index + 1) (\(keyword))"
        switch keyword {
        case "tap":
            let (target, timeout) = try targetAndTimeout(value, context: context)
            return .tap(target, timeout: timeout)
        case "type":
            return .type(scalarString(value))
        case "swipe":
            let raw = scalarString(value)
            guard let direction = TestFlowSwipeDirection(rawValue: raw) else {
                throw SimToolError("\(context): unknown direction `\(raw)`. Use up, down, left or right.")
            }
            return .swipe(direction)
        case "waitFor", "assertVisible":
            let (target, timeout) = try targetAndTimeout(value, context: context)
            return .waitFor(target, timeout: timeout)
        case "assertHidden":
            let (target, timeout) = try targetAndTimeout(value, context: context)
            return .assertHidden(target, timeout: timeout)
        case "wait":
            return .pause(try seconds(value, context: context))
        default:
            throw SimToolError("Step \(index + 1): unknown step `\(keyword)`. Known steps: tap, type, swipe, waitFor, assertVisible, assertHidden, wait.")
        }
    }

    /// A target is either a bare string (matched as `text`) or a mapping with
    /// exactly one of `id` / `label` / `text`, plus an optional `timeout`.
    private static func targetAndTimeout(_ value: Any, context: String) throws -> (TestFlowTarget, Double?) {
        if let dictionary = value as? [String: Any] {
            let kinds: [TestFlowTarget.Kind] = [.id, .label, .text]
            let present = kinds.filter { dictionary[$0.rawValue] != nil }
            guard present.count == 1 else {
                throw SimToolError("\(context): provide exactly one of `id`, `label` or `text`.")
            }
            if let unknown = dictionary.keys.first(where: { $0 != present[0].rawValue && $0 != "timeout" }) {
                throw SimToolError("\(context): unknown key `\(unknown)`.")
            }
            return (
                TestFlowTarget(kind: present[0], query: scalarString(dictionary[present[0].rawValue]!)),
                try dictionary["timeout"].map { try seconds($0, context: context) }
            )
        }
        return (TestFlowTarget(kind: .text, query: scalarString(value)), nil)
    }

    private static func seconds(_ value: Any, context: String) throws -> Double {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let string = value as? String, let number = Double(string) { return number }
        throw SimToolError("\(context): expected a number of seconds, got `\(scalarString(value))`.")
    }

    /// YAML scalars arrive as String/Int/Double/Bool depending on quoting;
    /// launch arguments and queries always want their literal text form.
    private static func scalarString(_ value: Any) -> String {
        switch value {
        case let string as String: string
        case let bool as Bool: bool ? "true" : "false"
        case let int as Int: String(int)
        case let double as Double: String(double)
        default: String(describing: value)
        }
    }
}
