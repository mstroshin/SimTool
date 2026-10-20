@testable import SimToolWeb
import XCTest

// Contracts of the assembled page: what it talks to, how it is put together,
// and the promises the redesign made — the structure, not the styling.
final class WebViewerPageTests: XCTestCase {
    private let page = WebViewer.html()

    func testTheInspectorIsATablistWithAPanelPerTab() throws {
        for tab in ["network", "logs", "state", "ax", "tests"] {
            let tabButton = try XCTUnwrap(page.range(of: #"role="tab" class="tab" type="button" id="tab-\#(tab)""#), "missing tab \(tab)")
            XCTAssertTrue(page[tabButton.upperBound...].prefix(200).contains(#"aria-controls="panel-\#(tab)""#), "tab \(tab) must name its panel")
            XCTAssertTrue(page.contains(#"role="tabpanel" id="panel-\#(tab)" aria-labelledby="tab-\#(tab)""#), "missing panel \(tab)")
        }
        XCTAssertTrue(page.contains(#"role="tablist""#))
    }

    func testTheScreenStreamsH264OnlyAndReconnects() {
        XCTAssertTrue(page.contains(#"fetch("/stream.avcc""#), "the screen must stream AVCC")
        XCTAssertTrue(page.contains("new VideoDecoder("), "the screen must decode with WebCodecs")
        XCTAssertTrue(page.contains("optimizeForLatency: true"), "the decoder must be tuned for latency")
        XCTAssertFalse(page.contains("mjpeg"), "there is no JPEG fallback")
        XCTAssertTrue(page.contains("function scheduleReconnect"), "a lost stream must reconnect by itself")
        XCTAssertTrue(page.contains("Math.min(5000, 500 * Math.pow(2"), "reconnects back off up to 5 s")
        XCTAssertTrue(page.contains(#"screenState.connection !== "live""#), "touches wait for a live screen")
    }

    // A restarted server numbers log and state entries from zero again: whichever
    // of /config and the event stream's snapshot names the new instance first
    // resets the cursors.
    func testANewServerInstanceResetsTheCursors() throws {
        let forget = try XCTUnwrap(page.range(of: "function forgetServer()"))
        let reset = page[forget.upperBound...].prefix(300)
        XCTAssertTrue(reset.contains("resetLogs();"))
        XCTAssertTrue(reset.contains("resetState();"))
        let bootstrap = try XCTUnwrap(page.range(of: "async function bootstrap()"))
        XCTAssertTrue(page[bootstrap.upperBound...].prefix(300).contains("instance !== serverInstance) forgetServer();"))
        let snapshot = try XCTUnwrap(page.range(of: "function applySnapshot(snapshot)"))
        XCTAssertTrue(page[snapshot.upperBound...].prefix(300).contains("snapshot.instance !== serverInstance) forgetServer();"))
    }

    // One stream per page brings what the tabs used to poll; the polls only
    // stand in while it is down, so an idle page asks for nothing.
    func testInspectorDataIsPushedAndPollingIsTheFallback() throws {
        XCTAssertTrue(page.contains(#"new EventSource("/api/v1/events" + resume)"#))
        XCTAssertEqual(page.components(separatedBy: "new EventSource(").count - 1, 1, "one stream per page, not per tab")
        for topic in ["snapshot", "network", "logs", "state", "tests", "launches"] {
            XCTAssertTrue(page.contains(#"on("\#(topic)""#), "missing topic \(topic)")
        }
        for task in ["network", "logs", "state", "tests"] {
            let add = try XCTUnwrap(page.range(of: #"poller.add("\#(task)""#), "missing poll \(task)")
            let line = page[add.lowerBound...].prefix { $0 != "\n" }
            XCTAssertTrue(line.contains("polling"), "\(task) polls only while the stream is down")
        }
        let ax = try XCTUnwrap(page.range(of: #"poller.add("ax""#))
        XCTAssertTrue(page[ax.lowerBound...].prefix { $0 != "\n" }.contains("axTreeStale()"), "the tree is read when the screen changed")
    }

    func testThePageTalksToTheServersRoutes() {
        for route in ["/api/v1/input/stream", "/api/v1/input", "/api/v1/screenshot", "/api/v1/photos", "/api/v1/input/paste-image",
                      "/api/v1/network/events", "/api/v1/mocks", "/api/v1/launches", "/api/v1/logs/capture", "/api/v1/state/events",
                      "/api/v1/ax/tree?raw=1", "/api/v1/tests/definitions", "/api/v1/tests/run", "/api/v1/tests/run/stop", "/config",
                      "/api/v1/events"] {
            XCTAssertTrue(page.contains(route), "missing \(route)")
        }
        for action in [#"action: "button", name: "home""#, #"action: "shake""#, #"action: "terminate""#, #"action: "launch""#,
                       #"action: "software-keyboard""#, #"action: "hardware-keyboard", enabled: on"#, #"action: "paste", text"#] {
            XCTAssertTrue(page.contains(action), "missing \(action)")
        }
    }

    // The toolbar is drawn with the page's own icons, never emoji, which every
    // system renders differently and screen readers read out as pictures.
    func testTheChromeHasNoEmoji() throws {
        let template = try XCTUnwrap(WebViewerAssets.files["viewer.html"])
        let emoji = template.unicodeScalars.filter { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
        XCTAssertEqual(String(String.UnicodeScalarView(emoji)), "", "emoji in web/viewer.html")
        XCTAssertTrue(template.contains(#"<symbol id="i-home""#))
        XCTAssertTrue(template.contains(#"id="homeButton" aria-label="Home""#), "icon buttons need a spoken name")
    }

    // Colours live in tokens on :root, so a theme restates the tokens and nothing else.
    func testEveryColourComesFromAToken() throws {
        let css = try XCTUnwrap(WebViewerAssets.files["viewer.css"])
        let rootEnd = try XCTUnwrap(css.range(of: "}", range: try XCTUnwrap(css.range(of: ":root {")).upperBound..<css.endIndex))
        let rest = String(css[rootEnd.upperBound...])
        let literal = try NSRegularExpression(pattern: #"#[0-9a-fA-F]{3,8}\b|rgba?\("#)
        let matches = literal.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)).map { String(rest[Range($0.range, in: rest)!]) }
        XCTAssertEqual(matches, [], "colour literals outside the token block")
    }

    func testFocusIsAlwaysVisibleAndMotionCanBeReduced() throws {
        let css = try XCTUnwrap(WebViewerAssets.files["viewer.css"])
        XCTAssertTrue(css.contains(":focus-visible { outline: 2px solid var(--accent)"))
        XCTAssertTrue(css.contains("@media (prefers-reduced-motion: reduce)"))
    }

    // Deleting a run deletes its recording; deleting a launch section deletes it for every viewer.
    func testWhatCannotBeUndoneAsksFirst() throws {
        for marker in ["async function deleteSession(session) {", #"label: "Delete this launch's ""#] {
            let start = try XCTUnwrap(page.range(of: marker), "missing \(marker)")
            XCTAssertTrue(page[start.upperBound...].prefix(400).contains("confirmDestructive("), "\(marker) must confirm")
        }
    }

    func testTheMacClipboardPastesIntoTheSimulator() throws {
        XCTAssertTrue(page.contains(#"document.addEventListener("paste""#), "⌘V on the page pastes into the simulator")
        let handler = try XCTUnwrap(page.range(of: #"document.addEventListener("paste""#))
        XCTAssertTrue(page[handler.upperBound...].prefix(300).contains("if (isEditableTarget(event.target)) return;"), "the viewer's own fields keep their paste")
        XCTAssertTrue(page.contains("navigator.clipboard.readText()"), "browsers without clipboard.read() still paste text")
        XCTAssertTrue(page.contains("X-SimTool-Filename"), "uploads name the file")
        XCTAssertTrue(page.contains(#"<input id="photosFile" type="file" accept="image/*,video/*" multiple hidden>"#))
        XCTAssertTrue(page.contains("(await response.json()).error"), "failures carry the server's explanation")
    }

    // A run started from a terminal is visible here, with no Stop the server cannot honour.
    func testARunTheViewerCannotStopIsShownAsRunning() {
        XCTAssertTrue(page.contains("tests.run.stoppable === false"))
        XCTAssertTrue(page.contains("Running from a terminal"))
    }

    func testTheRecordingPlaysInTheScreensPlaceWithItsOwnTransport() {
        XCTAssertTrue(page.contains(#"<video class="replay-video" id="replayVideo" playsinline></video>"#))
        XCTAssertTrue(page.contains(#"id="backToLive""#))
        XCTAssertTrue(page.contains(#"role="slider""#), "the scrubber is a slider for keyboard and screen readers")
        XCTAssertTrue(page.contains(#"app.dataset.mode = "replay""#), "replay is a mode of the whole viewer")
        XCTAssertTrue(page.contains("/video"), "replay streams the session's video")
    }

    func testTheEmbeddedModelMarkerMatchesTheSerializer() {
        XCTAssertTrue(page.contains(#"const MODEL_ID_KEY = "$modelId";"#))
    }

    // Panes that polling re-renders keep focus and a text selection: the AX
    // detail every two seconds, Network's on every request, Tests' on every step.
    func testPolledPanesArePatchedNotRebuilt() {
        XCTAssertTrue(page.contains("function patchPane(node, key, html)"))
        for pane in ["patchPane(axView.detail", "patchPane(networkView.detail", #"patchPane(node, "test:""#, #"patchPane(node, "session:""#, "patchPane(stateBody"] {
            XCTAssertTrue(page.contains(pane), "\(pane) must go through patchPane")
        }
        XCTAssertFalse(page.contains(#"logsLevels.innerHTML = """#), "level buttons are made once")
    }

    func testBrowsingTestsNeverStartsARun() throws {
        let list = try XCTUnwrap(page.range(of: "const definitionList = createList("))
        let options = page[list.upperBound...].prefix(1400)
        let activate = try XCTUnwrap(options.range(of: "onActivate:"))
        XCTAssertFalse(options[activate.upperBound...].prefix(200).contains("runTest"), "Enter on a test focuses its Run button")
    }

    // Same-specificity rules: the narrow-width ones must come after the base rules to win.
    func testTheToolbarShedsWordsAfterItsBaseRules() throws {
        let css = WebViewer.asset("viewer.css")
        let base = try XCTUnwrap(css.range(of: ".device-id { display: inline-flex"))
        let narrow = try XCTUnwrap(css.range(of: "@container bar (max-width: 560px)"))
        XCTAssertLessThan(base.lowerBound, narrow.lowerBound)
        XCTAssertNil(css.range(of: "@container bar", range: css.startIndex..<base.lowerBound), "a container rule above the base rules loses to them")
    }
}
