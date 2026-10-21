@testable import SimToolWeb
import XCTest

// Contracts of the assembled page: what it talks to, how it is put together,
// and the promises the redesign made — the structure, not the styling.
final class WebViewerPageTests: XCTestCase {
    private let page = WebViewer.pageWithAssets

    func testTheInspectorIsATablistWithAPanelPerTab() throws {
        for tab in ["network", "logs", "state", "ax", "tests", "activity"] {
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
                      "/api/v1/events", "/api/v1/activity", "/api/v1/recording", "/api/v1/recording/stop"] {
            XCTAssertTrue(page.contains(route), "missing \(route)")
        }
        for action in [#"action: "button", name: "home""#, #"action: "shake""#, #"action: "terminate""#, #"action: "launch""#,
                       #"action: "software-keyboard""#, #"action: "hardware-keyboard", enabled: on"#, #"action: "paste", text"#] {
            XCTAssertTrue(page.contains(action), "missing \(action)")
        }
    }

    // Screenshots and videos come with the device's bezel or as the screen
    // alone; a recording runs on the server, so every viewer shows it and a
    // reload keeps it, and the viewer that stops it downloads the video.
    func testScreenshotsAndRecordingsTakeTheFrameAndARecordingShowsWhileItRuns() throws {
        XCTAssertTrue(page.contains(#"id="recordButton" aria-label="Record video" data-tip="Record video" data-key="⌘R""#))
        XCTAssertTrue(page.contains(#"id="captureMenuButton" aria-haspopup="menu""#))
        XCTAssertTrue(page.contains(#"wireMenuButton($("captureMenuButton"), captureMenuItems);"#))
        XCTAssertTrue(page.contains(#"api("/api/v1/screenshot" + (capture.bezel ? "?bezel=1" : ""))"#), "a screenshot takes the frame option")
        XCTAssertTrue(page.contains(#"body: JSON.stringify({ bezel: capture.bezel })"#), "a recording takes it when it starts")
        XCTAssertTrue(page.contains(#"bezel: stored("capture.bezel", false)"#), "the option is remembered per browser")
        let items = try XCTUnwrap(page.range(of: "function captureMenuItems()"))
        let menu = String(page[items.upperBound...].prefix(1800))
        XCTAssertTrue(menu.contains(#"label: "Screen only", radio: true"#))
        XCTAssertTrue(menu.contains(#"label: "With the device bezel", radio: true"#))
        XCTAssertTrue(page.contains(#"on("recording", applyRecordingTopic);"#), "every viewer hears the recording")
        XCTAssertTrue(page.contains("applyRecordingTopic(snapshot.recording || {});"))
        XCTAssertTrue(page.contains(#"saveFile("/api/v1/recording/" + encodeURIComponent(recording.id) + "/video", name);"#), "the video is downloaded once saved")
        XCTAssertTrue(page.contains(#"event.code === "KeyR") { event.preventDefault(); if (!event.repeat) toggleRecording(); return; }"#), "⌘R records and stops, as in Simulator.app")
        XCTAssertTrue(page.contains(".tb-rec.recording .rec-dot {"), "a running recording is marked")
    }

    // A call's detail: Request and Response, as tabs or side by side, each in
    // sections that fold; bodies as trees that stay folded as a person left
    // them; a search that marks what it found and steps through it.
    func testTheNetworkDetailShowsRequestAndResponseAndTheSearchMarksWhatItFound() throws {
        XCTAssertTrue(page.contains(#"const tabs = [["request", "Request"], ["response", "Response"]]"#))
        XCTAssertTrue(page.contains(#"data-act="split" aria-pressed=""#), "request and response side by side")
        XCTAssertTrue(page.contains(#"split: stored("network.split", false)"#))
        XCTAssertTrue(page.contains(#"bodyView: stored("network.bodyView", "tree")"#))
        XCTAssertTrue(page.contains("const parsed = parseBodyTree(text);"), "bodies are read as trees")
        XCTAssertTrue(page.contains(#"networkView.detail.addEventListener("toggle", (domEvent) => {"#), "folds survive re-renders")
        XCTAssertTrue(page.contains("fields: NETWORK_FILTER_FIELDS,"), "url:, header:, body: … scope the search")
        XCTAssertTrue(page.contains("return matchesFilters(fields.all, chips, query.term, fields, query.field);"), "the search reads headers and bodies")
        XCTAssertTrue(page.contains(#"'<span class="tag tag-hit" title="'"#), "a call found only in its body says where")
        XCTAssertTrue(page.contains(#"data-act="next-match""#), "the marks can be stepped through")
        XCTAssertTrue(page.contains("patchPane(networkView.detail, event.id + \"|\" + (network.split ? \"split\" : network.detailTab),"), "polling keeps the pane's scroll")
    }

    // A person watching can tell what was done to the device, and by whom,
    // without opening anything: marks on the screen, the driver in the
    // toolbar, the last action under the device.
    func testWhatAgentsDoShowsOnTheScreenAndWhoDrivesIsSaid() {
        XCTAssertTrue(page.contains(#"<div class="activity-layer" id="activityLayer" aria-hidden="true"></div>"#), "marks are drawn over the screen")
        XCTAssertTrue(page.contains(#"<span class="driver-status" role="status" aria-live="polite"><button class="driver" type="button" id="driverChip""#), "the driver is announced")
        XCTAssertTrue(page.contains(#"id="readLast""#), "the last action stays under the device")
        XCTAssertTrue(page.contains(#""X-SimTool-Source": "viewer""#), "the viewer's own input is told apart from an agent's")
        XCTAssertTrue(page.contains(#"on("activity", (payload) => applyActivityTopic(payload, false));"#), "activity arrives on the event stream")
        XCTAssertTrue(page.contains("applyActivityTopic(snapshot.activity || {}, true);"), "the snapshot carries the feed")
        XCTAssertTrue(page.contains(#"poller.add("activity", 500, pollActivity, polling);"#), "the feed is polled only while the stream is down")
    }

    // Input from the page while a test or an agent drives the device asks
    // first, wherever it comes from: the finger, the wheel, the keys, the toolbar, a paste.
    func testManualInputAsksBeforeItLandsInSomeoneElsesRun() throws {
        XCTAssertTrue(page.contains("if (!manualInputAllowed()) { event.preventDefault(); return; }"), "the first touch asks")
        XCTAssertTrue(page.contains("(!wheel && !manualInputAllowed())"), "a wheel scroll asks")
        XCTAssertTrue(page.contains("if (!manualInputAllowed()) { keepFromPage(event); return; }"), "a key asks")
        XCTAssertTrue(page.contains("if (!manualInputAllowed(() => deviceAction(label, payload, done))) return;"), "toolbar actions ask, then run")
        XCTAssertTrue(page.contains("if (!manualInputAllowed(() => runPaste(label, send, failureHint))) return;"), "a paste asks, then runs")
        let guardBody = try XCTUnwrap(page.range(of: "function manualInputAllowed(proceed)"))
        XCTAssertTrue(page[guardBody.upperBound...].prefix(900).contains("confirmDestructive("), "asking is a confirmation, not a toast")
    }

    // A recording under review cuts Network, Logs and State to the step the
    // playhead is in, from the run's own evidence, and each step opens what it caused.
    func testReviewingARunFollowsThePlayheadIntoTheLists() throws {
        XCTAssertTrue(page.contains(#"api("/api/v1/tests/" + encodeURIComponent(session.id) + "/evidence/""#), "the run's own evidence files")
        let transport = try XCTUnwrap(page.range(of: "if (current !== replayCurrentIndex) {"))
        XCTAssertTrue(page[transport.upperBound...].prefix(200).contains("refreshReview();"), "the window follows the playhead")
        XCTAssertTrue(page.contains("return reviewActive() ? reviewRows(\"network\", network.events)"), "Network reads the reviewed run")
        XCTAssertTrue(page.contains("return reviewActive() ? reviewRows(\"logs\", logs.entries)"), "Logs reads the reviewed run")
        XCTAssertTrue(page.contains("return reviewStateView(stateView);"), "State reads the reviewed run")
        XCTAssertTrue(page.contains(#"data-act="step-evidence""#), "a step opens what it caused")
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
        let literal = try NSRegularExpression(pattern: #"(?<!href=")#[0-9a-fA-F]{3,8}\b|rgba?\(|light-dark\("#)
        for (name, text) in [("web/viewer.css after :root", String(css[rootEnd.upperBound...])), ("web/viewer.html", try XCTUnwrap(WebViewerAssets.files["viewer.html"]))] {
            let matches = literal.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) }
            XCTAssertEqual(matches, [], "colour literals in \(name)")
        }
    }

    // Each colour token carries its drafting-film (light) and graphite (dark)
    // value; only the device's own screen is the same in both.
    func testEveryColourTokenHasALightAndADarkValue() throws {
        let colour = try NSRegularExpression(pattern: #"#[0-9a-fA-F]{3,8}\b|rgba?\("#)
        let tokens = try colourTokens()
        XCTAssertGreaterThan(tokens.count, 40)
        for (name, value) in tokens where colour.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil && !name.hasPrefix("screen-") {
            XCTAssertTrue(value.contains("light-dark("), "--\(name) has one value for both themes: \(value)")
        }
        let css = WebViewer.asset("viewer.css")
        XCTAssertTrue(css.contains("color-scheme: light dark;"), "the page follows the system's appearance")
        XCTAssertTrue(css.contains(#":root[data-theme="light"] { color-scheme: light; }"#))
        XCTAssertTrue(css.contains(#":root[data-theme="dark"] { color-scheme: dark; }"#))
    }

    // WCAG AA in both themes: every ink that sets text reads at 4.5:1 or more on
    // every surface text sits on, and so do the inverted pairs — filled buttons,
    // tooltips and toasts, the Fault badge, words on the device's screen.
    func testEveryTextPairMeetsAAInBothThemes() throws {
        let tokens = try colourTokens()
        let inks = ["ink1", "ink2", "ink3", "accent", "course", "ok", "warn", "err", "json-str", "json-num", "json-lit"]
        var pairs = inks.flatMap { ink in ["g0", "g1", "g2", "g3"].map { (ink, $0) } }
        pairs += [("on-accent", "accent"), ("on-accent", "accent-hover"), ("g1", "ink1"), ("g1", "err"), ("screen-ink", "screen-black")]
        var failures: [String] = []
        for (dark, theme) in [(false, "light"), (true, "dark")] {
            for (text, surface) in pairs {
                let (foreground, background) = (try hex(tokens, text, dark: dark), try hex(tokens, surface, dark: dark))
                let ratio = contrast(foreground, background)
                if ratio < 4.5 { failures.append("\(theme): --\(text) \(foreground) on --\(surface) \(background) is \(String(format: "%.2f", ratio)):1") }
            }
        }
        XCTAssertEqual(failures, [])
    }

    // A pinned theme is on <html> before the body is parsed, so the page never
    // paints in the other theme first; the button names what it switches to.
    func testAPinnedThemeIsAppliedBeforeTheBody() throws {
        let html = WebViewer.html()
        let body = try XCTUnwrap(html.range(of: "<body>"))
        let head = html[..<body.lowerBound]
        XCTAssertTrue(head.contains(#"<script src="/assets/js/theme.js"></script>"#), "theme.js runs while the head is parsed: in <head>, neither defer nor async")
        let theme = WebViewer.asset("js/theme.js")
        XCTAssertTrue(theme.contains(#"localStorage.getItem(THEME_KEY)"#))
        XCTAssertTrue(theme.contains("\napplyTheme();\n"), "the stored theme is applied while the head is parsed")
        XCTAssertTrue(page.contains(#"id="themeButton" aria-label="Switch to the light theme""#))
        XCTAssertTrue(page.contains(#"$("themeButton").addEventListener("click", toggleTheme);"#))
    }

    /// `--name` (without the dashes) → its value, from the token block on :root.
    private func colourTokens() throws -> [String: String] {
        let css = WebViewer.asset("viewer.css")
        let start = try XCTUnwrap(css.range(of: ":root {"))
        let end = try XCTUnwrap(css.range(of: "}", range: start.upperBound..<css.endIndex))
        let block = String(css[start.upperBound..<end.lowerBound])
        let declaration = try NSRegularExpression(pattern: #"--([\w-]+):\s*([^;]+);"#)
        var tokens: [String: String] = [:]
        for match in declaration.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
            tokens[String(block[Range(match.range(at: 1), in: block)!])] = String(block[Range(match.range(at: 2), in: block)!])
        }
        return tokens
    }

    /// The token's hex colour in one theme: `light-dark(#light, #dark)` or a plain `#hex`.
    private func hex(_ tokens: [String: String], _ name: String, dark: Bool) throws -> String {
        let value = try XCTUnwrap(tokens[name], "no --\(name)")
        let colours = value.split(whereSeparator: { "(), ".contains($0) }).filter { $0.hasPrefix("#") }.map(String.init)
        let colour = try XCTUnwrap(colours.count == 2 ? colours[dark ? 1 : 0] : colours.first, "--\(name) is not a hex colour: \(value)")
        // #abc is #aabbcc.
        return colour.count == 4 ? "#" + colour.dropFirst().map { "\($0)\($0)" }.joined() : colour
    }

    private func contrast(_ a: String, _ b: String) -> Double {
        func luminance(_ hex: String) -> Double {
            let rgb = Int(hex.dropFirst(), radix: 16) ?? 0
            let linear = [rgb >> 16 & 255, rgb >> 8 & 255, rgb & 255].map { channel -> Double in
                let value = Double(channel) / 255
                return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
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
