import Foundation
import SimToolNetworkLogger
import Yams

/// A declarative UI test: what it claims, how to stage it, and the steps that
/// check it. Parsed from YAML:
///
/// ```yaml
/// name: Settings flow
/// kind: feature                   # bug | feature — makes this a verifying test
/// reference: "PROJ-42"            # optional, free-form; stored, never parsed
/// description: >                  # what is tested and the expected result
///   Opening Settings displays the preferences screen and lets the user
///   enable an option.
/// app: com.example.demo           # when present, the app is relaunched before steps
/// launch:                         # how to launch it
///   profile: staging-account1     #   named recipe from .simtool/config.yml
///   arguments: [-UITesting]       #   appended after the profile's arguments
///   env: { SOME_FLAG: "1" }       #   exported to the app as SIMCTL_CHILD_*
///   deeplink: myapp://settings    #   opened once the app is running
/// reset:                          # simulator state, before launch
///   defaults: true                #   clear the app's UserDefaults
///   container: false              #   wipe the app's data container
///   permissions:                  #   pre-answer permission alerts
///     att: deny
///     location: grant
///   locale: es_ES               #   as -AppleLocale / -AppleLanguages
///   language: es
/// mocks:                          # backend answers, applied before launch
///   - method: "*/GetSettings"
///     body: { items: [] }         #   YAML or a JSON string
///     strict: true                #   the rule must fire, or the run is inconclusive
/// setup:                          # shell commands run before launch; {udid} and
///   - xcrun simctl spawn {udid} … # {app} are substituted; failures are recorded
/// timeout: 10                     # default per-step wait, seconds
/// steps:
///   - waitFor: { id: settingsButton, timeout: 20 }
///   - tap: { id: settingsButton }
///   - longPress: { id: optionToggle, duration: 1.5 }
///   - type: "hello"
///   - swipe: up
///   - assertVisible: { text: "Welcome", criterion: AC-1 }
///   - assertHidden: { label: "Loading" }
///   - wait: 2
/// ```
///
/// Steps carrying a `criterion:` are the claim; every other step merely stages
/// it. That distinction is what lets a run answer "the claim does not hold"
/// (the bug reproduces, or the feature is not done) separately from "the test
/// never reached the state it checks".
public struct TestDefinition: Equatable, Sendable {
    public var name: String?
    public var description: String?
    /// Present when the test verifies a claim. Selects how a failure reads and
    /// whether the run stops at the first unmet criterion.
    public var kind: TestKind?
    /// Free-form origin of the work — an issue key, a URL, "reported in chat".
    /// Stored and displayed, never interpreted: SimTool assumes no tracker.
    public var reference: String?
    public var app: String?
    public var launch: TestLaunch
    public var reset: TestReset
    public var mocks: [TestMock]
    public var setup: [String]
    public var stepTimeout: Double
    public var steps: [TestStep]

    public init(
        name: String? = nil,
        description: String? = nil,
        kind: TestKind? = nil,
        reference: String? = nil,
        app: String? = nil,
        launch: TestLaunch = TestLaunch(),
        reset: TestReset = TestReset(),
        mocks: [TestMock] = [],
        setup: [String] = [],
        stepTimeout: Double = 10,
        steps: [TestStep]
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.reference = reference
        self.app = app
        self.launch = launch
        self.reset = reset
        self.mocks = mocks
        self.setup = setup
        self.stepTimeout = stepTimeout
        self.steps = steps
    }

    /// The distinct criterion labels this test claims, in first-appearance
    /// order. Several assertions may share a label; the claim holds only when
    /// all of them pass.
    public var criteria: [String] {
        var seen = Set<String>()
        return steps.compactMap(\.criterion).filter { seen.insert($0).inserted }
    }
}

