import SimToolCore
import XCTest

final class TestFlowParserTests: XCTestCase {
    func testParsesFullFlow() throws {
        let flow = try TestFlowParser.parse("""
        name: Tab bar badge
        app: com.example.demo
        launchArguments: [-SampleMode, "1"]
        timeout: 15
        steps:
          - waitFor: { id: settingsButton, timeout: 20 }
          - tap: { id: settingsButton }
          - type: "hello"
          - swipe: up
          - assertVisible: { text: "Welcome" }
          - assertHidden: { label: "Badge" }
          - wait: 2
        """)

        XCTAssertEqual(flow.name, "Tab bar badge")
        XCTAssertEqual(flow.app, "com.example.demo")
        XCTAssertEqual(flow.launchArguments, ["-SampleMode", "1"])
        XCTAssertEqual(flow.stepTimeout, 15)
        XCTAssertEqual(flow.steps, [
            .waitFor(TestFlowTarget(kind: .id, query: "settingsButton"), timeout: 20),
            .tap(TestFlowTarget(kind: .id, query: "settingsButton"), timeout: nil),
            .type("hello"),
            .swipe(.up),
            .waitFor(TestFlowTarget(kind: .text, query: "Welcome"), timeout: nil),
            .assertHidden(TestFlowTarget(kind: .label, query: "Badge"), timeout: nil),
            .pause(2),
        ])
    }

    func testShorthandStringTargetIsText() throws {
        let flow = try TestFlowParser.parse("""
        steps:
          - tap: "Continue"
        """)
        XCTAssertEqual(flow.steps, [.tap(TestFlowTarget(kind: .text, query: "Continue"), timeout: nil)])
        XCTAssertEqual(flow.stepTimeout, 10)
    }

    func testNumericLaunchArgumentsBecomeStrings() throws {
        let flow = try TestFlowParser.parse("""
        launchArguments: [-SampleCode, 111111]
        steps:
          - wait: 1
        """)
        XCTAssertEqual(flow.launchArguments, ["-SampleCode", "111111"])
    }

    func testParsesDescription() throws {
        let flow = try TestFlowParser.parse("""
        name: Badges
        description: >
          Settings state: Settings shows the current value,
          selecting Settings updates it.
        steps:
          - wait: 1
        """)
        XCTAssertEqual(
            flow.description,
            "Settings state: Settings shows the current value, selecting Settings updates it."
        )
    }

    func testParsesSetupAndEnvironment() throws {
        let flow = try TestFlowParser.parse("""
        app: com.example.demo
        environment:
          sampleAccount: "sample-user"
          country: sample-region
          env: stable
        setup:
          - xcrun simctl spawn {udid} defaults delete some.domain some.key
        steps:
          - wait: 1
        """)
        XCTAssertEqual(flow.setup, ["xcrun simctl spawn {udid} defaults delete some.domain some.key"])
        XCTAssertEqual(flow.environment, TestFlowEnvironment(sampleAccount: "sample-user", env: "stable", country: "sample-region"))
        XCTAssertEqual(flow.effectiveLaunchArguments, [
            "-SampleAccount", "sample-user",
            "-SampleRegion", "sample-region",
            "-UITesting", "-Environment", "stable",
        ])
    }

    func testEffectiveLaunchArgumentsDoNotDuplicateUITesting() throws {
        let flow = try TestFlowParser.parse("""
        environment:
          env: mock
        launchArguments: [-UITesting, -SampleConfig, some_flag, "true"]
        steps:
          - wait: 1
        """)
        XCTAssertEqual(flow.effectiveLaunchArguments, [
            "-UITesting", "-SampleConfig", "some_flag", "true",
            "-Environment", "mock",
        ])
    }

    func testRejectsUnknownEnvironmentKey() {
        XCTAssertThrowsError(try TestFlowParser.parse("""
        environment:
          locale: mx
        steps:
          - wait: 1
        """))
        XCTAssertThrowsError(try TestFlowParser.parse("""
        environment: {}
        steps:
          - wait: 1
        """))
    }

    func testRejectsNonListSetup() {
        XCTAssertThrowsError(try TestFlowParser.parse("""
        setup: reset everything
        steps:
          - wait: 1
        """))
    }

    func testRejectsEmptySteps() {
        XCTAssertThrowsError(try TestFlowParser.parse("steps: []"))
        XCTAssertThrowsError(try TestFlowParser.parse("name: x"))
    }

    func testRejectsUnknownStep() {
        XCTAssertThrowsError(try TestFlowParser.parse("""
        steps:
          - tapp: { id: x }
        """)) { error in
            XCTAssertTrue("\(error)".contains("unknown step"))
        }
    }

    func testRejectsAmbiguousTarget() {
        XCTAssertThrowsError(try TestFlowParser.parse("""
        steps:
          - tap: { id: x, label: y }
        """))
    }

    func testRejectsUnknownTopLevelKey() {
        XCTAssertThrowsError(try TestFlowParser.parse("""
        mocks: []
        steps:
          - wait: 1
        """))
    }

    func testRejectsUnknownSwipeDirection() {
        XCTAssertThrowsError(try TestFlowParser.parse("""
        steps:
          - swipe: sideways
        """))
    }

    func testTargetMatching() {
        let node = AccessibilityNode(
            id: "1",
            accessibilityIdentifier: "settingsButton",
            label: "Chat",
            value: "3 unread",
            children: []
        )
        XCTAssertTrue(TestFlowTarget(kind: .id, query: "settingsButton").matches(node))
        XCTAssertFalse(TestFlowTarget(kind: .id, query: "chat").matches(node))
        XCTAssertTrue(TestFlowTarget(kind: .label, query: "Chat").matches(node))
        XCTAssertTrue(TestFlowTarget(kind: .text, query: "unread").matches(node))
        XCTAssertFalse(TestFlowTarget(kind: .text, query: "items").matches(node))
    }
}
