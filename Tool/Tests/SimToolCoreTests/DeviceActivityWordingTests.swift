import SimToolCore
import SimToolNetworkLogger
import XCTest

// The feed's words for an input read the same whether the server performed it
// or the CLI did and reported it.
final class DeviceActivityWordingTests: XCTestCase {
    private func title(_ input: SimulatorInputPayload, stroke: TouchStroke? = nil) -> String {
        DeviceActivityWording.describe(input, action: input.action ?? "", stroke: stroke).title
    }

    func testATapNamesWhatItAimedAtAndOtherwiseWhereItLanded() {
        let stroke = TouchStroke.tap(at: TouchPoint(x: 201.4, y: 339.6))
        XCTAssertEqual(title(SimulatorInputPayload(action: "tap", label: "General"), stroke: stroke), "Tap “General”")
        XCTAssertEqual(title(SimulatorInputPayload(action: "tap", x: 201.4, y: 339.6, target: "General"), stroke: stroke), "Tap “General”",
                       "a test step taps by coordinates but names its element")
        XCTAssertEqual(title(SimulatorInputPayload(action: "tap", x: 201.4, y: 339.6), stroke: stroke), "Tap 201, 340")
        let described = DeviceActivityWording.describe(SimulatorInputPayload(action: "tap", id: "save"), action: "tap", stroke: stroke)
        XCTAssertEqual(described.kind, "tap")
        XCTAssertEqual(described.detail, "at 201, 340")
    }

    func testDirectionGesturesSayWhichWayAndHowFar() {
        let stroke = TouchStroke.scroll(from: TouchPoint(x: 201, y: 655), to: TouchPoint(x: 201, y: 345))
        let scroll = DeviceActivityWording.describe(SimulatorInputPayload(action: "scroll", direction: "up", distance: 300), action: "scroll", stroke: stroke)
        XCTAssertEqual(scroll.title, "Scroll up 300 pt")
        XCTAssertEqual(scroll.detail, "201, 655 → 201, 345")
        XCTAssertEqual(title(SimulatorInputPayload(action: "fling", direction: "down", target: "Feed")), "Fling down on “Feed”")
        XCTAssertEqual(title(SimulatorInputPayload(action: "swipe"), stroke: stroke), "Swipe 201, 655 → 201, 345")
    }

    func testAFoldSaysWhereTo() {
        XCTAssertEqual(DeviceActivityWording.describe(SimulatorInputPayload(action: "pose", name: "book"), action: "pose").title, "Fold to book")
        XCTAssertEqual(DeviceActivityWording.describe(SimulatorInputPayload(action: "pose", angle: 92.5), action: "pose").title, "Fold to 92.5°")
        XCTAssertEqual(DeviceActivityWording.describe(SimulatorInputPayload(action: "pose"), action: "pose").kind, "pose")
    }

    func testTextIsQuotedShortAndOnOneLine() {
        XCTAssertEqual(title(SimulatorInputPayload(action: "type", text: "hello")), "Type “hello”")
        let long = String(repeating: "a", count: 60)
        let paste = DeviceActivityWording.describe(SimulatorInputPayload(action: "paste", text: long + "\nb"), action: "paste")
        XCTAssertEqual(paste.title, "Paste “" + String(repeating: "a", count: 39) + "…”")
        XCTAssertEqual(paste.detail, "62 characters")
    }

    func testDeviceActionsReadAsWhatAPersonWouldSay() {
        XCTAssertEqual(title(SimulatorInputPayload(action: "button", name: "home")), "Press Home")
        XCTAssertEqual(title(SimulatorInputPayload(action: "button", name: "app-switcher")), "Open the app switcher")
        XCTAssertEqual(title(SimulatorInputPayload(action: "launch", name: "com.example.app")), "Launch com.example.app")
        XCTAssertEqual(title(SimulatorInputPayload(action: "software-keyboard", visible: false)), "Hide the software keyboard")
        XCTAssertEqual(title(SimulatorInputPayload(action: "software-keyboard")), "Toggle the software keyboard")
        XCTAssertEqual(title(SimulatorInputPayload(action: "hardware-keyboard", enabled: true)), "Connect the hardware keyboard")
    }

    func testAGestureKnowsHowLongTheFingerIsDown() {
        let gesture = DeviceActivityGesture(stroke: .drag(from: TouchPoint(x: 0, y: 0), to: TouchPoint(x: 0, y: 300)), screen: nil)
        XCTAssertEqual(gesture.duration, 0.8 + 1 + 0.5, accuracy: 0.001, "press, 300 pt at 300 pt/s, hold")
        XCTAssertEqual(DeviceActivityGesture(stroke: .tap(at: TouchPoint(x: 5, y: 5)), screen: nil).duration, TouchStroke.tapPress, accuracy: 0.001)
    }
}

final class DeviceActivityCodingTests: XCTestCase {
    func testTimesKeepTheirMilliseconds() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000.123)
        let entry = DeviceActivity(id: 1, revision: 2, actor: .agent, kind: "tap", title: "Tap 1, 2", at: at, endedAt: at.addingTimeInterval(0.25), status: .done)
        let json = String(decoding: try JSON.data(entry, pretty: false), as: UTF8.self)
        XCTAssertTrue(json.contains(#""at":"2026-09-21T14:13:20.123Z""#), json)
        let decoded = try JSON.decoder.decode(DeviceActivity.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.at.timeIntervalSince1970, at.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.endedAt!.timeIntervalSince(decoded.at), 0.25, accuracy: 0.001)
    }
}