/// What a test is verifying. The machinery is identical for both; only the
/// reporting differs, and whether one unmet criterion is enough to stop.
public enum TestKind: String, Codable, Equatable, Sendable, CaseIterable {
    /// The test asserts the expected behaviour of something reported broken.
    /// It fails while the defect is there — that failure *is* the reproduction
    /// — and the first unmet criterion is the whole answer, so the run stops.
    case bug
    /// The test asserts acceptance criteria. Every criterion is reported from
    /// one run, so "AC-1 ok, AC-3 unmet" does not take three runs to learn.
    case feature
}

/// How the app is launched for a run: a named recipe from the project config
/// plus this test's own additions.
public struct TestLaunch: Equatable, Sendable {
    /// Name of a `profiles:` entry in `.simtool/config.yml`.
    public var profile: String?
    /// argv appended after the profile's own arguments.
    public var arguments: [String]
    /// Environment entries, overriding the profile's per key.
    public var environment: [String: String]
    /// Opened after launch; overrides the profile's.
    public var deeplink: String?

    public init(
        profile: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        deeplink: String? = nil
    ) {
        self.profile = profile
        self.arguments = arguments
        self.environment = environment
        self.deeplink = deeplink
    }

    public var isEmpty: Bool {
        profile == nil && arguments.isEmpty && environment.isEmpty && deeplink == nil
    }

    /// Folds a config profile and this test's inline values into one launch.
    /// The profile's arguments come first and the test's are appended: a test
    /// refines a recipe, it does not rewrite it. Environment and deeplink are
    /// overrides, so the test wins per key.
    public func resolved(profile resolvedProfile: LaunchProfile?) -> ResolvedLaunch {
        var environment = resolvedProfile?.environment ?? [:]
        for (key, value) in self.environment { environment[key] = value }
        return ResolvedLaunch(
            profile: resolvedProfile?.name ?? profile,
            arguments: (resolvedProfile?.arguments ?? []) + arguments,
            environment: environment,
            deeplink: deeplink ?? resolvedProfile?.deeplink
        )
    }
}

/// Simulator state to put in a known position before launch. Declarative on
/// purpose: the same intent expressed as `setup:` shell encodes one machine's
/// paths and cannot travel with the test.
public struct TestReset: Equatable, Sendable {
    /// Clear the app's `UserDefaults` domain.
    public var defaults: Bool
    /// Wipe the contents of the app's data container (Documents, Library, tmp)
    /// without reinstalling it.
    public var container: Bool
    /// Permission alerts to pre-answer, in declaration order.
    public var permissions: [TestPermission]
    /// Region override, e.g. `es_ES`. Applied as the standard `-AppleLocale`
    /// launch argument rather than by mutating the device: that is the
    /// documented iOS override, and it cannot leak into another test's run.
    public var locale: String?
    /// Language override, e.g. `es`. Applied as `-AppleLanguages (es)`.
    public var language: String?

    public init(
        defaults: Bool = false,
        container: Bool = false,
        permissions: [TestPermission] = [],
        locale: String? = nil,
        language: String? = nil
    ) {
        self.defaults = defaults
        self.container = container
        self.permissions = permissions
        self.locale = locale
        self.language = language
    }

    public var isEmpty: Bool {
        !defaults && !container && permissions.isEmpty && locale == nil && language == nil
    }

    /// Launch arguments this reset contributes. Prepended to the test's own, so
    /// an explicit `-AppleLanguages` in the test still wins (argv is read
    /// last-wins by `UserDefaults`' argument domain).
    public var launchArguments: [String] {
        var arguments: [String] = []
        if let language { arguments += ["-AppleLanguages", "(\(language))"] }
        if let locale { arguments += ["-AppleLocale", locale] }
        return arguments
    }
}

/// One pre-answered permission. A system alert cannot be driven through the
/// accessibility API — while one is up, the tree is unreadable and a run reads
/// exactly like "the claim does not hold" — so answering them up front is part
/// of staging, not a convenience.
public struct TestPermission: Equatable, Sendable {
    public enum Decision: String, Equatable, Sendable, CaseIterable {
        case grant
        case deny
        /// Back to "not determined", so the next launch prompts again — for
        /// tests whose subject *is* the prompt.
        case reset
    }

