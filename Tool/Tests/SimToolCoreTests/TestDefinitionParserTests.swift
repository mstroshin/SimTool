import SimToolCore
import XCTest

final class TestDefinitionParserTests: XCTestCase {
    func testParsesFullTest() throws {
        let test = try TestDefinitionParser.parse("""
        name: Tab bar badge
        app: com.example.demo
        launchArguments: [-SampleMode, "1"]
        timeout: 15
        steps:
          - waitFor: { id: settingsButton, timeout: 20 }
          - tap: { id: settingsButton }
          - longPress: { id: optionToggle, duration: 1.5, timeout: 20 }
          - type: "hello"
          - swipe: up
          - assertVisible: { text: "Welcome" }
          - assertHidden: { label: "Badge" }
          - wait: 2
        """)

        XCTAssertEqual(test.name, "Tab bar badge")
        XCTAssertEqual(test.app, "com.example.demo")
        XCTAssertEqual(test.launchArguments, ["-SampleMode", "1"])
        XCTAssertEqual(test.stepTimeout, 15)
        XCTAssertEqual(test.steps, [
            .waitFor(TestTarget(kind: .id, query: "settingsButton"), timeout: 20),
            .tap(TestTarget(kind: .id, query: "settingsButton"), timeout: nil),
            .longPress(TestTarget(kind: .id, query: "optionToggle"), duration: 1.5, timeout: 20),
            .type("hello"),
            .swipe(.up),
            .waitFor(TestTarget(kind: .text, query: "Welcome"), timeout: nil),
            .assertHidden(TestTarget(kind: .label, query: "Badge"), timeout: nil),
            .pause(2),
        ])
    }

    func testLongPressDurationIsOptional() throws {
        let test = try TestDefinitionParser.parse("""
        steps:
          - longPress: { label: "Home" }
        """)
        XCTAssertEqual(test.steps, [.longPress(TestTarget(kind: .label, query: "Home"), duration: nil, timeout: nil)])
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
        XCTAssertEqual(test.steps, [.tap(TestTarget(kind: .text, query: "Continue"), timeout: nil)])
        XCTAssertEqual(test.stepTimeout, 10)
    }

    func testNumericLaunchArgumentsBecomeStrings() throws {
        let test = try TestDefinitionParser.parse("""
        launchArguments: [-SampleCode, 111111]
        steps:
          - wait: 1
        """)
        XCTAssertEqual(test.launchArguments, ["-SampleCode", "111111"])
    }

    func testParsesDescription() throws {
        let test = try TestDefinitionParser.parse("""
        name: Badges
        description: >
          Settings state: Settings shows the current value,
          selecting Settings updates it.
        steps:
          - wait: 1
        """)
        XCTAssertEqual(
            test.description,
            "Settings state: Settings shows the current value, selecting Settings updates it."
        )
    }

    func testParsesSetupAndEnvironment() throws {
        let test = try TestDefinitionParser.parse("""
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
        XCTAssertEqual(test.setup, ["xcrun simctl spawn {udid} defaults delete some.domain some.key"])
        XCTAssertEqual(test.environment, TestEnvironment(sampleAccount: "sample-user", env: "stable", country: "sample-region"))
        XCTAssertEqual(test.effectiveLaunchArguments, [
            "-SampleAccount", "sample-user",
            "-SampleRegion", "sample-region",
            "-UITesting", "-Environment", "stable",
        ])
    }

    func testEffectiveLaunchArgumentsDoNotDuplicateUITesting() throws {
        let test = try TestDefinitionParser.parse("""
        environment:
          env: mock
        launchArguments: [-UITesting, -SampleConfig, some_flag, "true"]
        steps:
          - wait: 1
        """)
        XCTAssertEqual(test.effectiveLaunchArguments, [
            "-UITesting", "-SampleConfig", "some_flag", "true",
            "-Environment", "mock",
        ])
    }

    func testRejectsUnknownEnvironmentKey() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        environment:
          locale: mx
        steps:
          - wait: 1
        """))
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
        environment: {}
        steps:
          - wait: 1
        """))
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
        mocks: []
        steps:
          - wait: 1
        """))
    }

    func testRejectsUnknownSwipeDirection() {
        XCTAssertThrowsError(try TestDefinitionParser.parse("""
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
        XCTAssertTrue(TestTarget(kind: .id, query: "settingsButton").matches(node))
        XCTAssertFalse(TestTarget(kind: .id, query: "chat").matches(node))
        XCTAssertTrue(TestTarget(kind: .label, query: "Chat").matches(node))
        XCTAssertTrue(TestTarget(kind: .text, query: "unread").matches(node))
        XCTAssertFalse(TestTarget(kind: .text, query: "items").matches(node))
    }
}
