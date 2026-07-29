import SimToolCore
import XCTest

final class TestDefinitionParserTests: XCTestCase {
    func testParsesFullTest() throws {
        let test = try TestDefinitionParser.parse("""
        name: Settings flow
        app: com.example.demo
        launchArguments: [-UITesting, "1"]
        timeout: 15
        steps:
          - waitFor: { id: settingsButton, timeout: 20 }
          - tap: { id: settingsButton }
          - longPress: { id: optionToggle, duration: 1.5, timeout: 20 }
          - type: "hello"
          - swipe: up
          - assertVisible: { text: "Welcome" }
          - assertHidden: { label: "Loading" }
          - wait: 2
        """)

        XCTAssertEqual(test.name, "Settings flow")
        XCTAssertEqual(test.app, "com.example.demo")
        XCTAssertEqual(test.launch.arguments, ["-UITesting", "1"])
        XCTAssertEqual(test.stepTimeout, 15)
        XCTAssertEqual(test.steps.map(\.action), [
            .waitFor(TestTarget(kind: .id, query: "settingsButton"), timeout: 20),
            .tap(TestTarget(kind: .id, query: "settingsButton"), timeout: nil),
            .longPress(TestTarget(kind: .id, query: "optionToggle"), duration: 1.5, timeout: 20),
            .type("hello"),
            .swipe(.up),
            .waitFor(TestTarget(kind: .text, query: "Welcome"), timeout: nil),
            .assertHidden(TestTarget(kind: .label, query: "Loading"), timeout: nil),
            .pause(2),
        ])
        XCTAssertTrue(test.criteria.isEmpty)
        XCTAssertNil(test.kind)
    }

    func testLongPressDurationIsOptional() throws {
        let test = try TestDefinitionParser.parse("""
        steps:
          - longPress: { label: "Home" }
        """)
        XCTAssertEqual(
            test.steps.map(\.action),
            [.longPress(TestTarget(kind: .label, query: "Home"), duration: nil, timeout: nil)]
        )
    }

