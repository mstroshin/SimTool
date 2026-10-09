@testable import SimToolCore
import XCTest

final class SimulatorKeyboardTests: XCTestCase {
    func testWebCodesNameThePhysicalKeysOnTheHIDKeyboardPage() {
        let expected: [String: UInt32] = [
            "KeyA": 0x04, "KeyZ": 0x1D, "Digit1": 0x1E, "Digit0": 0x27,
            "Enter": 0x28, "Escape": 0x29, "Backspace": 0x2A, "Tab": 0x2B, "Space": 0x2C,
            "Minus": 0x2D, "Backslash": 0x31, "Backquote": 0x35, "Slash": 0x38, "CapsLock": 0x39,
            "F1": 0x3A, "F12": 0x45, "F13": 0x68, "Delete": 0x4C,
            "ArrowRight": 0x4F, "ArrowLeft": 0x50, "ArrowDown": 0x51, "ArrowUp": 0x52,
            "Numpad1": 0x59, "Numpad0": 0x62, "NumpadEnter": 0x58, "IntlBackslash": 0x64,
            "ControlLeft": 0xE0, "ShiftLeft": 0xE1, "AltLeft": 0xE2, "MetaLeft": 0xE3,
            "ShiftRight": 0xE5, "MetaRight": 0xE7, "OSLeft": 0xE3,
        ]
        for (code, usage) in expected {
            XCTAssertEqual(KeyboardKey(webCode: code)?.usage, usage, code)
        }
        XCTAssertEqual(KeyboardKey.v, KeyboardKey(webCode: "KeyV"))
        XCTAssertEqual(KeyboardKey.leftCommand, KeyboardKey(webCode: "MetaLeft"))
    }

    func testCodesWithoutAKeyboardUsageAreNotKeys() {
        for code in ["", "Unidentified", "Fn", "AudioVolumeUp", "keya", "KeyAA"] {
            XCTAssertNil(KeyboardKey(webCode: code), code)
        }
        XCTAssertNil(KeyboardKey(usage: 0))
        XCTAssertNil(KeyboardKey(usage: 256))
        XCTAssertEqual(KeyboardKey(usage: 4), KeyboardKey(webCode: "KeyA"))
    }

    func testKeysReachTheHelperAsUsagesDownOrUp() throws {
        let a = try XCTUnwrap(KeyboardKey(webCode: "KeyA"))
        XCTAssertEqual(LiveKeyEvent(key: a, isDown: true).helperLine, "key 4 1")
        XCTAssertEqual(LiveKeyEvent(key: a, isDown: false).helperLine, "key 4 0")
    }

    func testShortcutsSoftwareKeyboardAndHardwareKeyboardCommands() throws {
        let shift = try XCTUnwrap(KeyboardKey(webCode: "ShiftLeft"))
        XCTAssertEqual(SimulatorDirectInputCommand.press(.v, modifiers: [.leftCommand]).line, "press 25 227")
        XCTAssertEqual(SimulatorDirectInputCommand.press(.v, modifiers: []).line, "press 25")
        XCTAssertEqual(
            SimulatorDirectInputCommand.press(.v, modifiers: [.leftCommand, shift, shift, shift]).line,
            "press 25 227 225 225",
            "the helper holds at most three modifiers"
        )
        XCTAssertEqual(SimulatorDirectInputCommand.ejectKey.line, "button 12 184")
        XCTAssertEqual(SimulatorDirectInputCommand.hardwareKeyboard(connected: true).line, "hwkeyboard 1")
        XCTAssertEqual(SimulatorDirectInputCommand.hardwareKeyboard(connected: false).line, "hwkeyboard 0")
    }

    // MARK: - software keyboard on screen

    private func tree(screenHeight: Double, keyboardTop: Double?) -> AccessibilityTreePayload {
        var children: [AccessibilityNode] = [
            AccessibilityNode(id: "0.0", type: "TextField", frame: AccessibilityFrame(x: 20, y: 120, width: 380, height: 44), children: []),
        ]
        if let keyboardTop {
            let key = AccessibilityNode(id: "0.1.0", label: "q", type: "Button", frame: AccessibilityFrame(x: 4, y: keyboardTop + 7, width: 41, height: 56), children: [])
            children.append(AccessibilityNode(
                id: "0.1",
                accessibilityIdentifier: "UIKeyboardLayoutStar Preview",
                type: "Group",
                frame: AccessibilityFrame(x: 0, y: keyboardTop, width: 420, height: 245),
                children: [key]
            ))
        }
        let app = AccessibilityNode(id: "0", label: "App", type: "Application", frame: AccessibilityFrame(x: 0, y: 0, width: 420, height: screenHeight), children: children)
        return AccessibilityTreePayload(roots: [app])
    }

    func testTheKeyboardIsOnScreenWhileItsLayoutIsAboveTheBottomEdge() {
        XCTAssertTrue(SoftwareKeyboardVisibility.isOnScreen(in: tree(screenHeight: 912, keyboardTop: 609)))
    }

    func testAHiddenKeyboardIsParkedBelowTheScreen() {
        // iOS 27 parks it past the edge, iOS 26.4 exactly at it.
        XCTAssertFalse(SoftwareKeyboardVisibility.isOnScreen(in: tree(screenHeight: 912, keyboardTop: 929)))
        XCTAssertFalse(SoftwareKeyboardVisibility.isOnScreen(in: tree(screenHeight: 874, keyboardTop: 874)))
    }

    func testNoKeyboardLayoutMeansNoKeyboard() {
        XCTAssertFalse(SoftwareKeyboardVisibility.isOnScreen(in: tree(screenHeight: 912, keyboardTop: nil)))
        XCTAssertFalse(SoftwareKeyboardVisibility.isOnScreen(in: AccessibilityTreePayload(roots: [])))
    }

    func testHelperSourceSpeaksTheKeyboardCommands() {
        let source = SimulatorDirectInputHelperSource.source
        for command in ["\"key\"", "\"press\"", "\"button\"", "\"hwkeyboard\""] {
            XCTAssertTrue(source.contains("!strcmp(name, \(command))"), "the helper must parse \(command)")
        }
        // From Xcode 27 the guest drops Indigo keys; they go to dtuhidd instead.
        XCTAssertTrue(source.contains("com.apple.coredevice.feature.remote.hid.digitizer"))
        XCTAssertTrue(source.contains("\"1155.4\""))
        XCTAssertTrue(source.contains("IndigoKeyboardButtonEvent"))
        XCTAssertTrue(source.contains("IndigoHIDMessageForKeyboardArbitrary"), "older toolchains still type over Indigo")
        XCTAssertTrue(source.contains("setHardwareKeyboardEnabled:keyboardType:error:"))
        // A streamed key never gets an answer, malformed or not.
        XCTAssertTrue(source.contains("strncmp(line, \"key \", 4)"))
    }
}
