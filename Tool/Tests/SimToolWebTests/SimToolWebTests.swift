import XCTest
@testable import SimToolWeb

final class SimToolWebTests: XCTestCase {
    func testViewerEmbedsInspectToggleAndTabs() {
        let html = WebViewer.html()

        XCTAssertTrue(html.contains("id=\"inspectToggle\""), "missing Inspect toggle control")
        XCTAssertTrue(html.contains("id=\"inspector\""), "missing inspector drawer container")
        XCTAssertTrue(html.contains("id=\"drawerHandle\""), "missing resizable drawer handle")
        XCTAssertTrue(html.contains("id=\"tabNetwork\""), "missing Network tab")
        XCTAssertTrue(html.contains("id=\"tabLogs\""), "missing Logs tab")
        XCTAssertTrue(html.contains("id=\"tabAx\""), "missing AX tab placeholder")
        // The tabs are mutually exclusive: switching is driven by a single active tab.
        XCTAssertTrue(html.contains("function setActiveTab"), "missing mutually-exclusive tab switching")
    }

    func testViewerInspectorIsAdaptive() {
        let html = WebViewer.html()

        // Wide stage docks the inspector as a right column; narrow uses the bottom drawer.
        XCTAssertTrue(html.contains("function updateInspectorLayout"), "missing adaptive layout switch")
        XCTAssertTrue(html.contains("layout-side"), "missing side-by-side layout mode")
        XCTAssertTrue(html.contains(".stage.layout-side .inspector"), "missing side-by-side inspector styling")
    }

    func testViewerEmbedsNetworkInspector() {
        let html = WebViewer.html()

        XCTAssertTrue(html.contains("id=\"networkList\""), "missing network request list")
        XCTAssertTrue(html.contains("id=\"detailBody\""), "missing drill-down detail pane")
        XCTAssertTrue(html.contains("id=\"detailBack\""), "missing drill-down back control")
        XCTAssertTrue(html.contains("/api/v1/network/events"), "network inspector must poll the events endpoint")
    }

    func testViewerEmbedsLogsInspector() {
        let html = WebViewer.html()

        XCTAssertTrue(html.contains("id=\"logsList\""), "missing logs entry list")
        XCTAssertTrue(html.contains("/api/v1/logs/capture"), "logs inspector must poll the capture endpoint")
        XCTAssertTrue(html.contains("config.logApp"), "logs inspector must auto-scope to the server's default app")
        XCTAssertTrue(html.contains("logs-row-error"), "logs inspector must highlight error entries")
        XCTAssertTrue(html.contains("isErrorEntry"), "logs inspector must classify error entries")
        // The shared filter field is the only filtering surface: the bundle-id input and the
        // oslog/stdout source select are gone, and the filter starts out empty.
        XCTAssertFalse(html.contains("id=\"logsApp\""), "bundle-id input must be gone")
        XCTAssertFalse(html.contains("id=\"logsSource\""), "source select must be gone")
        XCTAssertFalse(html.contains("captureStdout"), "stdout capture must not be requested")
        XCTAssertFalse(html.contains("seedDefaultLogsChip"), "default chip seeding must be gone")
        XCTAssertFalse(html.contains("simtool.logsDefaultChip"), "default chip storage key must be gone")
    }

    func testViewerShowsSimulatorNameInStatusBar() {
        let html = WebViewer.html()

        XCTAssertTrue(html.contains("id=\"deviceName\""), "status bar must show the simulator name")
        XCTAssertTrue(html.contains("config.device"), "status bar must read the device name from /config")
        // The codec label and stream resolution were dropped from the status bar.
        XCTAssertFalse(html.contains("codec: starting"), "codec label must be gone from the status bar")
        XCTAssertFalse(html.contains("id=\"size\""), "stream resolution readout must be gone")
    }

    func testViewerStillRendersStreamControls() {
        let html = WebViewer.html()

        XCTAssertTrue(html.contains("id=\"screen\""))
        XCTAssertTrue(html.contains("id=\"stage\""))
    }