    func testRejectsDurationOutsideLongPress() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        steps:
          - tap: { id: x, duration: 2 }
        """)) { error in
            XCTAssertTrue("\(error)".contains("unknown key `duration`"))
        }
    }

    func testShorthandStringTargetIsText() throws {
        let test = try TestDefinitionParser.parse("""
        steps:
          - tap: "Continue"
        """)
        XCTAssertEqual(test.steps.map(\.action), [.tap(TestTarget(kind: .text, query: "Continue"), timeout: nil)])
        XCTAssertEqual(test.stepTimeout, 10)
    }

    func testNumericLaunchArgumentsBecomeStrings() throws {
        let test = try TestDefinitionParser.parse("""
        launchArguments: [-SampleCode, 123456]
        steps:
          - wait: 1
        """)
        XCTAssertEqual(test.launch.arguments, ["-SampleCode", "123456"])
    }

    func testParsesDescription() throws {
        let test = try TestDefinitionParser.parse("""
        name: Preferences
        description: >
          Opening Settings displays the preferences screen,
          and selecting an option updates its value.
        steps:
          - wait: 1
        """)
        XCTAssertEqual(
            test.description,
            "Opening Settings displays the preferences screen, and selecting an option updates its value."
        )
    }

    func testParsesSetupAndLaunchArguments() throws {
        let test = try TestDefinitionParser.parse("""
        app: com.example.demo
        setup:
          - xcrun simctl spawn {udid} defaults delete some.domain some.key
        launchArguments: [-UITesting, -SampleMode, preview]
        steps:
          - wait: 1
        """)
        XCTAssertEqual(test.setup, ["xcrun simctl spawn {udid} defaults delete some.domain some.key"])
        XCTAssertEqual(test.launch.arguments, ["-UITesting", "-SampleMode", "preview"])
    }

    func testRejectsNonListSetup() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        setup: reset everything
        steps:
          - wait: 1
        """))
    }

    func testRejectsEmptySteps() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("steps: []"))
        XCTAssertThrowsError(try TestDefinitionParser.parse("name: x"))
    }

    func testRejectsUnknownStep() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        steps:
          - tapp: { id: x }
        """)) { error in
            XCTAssertTrue("\(error)".contains("unknown step"))
        }
    }

    func testRejectsAmbiguousTarget() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        steps:
          - tap: { id: x, label: y }
        """))
    }

    func testRejectsUnknownTopLevelKey() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        mmocks: []
        steps:
          - wait: 1
        """)) { error in
            XCTAssertTrue("\(error)".contains("Unknown test key `mmocks`"))
        }
    }

    func testRejectsUnknownSwipeDirection() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        steps:
          - swipe: sideways
        """))
    }

    // MARK: - kind, reference, criteria

    func testParsesKindReferenceAndCriteria() throws {
        let test = try TestDefinitionParser.parse("""
        kind: bug
        reference: "reported in the support chat"
        steps:
          - tap: { id: promoBanner }
          - assertVisible: { id: PromoScreenView, criterion: AC-1 }
          - assertHidden: { id: spinner, criterion: "no spinner is left behind" }
        """)
        XCTAssertEqual(test.kind, .bug)
        XCTAssertEqual(test.reference, "reported in the support chat")
        XCTAssertEqual(test.criteria, ["AC-1", "no spinner is left behind"])
        XCTAssertFalse(test.steps[0].isClaim)
        XCTAssertTrue(test.steps[1].isClaim)
    }

    /// Several assertions may share one label; the claim then holds only if all
    /// of them do, so the label is listed once.
    func testRepeatedCriterionLabelIsListedOnce() throws {
        let test = try TestDefinitionParser.parse("""
        kind: feature
        steps:
          - assertVisible: { id: a, criterion: AC-1 }
          - assertVisible: { id: b, criterion: AC-1 }
        """)
        XCTAssertEqual(test.criteria, ["AC-1"])
    }

    func testRejectsUnknownKind() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        kind: regression
        steps:
          - assertVisible: { id: a, criterion: AC-1 }
        """)) { error in
            XCTAssertTrue("\(error)".contains("Unknown `kind`"))
        }
    }

    func testRejectsCriterionOnNonAssertion() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        kind: bug
        steps:
          - tap: { id: x, criterion: AC-1 }
        """)) { error in
            XCTAssertTrue("\(error)".contains("belongs on assertVisible"))
        }
    }

    /// A claim with no verdict machinery behind it, and machinery with nothing to
    /// verify, are both mistakes worth catching at parse time.
    func testRejectsCriterionWithoutKind() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        steps:
          - assertVisible: { id: a, criterion: AC-1 }
        """)) { error in
            XCTAssertTrue("\(error)".contains("needs a `kind:"))
        }
    }

    func testRejectsKindWithoutCriterion() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        kind: feature
        steps:
          - assertVisible: { id: a }
        """)) { error in
            XCTAssertTrue("\(error)".contains("must mark at least one assertion"))
        }
    }

    func testRejectsEmptyCriterionLabel() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        kind: bug
        steps:
          - assertVisible: { id: a, criterion: "  " }
        """))
    }

    // MARK: - launch

    func testParsesLaunchBlock() throws {
        let test = try TestDefinitionParser.parse("""
        launch:
          profile: staging-account1
          arguments: [-RemoteConfig, promo_enabled, true]
          env: { SOME_FLAG: 1 }
          deeplink: myapp://promo
        steps:
          - wait: 1
        """)
        XCTAssertEqual(test.launch.profile, "staging-account1")
        XCTAssertEqual(test.launch.arguments, ["-RemoteConfig", "promo_enabled", "true"])
        XCTAssertEqual(test.launch.environment, ["SOME_FLAG": "1"])
        XCTAssertEqual(test.launch.deeplink, "myapp://promo")
    }

    /// `launchArguments:` predates `launch:`; both are honoured, the top-level
    /// list appending after the block's.
    func testLaunchArgumentsAppendToLaunchBlock() throws {
        let test = try TestDefinitionParser.parse("""
        launch:
          arguments: [-First]
        launchArguments: [-Second]
        steps:
          - wait: 1
        """)
        XCTAssertEqual(test.launch.arguments, ["-First", "-Second"])
    }

    func testRejectsUnknownLaunchKey() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        launch:
          profil: staging
        steps:
          - wait: 1
        """)) { error in
            XCTAssertTrue("\(error)".contains("unknown key `profil`"))
        }
    }

    func testRejectsInvalidEnvironmentKey() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        launch:
          env: { "BAD-KEY": 1 }
        steps:
          - wait: 1
        """))
    }

    func testProfileArgumentsComeFirstAndEnvironmentOverrides() {
        let profile = LaunchProfile(
            name: "staging",
            arguments: ["-UITesting", "-Environment", "staging"],
            environment: ["A": "profile", "B": "profile"],
            deeplink: "myapp://from-profile"
        )
        let launch = TestLaunch(
            profile: "staging",
            arguments: ["-RemoteConfig", "flag", "true"],
            environment: ["B": "test"],
            deeplink: nil
        )
        let resolved = launch.resolved(profile: profile)
        XCTAssertEqual(resolved.arguments, ["-UITesting", "-Environment", "staging", "-RemoteConfig", "flag", "true"])
        XCTAssertEqual(resolved.environment, ["A": "profile", "B": "test"])
        XCTAssertEqual(resolved.deeplink, "myapp://from-profile")
        XCTAssertEqual(resolved.profile, "staging")
    }

    func testVariableExpansion() throws {
        let launch = ResolvedLaunch(arguments: ["-AutoLogin", "${ACCOUNT}"], environment: ["TOKEN": "${SECRET}"])
        let expanded = try launch.resolvingVariables(
            using: ["ACCOUNT": "5512345678", "SECRET": "abc"],
            context: "launch"
        )
        XCTAssertEqual(expanded.arguments, ["-AutoLogin", "5512345678"])
        XCTAssertEqual(expanded.environment, ["TOKEN": "abc"])
    }

    /// An unset variable must fail the run, not expand to nothing: an empty
    /// account argument logs in as nobody and the test tests nothing.
    func testMissingVariableThrows() {
        let launch = ResolvedLaunch(arguments: ["-AutoLogin", "${ACCOUNT}"])
        XCTAssertThrowsError(try launch.resolvingVariables(using: [:], context: "launch")) { error in
            XCTAssertTrue("\(error)".contains("${ACCOUNT}"))
        }
    }

    // MARK: - variables

    func testParsesVariablesAsText() throws {
        let test = try TestDefinitionParser.parse("""
        variables:
          ACCOUNT: "+34600000000"
          PASSCODE: 1234
          SEEDED: true
        steps:
          - wait: 1
        """)

        XCTAssertEqual(test.variables, ["ACCOUNT": "+34600000000", "PASSCODE": "1234", "SEEDED": "true"])
    }

    func testRejectsAVariableNameThatCannotBeReferenced() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        variables:
          "my account": x
        steps:
          - wait: 1
        """)) { error in
            XCTAssertTrue(message(error).contains("only letters, numbers and underscores"), message(error))
        }
    }

    func testRejectsAStructuredVariableValue() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        variables:
          ACCOUNTS: [a, b]
        steps:
          - wait: 1
        """)) { error in
            XCTAssertTrue(message(error).contains("must be a single value"), message(error))
        }
    }

    /// The file wins over the environment so a run is reproducible: a stale
    /// `export` in someone's shell must not silently send the test to another
    /// account than the one it names.
    func testTheTestFileWinsOverTheEnvironmentAndOverridesWinOverBoth() throws {
        let test = try TestDefinitionParser.parse("""
        variables:
          ACCOUNT: from-test
        steps:
          - wait: 1
        """)

        XCTAssertEqual(
            test.resolvedVariables(environment: ["ACCOUNT": "from-shell", "HOME": "/tmp"]),
            ["ACCOUNT": "from-test", "HOME": "/tmp"]
        )
        XCTAssertEqual(
            test.resolvedVariables(environment: ["ACCOUNT": "from-shell"], overrides: ["ACCOUNT": "from-flag"]),
            ["ACCOUNT": "from-flag"]
        )
    }

    func testATestWithoutVariablesStillSeesTheEnvironment() throws {
        let test = try TestDefinitionParser.parse("steps:\n  - wait: 1\n")

        XCTAssertEqual(test.resolvedVariables(environment: ["ACCOUNT": "from-shell"]), ["ACCOUNT": "from-shell"])
    }

    func testUnresolvedVariableErrorNamesEveryWayToSupplyIt() {
        let launch = ResolvedLaunch(arguments: ["-AutoLogin", "${ACCOUNT}"])
        XCTAssertThrowsError(try launch.resolvingVariables(using: [:], context: "launch")) { error in
            let text = message(error)
            XCTAssertTrue(text.contains("`variables:`"), text)
            XCTAssertTrue(text.contains("--var ACCOUNT="), text)
            XCTAssertTrue(text.contains("export it"), text)
        }
    }

    // MARK: - reset

    func testParsesReset() throws {
        let test = try TestDefinitionParser.parse("""
        reset:
          defaults: true
          container: false
          permissions: { att: deny, location: grant }
          locale: es_ES
          language: es
        steps:
          - wait: 1
        """)
        XCTAssertTrue(test.reset.defaults)
        XCTAssertFalse(test.reset.container)
        XCTAssertEqual(test.reset.permissions, [
            TestPermission(service: "att", decision: .deny),
            TestPermission(service: "location", decision: .grant),
        ])
        XCTAssertEqual(test.reset.launchArguments, ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"])
    }

    /// The notification prompt has no simctl backdoor, so accepting it in the
    /// schema would mean silently doing nothing — the exact failure this design
    /// is trying to remove.
    func testRejectsNotificationPermissionWithExplanation() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        reset:
          permissions: { notifications: deny }
        steps:
          - wait: 1
        """)) { error in
            XCTAssertTrue("\(error)".contains("no simctl backdoor"))
        }
    }

    func testRejectsUnknownPermissionDecision() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        reset:
          permissions: { location: maybe }
        steps:
          - wait: 1
        """))
    }

    // MARK: - mocks

    func testParsesMocks() throws {
        let test = try TestDefinitionParser.parse("""
        mocks:
          - method: "*/GetPromo"
            body: { items: [], total: 3 }
            delay: 250
            skip: 1
            times: 2
            strict: true
          - method: "*/GetBalance"
            error: unavailable
            message: backend down
            matchHeaders: { authorization: Bearer x }
            matchBody: '{"id":"7"}'
        steps:
          - wait: 1
        """)
        XCTAssertEqual(test.mocks.count, 2)

        let promo = test.mocks[0]
        XCTAssertEqual(promo.draft.match.method, "*/GetPromo")
        XCTAssertEqual(promo.draft.response.kind, .success)
        // Keys are sorted so the rendered body is stable across runs.
        XCTAssertEqual(promo.draft.response.bodyJSON, "{\"items\":[],\"total\":3}")
        XCTAssertEqual(promo.draft.delayMs, 250)
        XCTAssertEqual(promo.draft.match.skip, 1)
        XCTAssertEqual(promo.draft.match.times, 2)
        XCTAssertTrue(promo.strict)

        let balance = test.mocks[1]
        XCTAssertEqual(balance.draft.response.kind, .error)
        XCTAssertEqual(balance.draft.response.grpcStatus, "unavailable")
        XCTAssertEqual(balance.draft.response.message, "backend down")
        XCTAssertEqual(balance.draft.match.headerMatch, ["authorization": "Bearer x"])
        XCTAssertNotNil(balance.draft.match.bodyMatch)
        XCTAssertFalse(balance.strict)
    }

    func testMockBodyAcceptsJSONString() throws {
        let test = try TestDefinitionParser.parse("""
        mocks:
          - method: "*/GetPromo"
            body: '{"items":[]}'
        steps:
          - wait: 1
        """)
        XCTAssertEqual(test.mocks[0].draft.response.bodyJSON, "{\"items\":[]}")
    }

    func testRejectsUnknownGRPCStatus() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        mocks:
          - method: "*/GetPromo"
            error: exploded
        steps:
          - wait: 1
        """)) { error in
            XCTAssertTrue("\(error)".contains("unknown gRPC status"))
        }
    }

    func testRejectsMockWithBothBodyAndError() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        mocks:
          - method: "*/GetPromo"
            body: { a: 1 }
            error: unavailable
        steps:
          - wait: 1
        """)) { error in
            XCTAssertTrue("\(error)".contains("exactly one of `body` or `error`"))
        }
    }

    func testRejectsMockWithoutMethod() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        mocks:
          - error: unavailable
        steps:
          - wait: 1
        """)) { error in
            XCTAssertTrue("\(error)".contains("missing `method`"))
        }
    }

    func testTargetMatching() {
        let node = AccessibilityNode(
            id: "1",
            accessibilityIdentifier: "actionButton",
            label: "Action",
            value: "3 items",
            children: []
        )
        XCTAssertTrue(TestTarget(kind: .id, query: "actionButton").matches(node))
        XCTAssertFalse(TestTarget(kind: .id, query: "action").matches(node))
        XCTAssertTrue(TestTarget(kind: .label, query: "Action").matches(node))
        XCTAssertTrue(TestTarget(kind: .text, query: "items").matches(node))
        XCTAssertFalse(TestTarget(kind: .text, query: "missing").matches(node))
    }

    private func message(_ error: Error) -> String {
        (error as? SimToolError)?.message ?? error.localizedDescription
    }
}