    public var service: String
    public var decision: Decision

    public init(service: String, decision: Decision) {
        self.service = service
        self.decision = decision
    }

    /// App Tracking Transparency has no `simctl privacy` service; it is set
    /// directly in the device's TCC database instead.
    public static let appTrackingService = "att"

    /// Services `xcrun simctl privacy` accepts, plus `att`.
    public static let knownServices: [String] = [
        appTrackingService,
        "all", "calendar", "contacts-limited", "contacts", "location", "location-always",
        "photos-add", "photos", "media-library", "microphone", "motion", "reminders", "siri",
    ]
}

/// A mock rule declared by the test itself, so the backend answer a scenario
/// needs travels with it instead of living in whoever ran `simtool mock set`
/// last.
public struct TestMock: Equatable, Sendable {
    public var draft: MockRuleDraft
    /// The rule must actually intercept a call during the run. Without this a
    /// mock that never matched — a wrong method path, a body the app could not
    /// decode — leaves the real backend answering and the run silently tests
    /// something else.
    public var strict: Bool

    public init(draft: MockRuleDraft, strict: Bool = false) {
        self.draft = draft
        self.strict = strict
    }
}

public struct TestTarget: Equatable, Sendable, CustomStringConvertible {
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

public enum TestSwipeDirection: String, Equatable, Sendable {
    case up, down, left, right
}

/// One step: an action, plus the criterion it checks when the step is part of
/// the claim rather than staging for it.
public struct TestStep: Equatable, Sendable, CustomStringConvertible {
    public var action: TestStepAction
    public var criterion: String?

    public init(action: TestStepAction, criterion: String? = nil) {
        self.action = action
        self.criterion = criterion
    }

    /// Whether this step checks the claim. Only assertions can.
    public var isClaim: Bool { criterion != nil }

    // No parens: the viewer's step splitter treats " (" as the start of a
    // collapsible detail block and would hide the criterion.
    public var description: String {
        criterion.map { "\(action) · \($0)" } ?? action.description
    }
}

public enum TestStepAction: Equatable, Sendable, CustomStringConvertible {
    case tap(TestTarget, timeout: Double?)
    case longPress(TestTarget, duration: Double?, timeout: Double?)
    case type(String)
    case swipe(TestSwipeDirection)
    case waitFor(TestTarget, timeout: Double?)
    case assertHidden(TestTarget, timeout: Double?)
    case pause(Double)

    /// Whether this action checks a result, and so may carry a `criterion:`.
    public var isAssertion: Bool {
        switch self {
        case .waitFor, .assertHidden: true
        case .tap, .longPress, .type, .swipe, .pause: false
        }
    }

    public var description: String {
        switch self {
        case .tap(let target, _): "Tap \(target)"
        case .longPress(let target, let duration, _):
            "Long press \(target)" + (duration.map { " · \($0.formatted())s" } ?? "")
        case .type(let text): "Type \"\(text)\""
        case .swipe(let direction): "Swipe \(direction.rawValue)"
        case .waitFor(let target, _): "Wait for \(target)"
        case .assertHidden(let target, _): "Assert hidden \(target)"
        case .pause(let seconds): "Pause \(seconds.formatted())s"
        }
    }
}

public struct TestSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String { file }
    public var file: String
    public var name: String?
    public var description: String?
    public var kind: TestKind?
    public var reference: String?
    public var stepCount: Int
    /// Human-readable step descriptions, in execution order.
    public var steps: [String]
    /// Distinct criterion labels this test claims.
    public var criteria: [String]
    public var parseError: String?