    func testViewerStreamsH264Exclusively() {
        let html = WebViewer.html()

        // The viewer drives the H.264/AVCC stream and nothing else.
        XCTAssertTrue(html.contains("startAvcc().catch"), "viewer must start the avcc stream")
        XCTAssertTrue(html.contains("/stream.avcc"), "viewer must connect to the avcc stream")
        // No JPEG/MJPEG transports remain.
        XCTAssertFalse(html.contains("/stream.jpeg"), "raw JPEG transport must be gone")
        XCTAssertFalse(html.contains("/stream.mjpeg"), "MJPEG transport must be gone")
        XCTAssertFalse(html.contains("startJPEGFetch"), "JPEG fetch path must be gone")
        XCTAssertFalse(html.contains("startMjpeg"), "MJPEG fallback path must be gone")
        XCTAssertFalse(html.contains("id=\"mjpeg\""), "MJPEG fallback <img> must be gone")
    }

    func testViewerConfiguresDecoderForLowLatency() {
        let html = WebViewer.html()

        XCTAssertTrue(html.contains("optimizeForLatency: true"), "decoder must use the real low-latency flag")
        XCTAssertFalse(html.contains("optimizeFor: \"latency\""), "the non-standard optimizeFor key must be gone")
    }

    func testViewerEmbedsAxInspector() {
        let html = WebViewer.html()

        // AX panel scaffolding
        XCTAssertTrue(html.contains("id=\"axTree\""), "missing AX tree container")
        XCTAssertTrue(html.contains("id=\"axOverlay\""), "missing AX overlay layer")
        XCTAssertTrue(html.contains("id=\"axCopy\""), "missing AX copy button")
        XCTAssertTrue(html.contains("id=\"axRefresh\""), "missing AX refresh button")
        XCTAssertTrue(html.contains("id=\"axSelectedBar\""), "missing AX selected-element bar")
        // The old placeholder copy must be gone.
        XCTAssertFalse(html.contains("Бэкенд уже отдаёт его"), "AX stub placeholder must be removed")
        // Behavior anchors (filled in by later tasks, asserted here once).
        XCTAssertTrue(html.contains("/api/v1/ax/tree"), "AX inspector must poll the tree endpoint")
        XCTAssertTrue(html.contains("function renderAxTree"), "missing AX tree renderer")
        XCTAssertTrue(html.contains("function axHitTest"), "missing AX hit-test")
        XCTAssertTrue(html.contains("function axCopyPayload"), "missing AX copy payload builder")
        // Copy is available via the button and via a right-click context menu
        // (Copy element) on a tree row or on the screen.
        XCTAssertTrue(html.contains("function copyAxNode"), "missing per-node copy helper")
        XCTAssertTrue(html.contains("contextmenu"), "missing right-click wiring")
        XCTAssertTrue(html.contains("id=\"axMenu\""), "missing AX context menu")
        XCTAssertTrue(html.contains(">Copy element<"), "missing Copy element menu item")
        XCTAssertTrue(html.contains("function showAxMenu"), "missing context menu opener")
    }

    func testViewerCardIsHorizontallyResizable() {
        let html = WebViewer.html()

        // Drag handles on both card edges resize the whole card.
        XCTAssertTrue(html.contains("id=\"cardResizeLeft\""), "missing left resize handle")
        XCTAssertTrue(html.contains("id=\"cardResizeRight\""), "missing right resize handle")
        XCTAssertTrue(html.contains("--card-w"), "card width must be driven by a CSS variable")
        // The screen pane caps at 600px; width beyond that goes to the inspector.
        XCTAssertTrue(html.contains(".stage.layout-side.inspector-open .screen-wrap { max-width: 600px; }"),
                      "screen pane must cap at 600px when the inspector is open")
        XCTAssertTrue(html.contains("flex: 1 0 400px"), "inspector must absorb width past the screen cap")
        // The chosen width survives a reload, like the drawer height does.
        XCTAssertTrue(html.contains("simtool.cardWidth"), "card width must persist in localStorage")
    }

    func testViewerEmbedsStateInspector() {
        let html = WebViewer.html()

        XCTAssertTrue(html.contains("id=\"tabState\""), "missing State tab")
        XCTAssertTrue(html.contains("id=\"statePane\""), "missing state pane")
        XCTAssertTrue(html.contains("id=\"stateModels\""), "missing model snapshot list")
        XCTAssertTrue(html.contains("id=\"stateHistory\""), "missing state change history")
        XCTAssertTrue(html.contains("/api/v1/state/events"), "state inspector must poll the state events endpoint")
        XCTAssertTrue(html.contains("function renderStateTree"), "missing snapshot tree renderer")
        XCTAssertTrue(html.contains("function diffStateValues"), "missing snapshot diff")
        XCTAssertTrue(html.contains("state-dead"), "deallocated models must be greyed out")
    }

