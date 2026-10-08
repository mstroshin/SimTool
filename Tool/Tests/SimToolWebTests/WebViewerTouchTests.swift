import JavaScriptCore
@testable import SimToolWeb
import XCTest

final class WebViewerTouchTests: XCTestCase {
    func testTheWholePageScriptParses() throws {
        let html = WebViewer.html()
        let open = try XCTUnwrap(html.range(of: "<script>"))
        let close = try XCTUnwrap(html.range(of: "</script>", range: open.upperBound..<html.endIndex))
        let script = String(html[open.upperBound..<close.lowerBound])

        let context = try XCTUnwrap(JSGlobalContextCreate(nil))
        defer { JSGlobalContextRelease(context) }
        let source = JSStringCreateWithUTF8CString(script)
        defer { JSStringRelease(source) }
        var exception: JSValueRef?
        let valid = JSCheckScriptSyntax(context, source, nil, 1, &exception)
        let message = exception.flatMap { JSValueToStringCopy(context, $0, nil) }.map { text -> String in
            defer { JSStringRelease(text) }
            return JSStringCopyCFString(nil, text) as String
        }
        XCTAssertTrue(valid, message ?? "syntax error")
    }

    func testCanvasStreamsTheFingerInsteadOfPostingTapsAndSwipes() {
        let html = WebViewer.html()
        XCTAssertTrue(html.contains("/api/v1/input/stream"), "the canvas must stream over the live-touch socket")
        XCTAssertTrue(html.contains("id=\"touchOverlay\""), "missing touch indicator layer")
        XCTAssertTrue(html.contains("\"wheel\""), "wheel/trackpad scrolling must drive a finger")
        XCTAssertTrue(html.contains("lostpointercapture"), "a lost capture must lift the finger")
        XCTAssertTrue(html.contains("visibilitychange"), "a hidden tab must lift the finger")
        XCTAssertFalse(html.contains("TAP_MOVE_THRESHOLD"), "the tap/swipe classifier must be gone")
        XCTAssertFalse(html.contains("function sendSwipe"), "the canvas no longer posts swipes")
    }

    // MARK: - createTouchStream

    private func makeStream(file: StaticString = #filePath, line: UInt = #line) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("JS exception: \(exception?.toString() ?? "?")", file: file, line: line)
        }
        context.evaluateScript(WebViewer.touchScript)
        context.evaluateScript("""
        var clock = 0, frames = [], timers = [], sockets = [];
        function FakeSocket(url) { this.url = url; this.sent = []; sockets.push(this); }
        FakeSocket.prototype.send = function (text) { this.sent.push(JSON.parse(text)); };
        FakeSocket.prototype.close = function () { this.onclose && this.onclose(); };
        var stream = createTouchStream({
          url: "ws://test/api/v1/input/stream",
          makeSocket: function (url) { return new FakeSocket(url); },
          now: function () { return clock; },
          nextFrame: function (fn) { frames.push(fn); },
          later: function (fn, ms) { timers.push(fn); }
        });
        function runFrames() { var pending = frames; frames = []; pending.forEach(function (fn) { fn(); }); }
        function socket() { return sockets[sockets.length - 1]; }
        function sentKinds(s) { return (s || socket()).sent.map(function (m) { return m.t; }).join(","); }
        """)
        return context
    }

    private func value(_ context: JSContext, _ expression: String) -> String {
        context.evaluateScript(expression)?.toString() ?? ""
    }

    func testMovesCoalesceToOnePerFrameAndDownAndUpGoOutAtOnce() throws {
        let context = try makeStream()
        context.evaluateScript("""
        socket().onopen();
        stream.down({ x: 0.5, y: 0.8 });
        stream.move({ x: 0.5, y: 0.7 });
        stream.move({ x: 0.5, y: 0.6 });
        """)
        XCTAssertEqual(value(context, "sentKinds()"), "down")
        context.evaluateScript("runFrames()")
        XCTAssertEqual(value(context, "sentKinds()"), "down,move")
        XCTAssertEqual(value(context, "socket().sent[1].y"), "0.6", "the latest position wins")
        context.evaluateScript("""
        stream.move({ x: 0.5, y: 0.5 });
        stream.up({ x: 0.5, y: 0.45 });
        """)
        // A move still waiting for its frame goes out before the up.
        XCTAssertEqual(value(context, "sentKinds()"), "down,move,move,up")
        context.evaluateScript("runFrames()")
        XCTAssertEqual(value(context, "sentKinds()"), "down,move,move,up", "the frame finds nothing left to send")
    }

    func testSecondFingerAndRoundingTravelInTheMessage() throws {
        let context = try makeStream()
        context.evaluateScript("""
        socket().onopen();
        stream.down({ x: 0.123456789, y: 1.4 }, { x: -0.2, y: 0.5 });
        """)
        XCTAssertEqual(value(context, "JSON.stringify(socket().sent[0])"), #"{"t":"down","x":0.12346,"y":1,"x2":0,"y2":0.5}"#)
    }

    func testWhileReconnectingOnlyTheNewestRecentMessagesWait() throws {
        let context = try makeStream()
        context.evaluateScript("""
        socket().onopen();
        socket().onclose();             // connection lost
        stream.down({ x: 0.1, y: 0.1 }); // too old by the time the socket is back
        clock = 2000;
        for (var i = 0; i < 40; i++) { stream.down({ x: 0.2, y: i / 100 }); }
        timers.shift()();               // reconnect
        socket().onopen();
        """)
        XCTAssertEqual(value(context, "sockets.length"), "2")
        XCTAssertEqual(value(context, "socket().sent.length"), "32")
        XCTAssertEqual(value(context, "socket().sent[31].y"), "0.39", "the newest messages are the ones kept")
        XCTAssertEqual(value(context, "socket().sent.some(function (m) { return m.x === 0.1; })"), "false")
    }

    func testAClosedSocketReconnectsWithBackoff() throws {
        let context = try makeStream()
        context.evaluateScript("""
        socket().onclose();
        timers.shift()();
        socket().onclose();
        timers.shift()();
        """)
        XCTAssertEqual(value(context, "sockets.length"), "3")
        XCTAssertEqual(value(context, "stream.connected"), "false")
        context.evaluateScript("socket().onopen()")
        XCTAssertEqual(value(context, "stream.connected"), "true")
    }
}
