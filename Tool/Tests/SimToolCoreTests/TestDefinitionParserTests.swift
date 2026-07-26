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
        XCTAssertEqual(test.launchArguments, ["-UITesting", "1"])
        XCTAssertEqual(test.stepTimeout, 15)
        XCTAssertEqual(test.steps, [
            .waitFor(TestTarget(kind: .id, query: "settingsButton"), timeout: 20),
            .tap(TestTarget(kind: .id, query: "settingsButton"), timeout: nil),
            .longPress(TestTarget(kind: .id, query: "optionToggle"), duration: 1.5, timeout: 20),
            .type("hello"),
            .swipe(.up),
            .waitFor(TestTarget(kind: .text, query: "Welcome"), timeout: nil),
            .assertHidden(TestTarget(kind: .label, query: "Loading"), timeout: nil),
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
        launchArguments: [-SampleCode, 123456]
        steps:
          - wait: 1
        """)
        XCTAssertEqual(test.launchArguments, ["-SampleCode", "123456"])
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
        XCTAssertEqual(test.launchArguments, ["-UITesting", "-SampleMode", "preview"])
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
}