    func testViewerAxPaneRequestsRawTree() {
        let html = WebViewer.html()

        // The lean tree omits `raw` for agents; the browser's Copy JSON
        // feature still wants the full AXe payload, so the pane opts back in.
        XCTAssertTrue(html.contains("/api/v1/ax/tree?raw=1"), "AX pane must opt into raw nodes")
    }

    func testViewerEmbedsShakeButtonAndEmojiToolbarIcons() {
        let html = WebViewer.html()

        // Shake sits next to Home and Screenshot and posts the shake action.
        XCTAssertTrue(html.contains("id=\"shake\""), "missing Shake button")
        XCTAssertTrue(html.contains("function pressShake"), "missing shake click handler")
        XCTAssertTrue(html.contains("action: \"shake\""), "shake must post the shake input action")
        // The old glyphs were unreadable; the toolbar uses emoji icons now.
        XCTAssertTrue(html.contains(">🏠<"), "Home button must use the house emoji")
        XCTAssertTrue(html.contains(">📸<"), "Screenshot button must use the camera emoji")
        XCTAssertTrue(html.contains(">📳<"), "Shake button must use the vibration emoji")
        XCTAssertFalse(html.contains(">⌂<"), "old Home glyph must be gone")
        XCTAssertFalse(html.contains(">⎙<"), "old Screenshot glyph must be gone")
    }

    func testViewerEmbedsTerminateButtonNextToShake() {
        let html = WebViewer.html()

        // Terminate sits immediately to the right of Shake and posts the terminate action.
        XCTAssertTrue(html.contains("id=\"terminate\""), "missing Terminate button")
        XCTAssertTrue(html.contains("function pressTerminate"), "missing terminate click handler")
        XCTAssertTrue(html.contains("action: \"terminate\""), "terminate must post the terminate input action")
        guard let shakeRange = html.range(of: "id=\"shake\""),
              let terminateRange = html.range(of: "id=\"terminate\"") else {
            return XCTFail("toolbar buttons not found")
        }
        let between = html[shakeRange.upperBound..<terminateRange.lowerBound]
        XCTAssertFalse(between.contains("<button id="), "Terminate must directly follow Shake in the toolbar")
    }

    func testViewerEmbedsRelaunchButtonNextToTerminate() {
        let html = WebViewer.html()

        // Relaunch sits immediately to the right of Terminate and posts the launch
        // action, so the app comes back with the SIMCTL_CHILD_* logger environment
        // (an icon-tap launch loses it and the State/Network tabs go silent).
        XCTAssertTrue(html.contains("id=\"relaunch\""), "missing Relaunch button")
        XCTAssertTrue(html.contains("function pressRelaunch"), "missing relaunch click handler")
        XCTAssertTrue(html.contains("action: \"launch\""), "relaunch must post the launch input action")
        guard let terminateRange = html.range(of: "id=\"terminate\""),
              let relaunchRange = html.range(of: "id=\"relaunch\"") else {
            return XCTFail("toolbar buttons not found")
        }
        let between = html[terminateRange.upperBound..<relaunchRange.lowerBound]
        XCTAssertFalse(between.contains("<button id="), "Relaunch must directly follow Terminate in the toolbar")
    }

    func testStateHistoryFoldsEmbeddedModelsIntoParent() {
        let html = WebViewer.html()

        // Nested tracked models are stamped with "$modelId"; the viewer uses it
        // to hide their standalone history entries while a live parent shows
        // the same change as a nested diff.
        XCTAssertTrue(html.contains("MODEL_ID_KEY"), "missing $modelId marker constant")
        XCTAssertTrue(html.contains("\"$modelId\""), "marker constant must match the serializer key")
        XCTAssertTrue(html.contains("function embeddedModelIds"), "missing embedded-model map builder")
        XCTAssertTrue(html.contains("embedded.has(event.modelId)"), "history must skip embedded models")
        // The marker itself never renders in snapshot trees or diffs.
        XCTAssertTrue(html.contains("key === MODEL_ID_KEY"), "marker key must be filtered from rendering")
    }

