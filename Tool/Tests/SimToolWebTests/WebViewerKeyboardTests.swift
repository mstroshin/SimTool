import JavaScriptCore
@testable import SimToolWeb
import XCTest

final class WebViewerKeyboardTests: XCTestCase {
    func testToolbarHasTheSoftwareKeyboardButtonAndTheKeyboardToggle() throws {
        let html = WebViewer.html()
        XCTAssertTrue(html.contains(">⌨️<"), "missing the software keyboard button")
        XCTAssertTrue(html.contains("action: \"software-keyboard\""), "the button must toggle the software keyboard")
        XCTAssertTrue(html.contains(#"<button id="keyboardToggle" class="inspect-toggle" type="button" aria-pressed="false""#), "the keyboard toggle must look and behave like Inspect")
        XCTAssertTrue(html.contains("keyboardToggle.setAttribute(\"aria-pressed\", String(on))"))
        XCTAssertTrue(html.contains("action: \"hardware-keyboard\", enabled: on"), "the toggle connects the hardware keyboard as Simulator.app does")
        // Keyboard sits right before Inspect.
        let keyboard = try XCTUnwrap(html.range(of: "id=\"keyboardToggle\""))
        let inspect = try XCTUnwrap(html.range(of: "id=\"inspectToggle\""))
        XCTAssertFalse(html[keyboard.upperBound..<inspect.lowerBound].contains("<button id="))
    }

    func testTheScreenShowsWhereTheKeysGo() {
        let html = WebViewer.html()
        XCTAssertTrue(html.contains(".surface.kbd-capture {"), "missing the ring around the screen")
        XCTAssertTrue(html.contains(".surface.kbd-capture.kbd-paused {"), "missing the paused ring")
        XCTAssertTrue(html.contains("id=\"kbdBadge\""), "missing the status bar badge")
    }

    func testThePageKeepsItsOwnKeysAndTheModeChord() throws {
        let html = WebViewer.html()
        let handler = try XCTUnwrap(html.range(of: "window.addEventListener(\"keydown\""))
        let body = String(html[handler.upperBound...].prefix(900))
        // ⇧⌘K first, before any field or menu can take it: it is how the mode is left.
        let chord = try XCTUnwrap(body.range(of: "isKeyboardModeChord(event)"))
        let editable = try XCTUnwrap(body.range(of: "isEditableTarget(event.target)"))
        XCTAssertLessThan(chord.lowerBound, editable.lowerBound)
        XCTAssertTrue(body.contains("if (isPasteChord(event)) return;"), "⌘V must reach the paste event")
        XCTAssertTrue(body.contains("event.code === \"Escape\" && popupOpen()"), "Esc closes an open menu")
        XCTAssertFalse(body.contains("setKeyboardMode(false)"), "Esc must not leave the mode — iOS uses it")
        XCTAssertTrue(html.contains("}, true);"), "the handlers run in the capture phase")
    }

    // MARK: - createKeyboardBridge

    private func makeBridge(isMac: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("JS exception: \(exception?.toString() ?? "?")", file: file, line: line)
        }
        context.evaluateScript(WebViewer.keyboardScript)
        context.evaluateScript("""
        var sent = [];
        var bridge = createKeyboardBridge({ send: function (m) { sent.push(m); }, isMac: \(isMac) });
        function key(code, extra) {
          var event = { code: code, repeat: false, shiftKey: false, ctrlKey: false, altKey: false, metaKey: false };
          for (var name in (extra || {})) event[name] = extra[name];
          return event;
        }
        function log() { return sent.map(function (m) { return (m.t === "keydown" ? "+" : "-") + m.code; }).join(" "); }
        """)
        return context
    }

    private func value(_ context: JSContext, _ expression: String) -> String {
        context.evaluateScript(expression)?.toString() ?? ""
    }

    func testOffTheBridgeLeavesEveryKeyToThePage() throws {
        let context = try makeBridge()
        XCTAssertEqual(value(context, "bridge.keydown(key('KeyA'))"), "false")
        XCTAssertEqual(value(context, "bridge.keyup(key('KeyA'))"), "false")
        XCTAssertEqual(value(context, "log()"), "")
    }

    func testKeysGoDownAndUpAndTheBrowsersRepeatsAreDropped() throws {
        let context = try makeBridge()
        context.evaluateScript("""
        bridge.setEnabled(true);
        bridge.keydown(key('ShiftLeft', { shiftKey: true }));
        bridge.keydown(key('KeyH', { shiftKey: true }));
        bridge.keydown(key('KeyH', { shiftKey: true, repeat: true }));
        bridge.keyup(key('KeyH', { shiftKey: true }));
        bridge.keyup(key('ShiftLeft'));
        """)
        XCTAssertEqual(value(context, "log()"), "+ShiftLeft +KeyH -KeyH -ShiftLeft")
        XCTAssertEqual(value(context, "bridge.keydown(key('ArrowLeft', { repeat: true }))"), "true", "a repeat is still kept from the page")
    }

    func testTurningTheModeOffOrLosingTheKeyboardReleasesWhatIsHeld() throws {
        let context = try makeBridge()
        context.evaluateScript("""
        bridge.setEnabled(true);
        bridge.keydown(key('AltLeft', { altKey: true }));
        bridge.keydown(key('ArrowRight', { altKey: true }));
        bridge.releaseAll();
        """)
        XCTAssertEqual(value(context, "log()"), "+AltLeft +ArrowRight -ArrowRight -AltLeft")
        context.evaluateScript("""
        sent = [];
        bridge.keydown(key('KeyA'));
        bridge.setEnabled(false);
        """)
        XCTAssertEqual(value(context, "log()"), "+KeyA -KeyA")
        XCTAssertEqual(value(context, "bridge.keyup(key('KeyA'))"), "false", "the late keyup belongs to the page again")
    }

    func testAModifierHeldBeforeThePageHadTheKeyboardCatchesUp() throws {
        let context = try makeBridge()
        context.evaluateScript("""
        bridge.setEnabled(true);
        bridge.keydown(key('KeyA', { shiftKey: true }));
        bridge.keyup(key('KeyA', { shiftKey: true }));
        bridge.keydown(key('KeyB'));
        """)
        XCTAssertEqual(value(context, "log()"), "+ShiftLeft +KeyA -KeyA -ShiftLeft +KeyB")
    }

    func testUnderCommandAMacKeyIsAPressBecauseItsKeyupNeverComes() throws {
        let context = try makeBridge()
        context.evaluateScript("""
        bridge.setEnabled(true);
        bridge.keydown(key('MetaLeft', { metaKey: true }));
        bridge.keydown(key('KeyA', { metaKey: true }));
        bridge.keyup(key('MetaLeft'));
        """)
        XCTAssertEqual(value(context, "log()"), "+MetaLeft +KeyA -KeyA -MetaLeft")
    }

    func testOtherSystemsKeepTheKeyHeldUnderControl() throws {
        let context = try makeBridge(isMac: false)
        context.evaluateScript("""
        bridge.setEnabled(true);
        bridge.keydown(key('KeyA', { metaKey: true }));
        """)
        XCTAssertEqual(value(context, "log()"), "+MetaLeft +KeyA")
    }

    func testCapsLockIsAPressPerEventOnAMac() throws {
        let context = try makeBridge()
        context.evaluateScript("""
        bridge.setEnabled(true);
        bridge.keydown(key('CapsLock'));   // Caps Lock on
        bridge.keyup(key('CapsLock'));     // Caps Lock off, a press later
        """)
        XCTAssertEqual(value(context, "log()"), "+CapsLock -CapsLock +CapsLock -CapsLock")

        let other = try makeBridge(isMac: false)
        other.evaluateScript("""
        bridge.setEnabled(true);
        bridge.keydown(key('CapsLock'));
        bridge.keyup(key('CapsLock'));
        """)
        XCTAssertEqual(value(other, "log()"), "+CapsLock -CapsLock")
    }

    func testKeysWithoutAPhysicalCodeStayWithThePage() throws {
        let context = try makeBridge()
        context.evaluateScript("bridge.setEnabled(true)")
        XCTAssertEqual(value(context, "bridge.keydown(key(''))"), "false")
        XCTAssertEqual(value(context, "bridge.keydown(key('Unidentified'))"), "false")
        XCTAssertEqual(value(context, "log()"), "")
    }

    func testKeysTravelOnTheLiveTouchSocket() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(WebViewer.touchScript)
        context.evaluateScript("""
        var sockets = [], frames = [];
        function FakeSocket(url) { this.sent = []; sockets.push(this); }
        FakeSocket.prototype.send = function (text) { this.sent.push(JSON.parse(text)); };
        var stream = createTouchStream({
          url: "ws://test", makeSocket: function (url) { return new FakeSocket(url); },
          now: function () { return 0; }, nextFrame: function (fn) { frames.push(fn); }, later: function () {}
        });
        sockets[0].onopen();
        stream.down({ x: 0.5, y: 0.5 });
        stream.move({ x: 0.5, y: 0.4 });
        stream.key({ t: "keydown", code: "KeyA" });
        """)
        // A move still waiting for its frame goes out before the key.
        XCTAssertEqual(value(context, "sockets[0].sent.map(function (m) { return m.t; }).join(',')"), "down,move,keydown")
        XCTAssertEqual(value(context, "JSON.stringify(sockets[0].sent[2])"), #"{"t":"keydown","code":"KeyA"}"#)
    }
}
