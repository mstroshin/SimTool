import XCTest
@testable import SimToolCore

final class PasteVerificationTests: XCTestCase {
    // Shape of `simctl spawn <udid> launchctl list`: pid, last exit status, label.
    private let launchctlList = """
    PID\tStatus\tLabel
    91564\t0\tUIKitApplication:com.apple.Spotlight[08b0][rb-legacy]
    92893\t0\tUIKitApplication:com.example.app.debug[e789][rb-legacy]
    90822\t0\tcom.apple.SpringBoard
    -\t0\tcom.apple.pasteboard.pasted
    """

    func testBundleIDComesFromTheAppsLaunchdJob() {
        XCTAssertEqual(PasteVerification.bundleID(forPID: 92893, launchctlList: launchctlList), "com.example.app.debug")
        XCTAssertEqual(PasteVerification.bundleID(forPID: 91564, launchctlList: launchctlList), "com.apple.Spotlight")
    }

    func testBundleIDIsNilForNonAppProcessesAndUnknownPids() {
        // SpringBoard is not a UIKitApplication job, so there is no app to grant.
        XCTAssertNil(PasteVerification.bundleID(forPID: 90822, launchctlList: launchctlList))
        XCTAssertNil(PasteVerification.bundleID(forPID: 4242, launchctlList: launchctlList))
    }

    func testForegroundPIDIsTheApplicationRoot() throws {
        let tree = try SimulatorAccessibilityClient.parseTree(Data(#"""
        [{"type": "Application", "AXLabel": "Example", "pid": 92893, "children": []}]
        """#.utf8))
        XCTAssertEqual(PasteVerification.foregroundPID(in: tree), 92893)
    }

    func testTextInputsCaptureFieldAndTextViewValues() throws {
        let before = try tree(field: "", textView: "")
        let pasted = try tree(field: "Привет, señor 🎉", textView: "")

        XCTAssertEqual(PasteVerification.textInputs(in: before).count, 2)
        XCTAssertNotEqual(PasteVerification.textInputs(in: before), PasteVerification.textInputs(in: pasted))
    }

    func testTextInputsIgnoreNonInputValueChanges() throws {
        // Status bar values and scroll indicators change on their own; only text
        // inputs count as evidence that the paste landed.
        let before = try tree(field: "a", textView: "b", battery: "Charging")
        let after = try tree(field: "a", textView: "b", battery: "Not charging")

        XCTAssertEqual(PasteVerification.textInputs(in: before), PasteVerification.textInputs(in: after))
    }

    func testKeyboardIsRecognisedByUIKitsOwnIdentifiers() throws {
        let withKeyboard = try SimulatorAccessibilityClient.parseTree(Data(#"""
        [{"type": "Application", "pid": 1, "children": [
          {"type": "Group", "AXUniqueId": "inputView", "children": [
            {"type": "Group", "AXUniqueId": "UIKeyboardLayoutStar Preview", "children": [
              {"type": "Button", "AXUniqueId": "space", "children": []}
            ]}
          ]}
        ]}]
        """#.utf8))
        // An app's own "delete" or "space" button is not a keyboard.
        let appButtons = try SimulatorAccessibilityClient.parseTree(Data(#"""
        [{"type": "Application", "pid": 1, "children": [
          {"type": "Button", "AXUniqueId": "delete", "children": []},
          {"type": "Button", "AXUniqueId": "space", "children": []}
        ]}]
        """#.utf8))

        XCTAssertTrue(PasteVerification.isKeyboardVisible(in: withKeyboard))
        XCTAssertFalse(PasteVerification.isKeyboardVisible(in: appButtons))
    }

    private func tree(field: String, textView: String, battery: String = "Charging") throws -> AccessibilityTreePayload {
        let object: [String: Any] = [
            "type": "Application",
            "pid": 1,
            "children": [
                ["type": "GenericElement", "AXLabel": "100% battery power", "AXValue": battery, "children": []],
                ["type": "TextField", "AXUniqueId": "name", "AXValue": field, "children": []],
                ["type": "TextArea", "AXUniqueId": "notes", "AXValue": textView, "children": [
                    ["type": "Slider", "AXValue": "0%", "children": []],
                ]],
            ],
        ]
        return try SimulatorAccessibilityClient.parseTree(JSONSerialization.data(withJSONObject: [object]))
    }
}