    func testViewerEmbedsFilterChips() {
        let html = WebViewer.html()

        // Chip field scaffolding.
        XCTAssertTrue(html.contains("id=\"filterChips\""), "missing chip container in the filter field")
        XCTAssertTrue(html.contains("id=\"filterHelp\""), "missing filter help button")
        XCTAssertTrue(html.contains("id=\"filterHelpPop\""), "missing filter help popover")
        // Right-click menu on network rows (Network tab only).
        XCTAssertTrue(html.contains("id=\"networkMenu\""), "missing network context menu")
        XCTAssertTrue(html.contains("id=\"networkMenuExclude\""), "missing Exclude menu item")
        XCTAssertTrue(html.contains("id=\"networkMenuInclude\""), "missing Include menu item")
        XCTAssertTrue(html.contains("function showNetworkMenu"), "missing network menu opener")
        XCTAssertTrue(html.contains("function chipPathForEvent"), "missing request path extraction")
        // Chips work on every tab against that tab's filter fields.
        XCTAssertTrue(html.contains("filterChipsByTab"), "missing per-tab chip state")
        XCTAssertTrue(html.contains("function addFilterChip"), "missing chip add helper")
        XCTAssertTrue(html.contains("function renderFilterChips"), "missing chip renderer")
        XCTAssertTrue(html.contains("function matchesFilters"), "missing shared chip/query predicate")
        XCTAssertTrue(html.contains("function networkEventHaystack"), "missing network match haystack")
        XCTAssertTrue(html.contains("function axHaystack"), "missing AX match haystack")
        // Chips survive a reload.
        XCTAssertTrue(html.contains("simtool.filterChips"), "chips must persist in localStorage")
        XCTAssertFalse(html.contains("simtool.networkFilterChips"), "old network-only storage key must be gone")
        // On the Logs tab a "field:text" term scopes matching to that single field.
        XCTAssertTrue(html.contains("function parseFieldTerm"), "missing field:term parser")
        XCTAssertTrue(html.contains("function termMatches"), "missing field-aware term matcher")
        XCTAssertTrue(html.contains("LOGS_FILTER_FIELDS"), "missing logs field whitelist")
        XCTAssertTrue(html.contains("subsystem:text"), "filter help must document the field syntax")
        // The help popover only shows the lines relevant to the active tab.
        XCTAssertTrue(html.contains("<p data-tab=\"logs\">"), "logs-only help lines must be tagged")
        XCTAssertTrue(html.contains("<p data-tab=\"network\">"), "network-only help lines must be tagged")
        XCTAssertTrue(html.contains("dataset.tab !== activeTab"), "help lines must be gated by the active tab")
    }

    func testViewerSupportsLogTextSelectionAndCopy() {
        let html = WebViewer.html()

        // Right-click menu on log rows: Copy entry without a selection.
        XCTAssertTrue(html.contains("id=\"logsMenu\""), "missing logs context menu")
        XCTAssertTrue(html.contains("id=\"logsMenuCopy\""), "missing Copy entry menu item")
        XCTAssertTrue(html.contains("function showLogsMenu"), "missing logs menu opener")
        XCTAssertTrue(html.contains("function logEntryText"), "missing log entry text builder")
        // Selecting text in a row must not open the detail view on mouseup.
        XCTAssertTrue(html.contains("getSelection"), "row clicks must not clobber an active text selection")
        // With a selection, right-click offers copy/include/exclude on the selected text.
        XCTAssertTrue(html.contains("id=\"logsMenuCopySel\""), "missing Copy Selected menu item")
        XCTAssertTrue(html.contains("id=\"logsMenuIncludeSel\""), "missing Include Selected menu item")
        XCTAssertTrue(html.contains("id=\"logsMenuExcludeSel\""), "missing Exclude Selected menu item")
        XCTAssertTrue(html.contains(">Copy Selected<"), "Copy Selected label must be present")
        XCTAssertTrue(html.contains(">Include Selected<"), "Include Selected label must be present")
        XCTAssertTrue(html.contains(">Exclude Selected<"), "Exclude Selected label must be present")
    }