    public init(
        file: String,
        name: String? = nil,
        description: String? = nil,
        kind: TestKind? = nil,
        reference: String? = nil,
        stepCount: Int = 0,
        steps: [String] = [],
        criteria: [String] = [],
        parseError: String? = nil
    ) {
        self.file = file
        self.name = name
        self.description = description
        self.kind = kind
        self.reference = reference
        self.stepCount = stepCount
        self.steps = steps
        self.criteria = criteria
        self.parseError = parseError
    }
}

public struct TestListPayload: Codable, Equatable, Sendable {
    public var tests: [TestSummary]
    public init(tests: [TestSummary]) { self.tests = tests }
}

public struct TestRunRequest: Codable, Equatable, Sendable {
    public var file: String
    /// Record a screen video for the run's session; nil means yes (the default).
    public var video: Bool?

    public init(file: String, video: Bool? = nil) {
        self.file = file
        self.video = video
    }
}

public struct TestRunStatusPayload: Codable, Equatable, Sendable {
    public var active: Bool
    public var file: String?
    public var name: String?
    public var sessionId: String?
    public var completedSteps: Int
    public var totalSteps: Int
    /// running | passed | failed | stopped; nil when no test has run yet.
    public var status: String?
    /// The run's verdict once it finished: satisfied | unsatisfied |
    /// inconclusive | infra. Nil for plain tests and runs still in flight.
    public var verdict: String?
    public var error: String?

    public init(
        active: Bool = false,
        file: String? = nil,
        name: String? = nil,
        sessionId: String? = nil,
        completedSteps: Int = 0,
        totalSteps: Int = 0,
        status: String? = nil,
        verdict: String? = nil,
        error: String? = nil
    ) {
        self.active = active
        self.file = file
        self.name = name
        self.sessionId = sessionId
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.status = status
        self.verdict = verdict
        self.error = error
    }
}

/// Canonical gRPC status names a mock may answer with, shared by the CLI's
/// `--error` flag and the `mocks:` parser so both reject the same typos.
public enum MockGRPCStatus {
    public static let names: Set<String> = [
        "ok", "cancelled", "unknown", "invalidArgument", "deadlineExceeded",
        "notFound", "alreadyExists", "permissionDenied", "resourceExhausted",
        "failedPrecondition", "aborted", "outOfRange", "unimplemented",
        "internal", "unavailable", "dataLoss", "unauthenticated",
    ]

    public static var sortedNames: String { names.sorted().joined(separator: ", ") }
}