final class TestSessionEntryTimeTests: XCTestCase {
    // A step's window is cut at its edges; whole seconds would let two steps
    // a few hundred milliseconds apart share them.
    func testStepTimesKeepTheirMillisecondsAndOldSessionsStillRead() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000.743)
        let entry = TestSessionEntry(kind: .step, at: at, endedAt: at.addingTimeInterval(0.067), text: "✓ 2/9 Tap label \"General\"")
        let json = String(decoding: try JSON.data(entry, pretty: false), as: UTF8.self)
        XCTAssertTrue(json.contains(#""at":"2026-09-21T14:13:20.743Z""#), json)
        let decoded = try JSON.decoder.decode(TestSessionEntry.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.endedAt!.timeIntervalSince(decoded.at), 0.067, accuracy: 0.001)
        let old = try JSON.decoder.decode(TestSessionEntry.self, from: Data(#"{"kind":"step","at":"2026-06-12T16:00:00Z","text":"Tapped"}"#.utf8))
        XCTAssertEqual(old.at.timeIntervalSince1970, 1_781_280_000)
    }
}

// A change to the device's settings reads as what it does.
final class DeviceControlWordingTests: XCTestCase {
    private func title(_ control: DeviceControlPayload) -> String { DeviceActivityWording.describe(control: control).title }

    func testEachSettingSaysWhatChanged() {
        XCTAssertEqual(title(DeviceControlPayload(action: "appearance", value: "dark")), "Dark appearance")
        XCTAssertEqual(title(DeviceControlPayload(action: "content-size", value: "ax2")), "Text size AX2")
        XCTAssertEqual(title(DeviceControlPayload(action: "content-size", value: "increment")), "Larger text")
        XCTAssertEqual(title(DeviceControlPayload(action: "increase-contrast", enabled: false)), "Increase Contrast off")
        XCTAssertEqual(title(DeviceControlPayload(action: "debug", option: "blended", enabled: true)), "Color Blended Layers on")
        XCTAssertEqual(title(DeviceControlPayload(action: "memory-warning")), "Simulate a memory warning")
        XCTAssertEqual(title(DeviceControlPayload(action: "biometrics", value: "nomatch")), "Non-matching face or finger")
        XCTAssertEqual(title(DeviceControlPayload(action: "status-bar", value: "clear")), "Clear the status bar")
        XCTAssertEqual(title(DeviceControlPayload(action: "status-bar", statusBar: SimulatorStatusBar(time: "9:41", batteryLevel: 100))), "Status bar 9:41 · 100%")
        XCTAssertEqual(title(DeviceControlPayload(action: "location", location: SimulatorLocation(waypoints: [SimulatorCoordinate(latitude: 1, longitude: 2)]))), "Location 1,2")
        XCTAssertEqual(DeviceActivityWording.describe(control: DeviceControlPayload(action: "debug", option: "slow", enabled: true)).kind, "debug")
    }

    func testAccessibilityPermissionsKeychainAndATurnSayWhatChanged() {
        XCTAssertEqual(title(DeviceControlPayload(action: "accessibility", option: "voiceover", enabled: true)), "VoiceOver on")
        XCTAssertEqual(title(DeviceControlPayload(action: "accessibility", option: "color-filter", value: "red-green")), "Color Filters protanopia")
        let grant = DeviceActivityWording.describe(control: DeviceControlPayload(action: "permission", option: "att", value: "revoke", bundleId: "com.example.app"))
        XCTAssertEqual(grant.title, "Deny Tracking (ATT)")
        XCTAssertEqual(grant.detail, "for com.example.app")
        XCTAssertEqual(title(DeviceControlPayload(action: "keychain", value: "add-root-cert")), "Trust a root certificate")
        XCTAssertEqual(DeviceActivityWording.describe(SimulatorInputPayload(action: "rotate", name: "left"), action: "rotate").title, "Rotate left")
        XCTAssertEqual(DeviceActivityWording.describe(SimulatorInputPayload(action: "rotate", name: "landscape-right"), action: "rotate").title, "Rotate to landscape right")
    }

    func testAPushNamesItsAppAndQuotesItsAlert() {
        let payload = NetworkLoggerJSONValue.object(["aps": .object(["alert": .object(["title": .string("Order"), "body": .string("Shipped")])])])
        let words = DeviceActivityWording.describe(control: DeviceControlPayload(action: "push", bundleId: "com.example.shop", payload: payload))
        XCTAssertEqual(words.title, "Push to com.example.shop")
        XCTAssertEqual(words.detail, "“Order — Shipped”")
    }

    // The device's answer is worth the detail line only where it adds to the title.
    func testOnlyAnAnswerThatSaysMoreBecomesTheDetail() {
        XCTAssertTrue(DeviceActivityWording.reportsResult(of: DeviceControlPayload(action: "content-size", value: "increment")))
        XCTAssertTrue(DeviceActivityWording.reportsResult(of: DeviceControlPayload(action: "biometrics", value: "match")))
        XCTAssertFalse(DeviceActivityWording.reportsResult(of: DeviceControlPayload(action: "appearance", value: "dark")))
        XCTAssertFalse(DeviceActivityWording.reportsResult(of: DeviceControlPayload(action: "status-bar", value: "clear")))
    }
}