    func testViewerEmbedsTestsInspector() {
        let html = WebViewer.html()

        // Tab scaffolding.
        XCTAssertTrue(html.contains("id=\"tabTests\""), "missing Tests tab")
        XCTAssertTrue(html.contains("id=\"testsCount\""), "missing Tests tab count badge")
        XCTAssertTrue(html.contains("id=\"testsPane\""), "missing Tests pane")
        XCTAssertTrue(html.contains("id=\"testsSessions\""), "missing sessions list container")
        XCTAssertTrue(html.contains("id=\"testsTimeline\""), "missing timeline container")
        // Polling and rendering.
        XCTAssertTrue(html.contains("/api/v1/tests"), "tests inspector must poll the sessions endpoint")
        XCTAssertTrue(html.contains("function startTestsPolling"), "missing tests polling starter")
        XCTAssertTrue(html.contains("function renderTestsList"), "missing sessions list renderer")
        XCTAssertTrue(html.contains("function renderTestTimeline"), "missing timeline renderer")
        XCTAssertTrue(html.contains("function entryOffsetSeconds"), "missing video-offset computation")
        // Status badges for every lifecycle state.
        XCTAssertTrue(html.contains("tests-status-passed"), "missing passed badge styling")
        XCTAssertTrue(html.contains("tests-status-failed"), "missing failed badge styling")
        XCTAssertTrue(html.contains("tests-status-running"), "missing running badge styling")
        XCTAssertTrue(html.contains("tests-status-interrupted"), "missing interrupted badge styling")
    }

    // A run started with `simtool test run` in a terminal records its session on
    // this server, so the viewer is watching it — and must not offer to start it
    // again, nor a Stop it cannot honour (the server holds no task to cancel).
    func testViewerShowsARunItCannotStopAsRunning() {
        let html = WebViewer.html()

        XCTAssertTrue(html.contains("stoppable"), "run status must carry whether Stop applies")
        XCTAssertTrue(html.contains("Running…"), "a run the viewer cannot stop needs a non-actionable label")
    }

    func testViewerEmbedsTestsContextMenuWithDelete() {
        let html = WebViewer.html()

        // Right-click on a session row opens a custom context menu.
        XCTAssertTrue(html.contains("id=\"testsMenu\""), "missing tests context menu container")
        XCTAssertTrue(html.contains("id=\"testsMenuDelete\""), "missing Delete menu item")
        XCTAssertTrue(html.contains("tests-menu-delete"), "Delete item must carry destructive styling")
        XCTAssertTrue(html.contains("\"contextmenu\""), "session rows must hook the contextmenu event")
        // Delete calls the API and refreshes the list.
        XCTAssertTrue(html.contains("method: \"DELETE\""), "Delete must call the DELETE endpoint")
        XCTAssertTrue(html.contains("function showTestsMenu"), "missing context menu opener")
        XCTAssertTrue(html.contains("function hideTestsMenu"), "missing context menu dismisser")
    }

    func testViewerSwapsScreenToTestVideoPlayback() {
        let html = WebViewer.html()

        // Playback overlay scaffolding in the screen pane.
        XCTAssertTrue(html.contains("id=\"testPlayback\""), "missing playback overlay")
        XCTAssertTrue(html.contains("id=\"testVideo\""), "missing playback video element")
        XCTAssertTrue(html.contains("id=\"testBackLive\""), "missing back-to-live button")
        XCTAssertTrue(html.contains("id=\"testVideoNote\""), "missing video-unavailable note")
        // `display: flex` on the class beats the UA `[hidden]` rule, so without
        // this selector the opaque panel covers the live canvas forever.
        XCTAssertTrue(html.contains(".test-playback[hidden] { display: none; }"), "playback overlay must hide when the hidden attribute is set")
        // Behavior anchors.
        XCTAssertTrue(html.contains("function showTestVideo"), "missing playback swap-in")
        XCTAssertTrue(html.contains("function showLiveStream"), "missing live swap-back")
        XCTAssertTrue(html.contains("/video"), "playback must stream the session video endpoint")
        // The native player controls are the only scrubber: no custom marker strip.
        XCTAssertFalse(html.contains("id=\"testMarkers\""), "custom marker strip must be gone")
        XCTAssertFalse(html.contains("function renderTestMarkers"), "marker renderer must be gone")
        // Auto-switch: a watched running session that finishes starts playback.
        XCTAssertTrue(html.contains("function maybeAutoSwitchPlayback"), "missing auto-switch hook")
        // Current-step highlight follows the playhead.
        XCTAssertTrue(html.contains("timeupdate"), "missing playhead-driven step highlight")
    }
}