public enum TestDefinitionParser {
    /// Summaries of every YAML test in a directory, sorted by file name;
    /// unparseable tests are reported through `parseError` instead of thrown.
    public static func summaries(in root: URL) -> [TestSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                do {
                    let test = try load(contentsOf: url)
                    return TestSummary(
                        file: url.lastPathComponent,
                        name: test.name,
                        description: test.description,
                        kind: test.kind,
                        reference: test.reference,
                        stepCount: test.steps.count,
                        steps: test.steps.map(\.description),
                        criteria: test.criteria
                    )
                } catch {
                    let message = (error as? SimToolError)?.message ?? error.localizedDescription
                    return TestSummary(file: url.lastPathComponent, parseError: message)
                }
            }
    }

    public static func load(contentsOf url: URL) throws -> TestDefinition {
        let yaml: String
        do {
            yaml = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SimToolError("Cannot read test file \(url.path): \(error.localizedDescription)")
        }
        return try parse(yaml)
    }

    public static func parse(_ yaml: String) throws -> TestDefinition {
        let root: Any?
        do {
            root = try Yams.load(yaml: yaml)
        } catch {
            throw SimToolError("Invalid YAML: \(error.localizedDescription)")
        }
        guard let dictionary = root as? [String: Any] else {
            throw SimToolError("Test must be a YAML mapping with a `steps` list.")
        }

        let knownKeys: Set<String> = [
            "name", "description", "kind", "reference", "app", "launch", "reset",
            "mocks", "setup", "launchArguments", "timeout", "steps",
        ]
        if let unknown = dictionary.keys.first(where: { !knownKeys.contains($0) }) {
            throw SimToolError("Unknown test key `\(unknown)`. Known keys: \(knownKeys.sorted().joined(separator: ", ")).")
        }

        guard let rawSteps = dictionary["steps"] as? [Any], !rawSteps.isEmpty else {
            throw SimToolError("Test must contain a non-empty `steps` list.")
        }

        let kind = try dictionary["kind"].map { raw -> TestKind in
            let text = scalarString(raw)
            guard let parsed = TestKind(rawValue: text) else {
                let known = TestKind.allCases.map(\.rawValue).joined(separator: ", ")
                throw SimToolError("Unknown `kind` `\(text)`. Use one of: \(known).")
            }
            return parsed
        }

        var launch = try parseLaunch(dictionary["launch"])
        // `launchArguments:` predates `launch:` and stays supported; the test's
        // own argv is appended after whatever `launch:` contributed.
        if let rawArguments = dictionary["launchArguments"] {
            guard let list = rawArguments as? [Any] else {
                throw SimToolError("`launchArguments` must be a list.")
            }
            launch.arguments += list.map(scalarString)
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

        let steps = try rawSteps.enumerated().map { try parseStep($1, index: $0) }
        let criteria = steps.compactMap(\.criterion)
        if kind == nil, !criteria.isEmpty {
            throw SimToolError("`criterion:` needs a `kind: bug|feature` so the run can be reported as reproduced or confirmed.")
        }
        if let kind, criteria.isEmpty {
            throw SimToolError("A `kind: \(kind.rawValue)` test must mark at least one assertion with `criterion:` — that assertion is the claim the run verifies.")
        }

        return TestDefinition(
            name: dictionary["name"].map(scalarString),
            description: dictionary["description"].map { scalarString($0).trimmingCharacters(in: .whitespacesAndNewlines) },
            kind: kind,
            reference: dictionary["reference"].map { scalarString($0).trimmingCharacters(in: .whitespacesAndNewlines) },
            app: dictionary["app"].map(scalarString),
            launch: launch,
            reset: try parseReset(dictionary["reset"]),
            mocks: try parseMocks(dictionary["mocks"]),
            setup: setup,
            stepTimeout: try dictionary["timeout"].map { try seconds($0, context: "timeout") } ?? 10,
            steps: steps
        )
    }

    // MARK: - launch

    private static func parseLaunch(_ raw: Any?) throws -> TestLaunch {
        guard let raw else { return TestLaunch() }
        guard let dictionary = raw as? [String: Any] else {
            throw SimToolError("`launch` must be a mapping with `profile`, `arguments`, `env` and/or `deeplink`.")
        }
        let known: Set<String> = ["profile", "arguments", "env", "deeplink"]
        if let unknown = dictionary.keys.first(where: { !known.contains($0) }) {
            throw SimToolError("`launch`: unknown key `\(unknown)`. Known keys: \(known.sorted().joined(separator: ", ")).")
        }
        var arguments: [String] = []
        if let rawArguments = dictionary["arguments"] {
            guard let list = rawArguments as? [Any] else {
                throw SimToolError("`launch.arguments` must be a list.")
            }
            arguments = list.map(scalarString)
        }
        var environment: [String: String] = [:]
        if let rawEnvironment = dictionary["env"] {
            guard let mapping = rawEnvironment as? [String: Any] else {
                throw SimToolError("`launch.env` must be a mapping of KEY: value.")
            }
            for (key, value) in mapping {
                guard SimulatorAppLifecycleClient.isValidEnvironmentKey(key) else {
                    throw SimToolError("`launch.env` key `\(key)` may contain only letters, numbers and underscores.")
                }
                environment[key] = scalarString(value)
            }
        }
        return TestLaunch(
            profile: dictionary["profile"].map { scalarString($0).trimmingCharacters(in: .whitespacesAndNewlines) },
            arguments: arguments,
            environment: environment,
            deeplink: dictionary["deeplink"].map { scalarString($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    // MARK: - reset

    private static func parseReset(_ raw: Any?) throws -> TestReset {
        guard let raw else { return TestReset() }
        guard let dictionary = raw as? [String: Any] else {
            throw SimToolError("`reset` must be a mapping.")
        }
        let known: Set<String> = ["defaults", "container", "permissions", "locale", "language"]
        if let unknown = dictionary.keys.first(where: { !known.contains($0) }) {
            throw SimToolError("`reset`: unknown key `\(unknown)`. Known keys: \(known.sorted().joined(separator: ", ")).")
        }

        var permissions: [TestPermission] = []
        if let rawPermissions = dictionary["permissions"] {
            guard let mapping = rawPermissions as? [String: Any] else {
                throw SimToolError("`reset.permissions` must be a mapping of service: grant|deny|reset.")
            }
            for (service, rawDecision) in mapping.sorted(by: { $0.key < $1.key }) {
                guard TestPermission.knownServices.contains(service) else {
                    let known = TestPermission.knownServices.joined(separator: ", ")
                    let extra = service == "notifications"
                        ? " The notification prompt has no simctl backdoor: answer it once by hand and it stays answered for that install."
                        : ""
                    throw SimToolError("`reset.permissions`: unknown service `\(service)`. Known services: \(known).\(extra)")
                }
                let text = scalarString(rawDecision)
                guard let decision = TestPermission.Decision(rawValue: text) else {
                    let known = TestPermission.Decision.allCases.map(\.rawValue).joined(separator: ", ")
                    throw SimToolError("`reset.permissions.\(service)`: unknown value `\(text)`. Use one of: \(known).")
                }
                permissions.append(TestPermission(service: service, decision: decision))
            }
        }

        return TestReset(
            defaults: try boolean(dictionary["defaults"], context: "reset.defaults") ?? false,
            container: try boolean(dictionary["container"], context: "reset.container") ?? false,
            permissions: permissions,
            locale: dictionary["locale"].map(scalarString),
            language: dictionary["language"].map(scalarString)
        )
    }

    // MARK: - mocks

    private static func parseMocks(_ raw: Any?) throws -> [TestMock] {
        guard let raw else { return [] }
        guard let list = raw as? [Any] else {
            throw SimToolError("`mocks` must be a list of rules.")
        }
        return try list.enumerated().map { index, element in
            let context = "mocks[\(index)]"
            guard let dictionary = element as? [String: Any] else {
                throw SimToolError("\(context) must be a mapping with at least `method` and one of `body`/`error`.")
            }
            let known: Set<String> = [
                "method", "matchHeaders", "matchBody", "body", "error", "message",
                "delay", "skip", "times", "strict",
            ]
            if let unknown = dictionary.keys.first(where: { !known.contains($0) }) {
                throw SimToolError("\(context): unknown key `\(unknown)`. Known keys: \(known.sorted().joined(separator: ", ")).")
            }
            guard let method = dictionary["method"].map(scalarString), !method.isEmpty else {
                throw SimToolError("\(context) is missing `method` — the gRPC full-method or HTTP path to match (`*` globs).")
            }

            var headerMatch: [String: String] = [:]
            if let rawHeaders = dictionary["matchHeaders"] {
                guard let mapping = rawHeaders as? [String: Any] else {
                    throw SimToolError("\(context).matchHeaders must be a mapping of header: value.")
                }
                for (key, value) in mapping { headerMatch[key] = scalarString(value) }
            }

            let bodyMatch = try dictionary["matchBody"].map { value in
                try decodeJSONValue(jsonText(from: value, context: "\(context).matchBody"), context: "\(context).matchBody")
            }

            let response: MockResponse
            switch (dictionary["body"], dictionary["error"]) {
            case let (body?, nil):
                response = MockResponse(
                    kind: .success,
                    bodyJSON: try jsonText(from: body, context: "\(context).body")
                )
            case let (nil, error?):
                let status = scalarString(error)
                guard MockGRPCStatus.names.contains(status) else {
                    throw SimToolError("\(context): unknown gRPC status `\(status)`. Expected one of: \(MockGRPCStatus.sortedNames)")
                }
                response = MockResponse(
                    kind: .error,
                    grpcStatus: status,
                    message: dictionary["message"].map(scalarString)
                )
            default:
                throw SimToolError("\(context): provide exactly one of `body` or `error`.")
            }

            let draft = MockRuleDraft(
                match: MockMatch(
                    method: method,
                    headerMatch: headerMatch.isEmpty ? nil : headerMatch,
                    bodyMatch: bodyMatch,
                    skip: try integer(dictionary["skip"], context: "\(context).skip") ?? 0,
                    times: try integer(dictionary["times"], context: "\(context).times")
                ),
                response: response,
                delayMs: try integer(dictionary["delay"], context: "\(context).delay") ?? 0
            )
            return TestMock(
                draft: draft,
                strict: try boolean(dictionary["strict"], context: "\(context).strict") ?? false
            )
        }
    }

    /// A mock body may be written as YAML (the readable form) or as a JSON
    /// string (handy when pasted from a real response); both end up as the JSON
    /// text the app decodes into its typed response.
    private static func jsonText(from value: Any, context: String) throws -> String {
        if let text = value as? String { return text }
        let json = try jsonSafe(value, context: context)
        guard JSONSerialization.isValidJSONObject(json) || json is [Any] else {
            throw SimToolError("\(context) must be a JSON object, a list, or a JSON string.")
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw SimToolError("\(context) could not be rendered as JSON text.")
        }
        return text
    }

    /// Maps YAML-decoded values onto types `JSONSerialization` accepts. Dates
    /// are the one YAML scalar with no JSON counterpart; render them ISO-8601.
    private static func jsonSafe(_ value: Any, context: String) throws -> Any {
        switch value {
        case let mapping as [String: Any]:
            return try mapping.mapValues { try jsonSafe($0, context: context) }
        case let list as [Any]:
            return try list.map { try jsonSafe($0, context: context) }
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case is String, is Int, is Double, is Bool, is NSNull:
            return value
        default:
            throw SimToolError("\(context) contains a value that cannot be rendered as JSON: \(value).")
        }
    }

    private static func decodeJSONValue(_ text: String, context: String) throws -> NetworkLoggerJSONValue {
        do {
            return try NetworkLoggerJSON.decoder.decode(NetworkLoggerJSONValue.self, from: Data(text.utf8))
        } catch {
            throw SimToolError("\(context) is not valid JSON: \(error.localizedDescription)")
        }
    }

    // MARK: - steps

    private static func parseStep(_ raw: Any, index: Int) throws -> TestStep {
        guard let dictionary = raw as? [String: Any], dictionary.count == 1,
              let (keyword, value) = dictionary.first else {
            throw SimToolError("Step \(index + 1) must be a single-key mapping like `- tap: {id: someId}`.")
        }
        let context = "step \(index + 1) (\(keyword))"
        let criterion = try criterionLabel(in: value, context: context)
        let action: TestStepAction
        switch keyword {
        case "tap":
            let (target, timeout) = try targetAndTimeout(value, context: context)
            action = .tap(target, timeout: timeout)
        case "longPress":
            let (target, timeout, duration) = try targetTimeoutAndDuration(value, context: context)
            action = .longPress(target, duration: duration, timeout: timeout)
        case "type":
            action = .type(scalarString(value))
        case "swipe":
            let raw = scalarString(value)
            guard let direction = TestSwipeDirection(rawValue: raw) else {
                throw SimToolError("\(context): unknown direction `\(raw)`. Use up, down, left or right.")
            }
            action = .swipe(direction)
        case "waitFor", "assertVisible":
            let (target, timeout) = try targetAndTimeout(value, context: context)
            action = .waitFor(target, timeout: timeout)
        case "assertHidden":
            let (target, timeout) = try targetAndTimeout(value, context: context)
            action = .assertHidden(target, timeout: timeout)
        case "wait":
            action = .pause(try seconds(value, context: context))
        default:
            throw SimToolError("Step \(index + 1): unknown step `\(keyword)`. Known steps: tap, longPress, type, swipe, waitFor, assertVisible, assertHidden, wait.")
        }
        if criterion != nil, !action.isAssertion {
            throw SimToolError("\(context): `criterion:` marks the assertion that checks the claim, so it belongs on assertVisible, assertHidden or waitFor — not on `\(keyword)`.")
        }
        return TestStep(action: action, criterion: criterion)
    }

    private static func criterionLabel(in value: Any, context: String) throws -> String? {
        guard let dictionary = value as? [String: Any], let raw = dictionary["criterion"] else { return nil }
        let label = scalarString(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            throw SimToolError("\(context): `criterion:` must be a non-empty label, e.g. `AC-1` or a short sentence.")
        }
        return label
    }

    /// A target is either a bare string (matched as `text`) or a mapping with
    /// exactly one of `id` / `label` / `text`, plus an optional `timeout`.
    private static func targetAndTimeout(_ value: Any, context: String) throws -> (TestTarget, Double?) {
        let (target, timeout, _) = try parseTarget(value, context: context, allowDuration: false)
        return (target, timeout)
    }

    private static func targetTimeoutAndDuration(_ value: Any, context: String) throws -> (TestTarget, Double?, Double?) {
        try parseTarget(value, context: context, allowDuration: true)
    }

    private static func parseTarget(
        _ value: Any,
        context: String,
        allowDuration: Bool
    ) throws -> (TestTarget, Double?, Double?) {
        if let dictionary = value as? [String: Any] {
            let kinds: [TestTarget.Kind] = [.id, .label, .text]
            let present = kinds.filter { dictionary[$0.rawValue] != nil }
            guard present.count == 1 else {
                throw SimToolError("\(context): provide exactly one of `id`, `label` or `text`.")
            }
            var extras = allowDuration ? ["timeout", "duration"] : ["timeout"]
            extras.append("criterion")
            if let unknown = dictionary.keys.first(where: { $0 != present[0].rawValue && !extras.contains($0) }) {
                throw SimToolError("\(context): unknown key `\(unknown)`.")
            }
            return (
                TestTarget(kind: present[0], query: scalarString(dictionary[present[0].rawValue]!)),
                try dictionary["timeout"].map { try seconds($0, context: context) },
                try dictionary["duration"].map { try seconds($0, context: context) }
            )
        }
        return (TestTarget(kind: .text, query: scalarString(value)), nil, nil)
    }

    private static func seconds(_ value: Any, context: String) throws -> Double {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let string = value as? String, let number = Double(string) { return number }
        throw SimToolError("\(context): expected a number of seconds, got `\(scalarString(value))`.")
    }

    private static func integer(_ value: Any?, context: String) throws -> Int? {
        guard let value else { return nil }
        if let number = value as? Int { return number }
        if let number = value as? Double, number == number.rounded() { return Int(number) }
        if let string = value as? String, let number = Int(string) { return number }
        throw SimToolError("\(context): expected a whole number, got `\(scalarString(value))`.")
    }

    private static func boolean(_ value: Any?, context: String) throws -> Bool? {
        guard let value else { return nil }
        if let flag = value as? Bool { return flag }
        if let string = value as? String {
            if ["true", "yes"].contains(string.lowercased()) { return true }
            if ["false", "no"].contains(string.lowercased()) { return false }
        }
        throw SimToolError("\(context): expected true or false, got `\(scalarString(value))`.")
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
