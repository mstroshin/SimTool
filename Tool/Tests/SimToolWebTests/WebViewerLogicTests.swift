import JavaScriptCore
@testable import SimToolWeb
import XCTest

// web/js/logic.js holds everything the viewer decides without the browser:
// what a status means, what a filter keeps, what changed in a model, where a
// step sits in a recording, what to copy. It runs here on its own.
final class WebViewerLogicTests: XCTestCase {
    private func makeContext(file: StaticString = #filePath, line: UInt = #line) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("JS exception: \(exception?.toString() ?? "?")", file: file, line: line)
        }
        context.evaluateScript(WebViewer.asset("js/logic.js"))
        return context
    }

    private func value(_ context: JSContext, _ expression: String) -> String {
        context.evaluateScript(expression)?.toString() ?? ""
    }

    // MARK: - Network status

    func testHTTPStatusSeverityFollowsTheStatusClass() throws {
        let context = try makeContext()
        func severity(_ code: Int) -> String {
            value(context, "networkStatus({ protocol: 'http', response: { statusCode: \(code) } }).severity")
        }
        XCTAssertEqual(severity(200), "ok")
        XCTAssertEqual(severity(204), "ok")
        XCTAssertEqual(severity(304), "info", "not modified is not a warning")
        XCTAssertEqual(severity(404), "warn")
        XCTAssertEqual(severity(500), "err")
        XCTAssertEqual(value(context, "JSON.stringify(networkStatus({ protocol: 'http', error: { message: 'timed out' } }))"),
                       #"{"text":"Failed","severity":"err","title":"timed out"}"#)
        XCTAssertEqual(value(context, "networkStatus({ protocol: 'http' }).severity"), "pending")
    }

    func testGRPCCodesAreNamedAndSplitIntoClientAndServerFailures() throws {
        let context = try makeContext()
        func status(_ code: String) -> String {
            value(context, "(s => s.text + ' ' + s.severity)(networkStatus({ protocol: 'grpc', response: { grpcStatusCode: '\(code)' } }))")
        }
        XCTAssertEqual(status("0"), "OK ok")
        XCTAssertEqual(status("5"), "NOT_FOUND warn")
        XCTAssertEqual(status("16"), "UNAUTHENTICATED warn")
        XCTAssertEqual(status("13"), "INTERNAL err")
        XCTAssertEqual(status("14"), "UNAVAILABLE err")
        XCTAssertEqual(value(context, "networkStatus({ protocol: 'grpc', response: { grpcStatusCode: '13', grpcStatusMessage: 'upstream reset' } }).title"),
                       "INTERNAL — upstream reset")
    }

    func testFailuresAndClientProblemsAreCountedApartAsTheirRowsAreColoured() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var calls = [
          { protocol: 'http', response: { statusCode: 200 } },
          { protocol: 'http', response: { statusCode: 404 } },
          { protocol: 'grpc', response: { grpcStatusCode: '16' } },
          { protocol: 'grpc', response: { grpcStatusCode: '13' } },
          { protocol: 'http', error: { message: 'timed out' } }
        ];
        """)
        XCTAssertEqual(value(context, "networkMarks(calls).map(m => m.tone + ':' + m.count).join(' ')"), "err:2 warn:2")
        XCTAssertEqual(value(context, "calls.filter(isNetworkProblem).length"), "4", "the Problems filter keeps both")
    }

    func testCopyCommandsReproduceTheRequest() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var http = { protocol: 'http', request: { method: 'POST', url: 'https://api.example.com/v2/cart/items', headers: { accept: 'application/json' }, bodyPreview: '{"qty":1}' },
                     response: { statusCode: 201, bodyPreview: '{ "cartId": "k-1" }' } };
        var grpc = { protocol: 'grpc', request: { path: '/shop.v1.Promo/GetPromotions', grpcService: 'shop.v1.Promo', grpcMethod: 'GetPromotions', grpcAuthority: 'grpc.example.com:443', metadata: { 'x-client': '3.4' }, bodyPreview: '{}' },
                     response: { grpcStatusCode: '14' } };
        """)
        XCTAssertEqual(value(context, "curlCommand(http)"),
                       "curl \\\n  -X POST \\\n  'https://api.example.com/v2/cart/items' \\\n  -H 'accept: application/json' \\\n  --data-raw '{\"qty\":1}'")
        XCTAssertEqual(value(context, "grpcurlCommand(grpc)"),
                       "grpcurl \\\n  -H 'x-client: 3.4' \\\n  -d '{}' \\\n  grpc.example.com:443 \\\n  shop.v1.Promo/GetPromotions")
        // A mock entry a YAML test can paste: the answer it got, or the error.
        XCTAssertEqual(value(context, "mockYaml(grpc)"), "mocks:\n  - method: \"*/GetPromotions\"\n    error: unavailable")
        XCTAssertEqual(value(context, "mockYaml({ protocol: 'grpc', request: { grpcMethod: 'List' }, response: { grpcStatusCode: '0', bodyPreview: '{ \"items\": [] }' } })"),
                       "mocks:\n  - method: \"*/List\"\n    body: {\"items\":[]}")
    }

    // A call can arrive twice — pushed, then replayed after a reconnect — and
    // its id says it is the same call.
    func testPushedCallsReplaceTheirIdAndKeepOnlyTheNewest() throws {
        let context = try makeContext()
        context.evaluateScript("var held = [{ id: 'a', n: 1 }, { id: 'b', n: 1 }];")
        XCTAssertEqual(value(context, "mergeNetworkEvents(held, [{ id: 'b', n: 2 }, { id: 'c', n: 1 }], 10).map(e => e.id + e.n).join()"), "a1,b2,c1")
        XCTAssertEqual(value(context, "mergeNetworkEvents(held, [{ id: 'c' }, { id: 'd' }], 3).map(e => e.id).join()"), "b,c,d", "the oldest goes first")
        XCTAssertEqual(value(context, "mergeNetworkEvents(held, undefined, 10).length"), "2")
        XCTAssertEqual(value(context, "held.map(e => e.n).join()"), "1,1", "what the page held is not changed under it")
    }

    // MARK: - Filters

    func testChipsExcludeFirstThenIncludeAnyThenTheLiveText() throws {
        let context = try makeContext()
        context.evaluateScript("var chips = [{ kind: 'include', term: 'catalog' }, { kind: 'include', term: 'cart' }, { kind: 'exclude', term: 'analytics' }];")
        XCTAssertEqual(value(context, "matchesFilters('get /catalog/list', chips, '')"), "true")
        XCTAssertEqual(value(context, "matchesFilters('post /cart/analytics', chips, '')"), "false", "exclude wins")
        XCTAssertEqual(value(context, "matchesFilters('get /orders', chips, '')"), "false", "includes are OR'd")
        XCTAssertEqual(value(context, "matchesFilters('get /catalog/list', chips, 'orders')"), "false", "the live text narrows further")
    }

    func testAFieldTermMatchesOnlyThatField() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(parseFieldTerm('subsystem:com.app', ['subsystem', 'message']))"), #"{"field":"subsystem","term":"com.app"}"#)
        XCTAssertEqual(value(context, "parseFieldTerm('https://x', ['subsystem']).field"), "null", "an URL's scheme is not a field")
        XCTAssertEqual(value(context, "matchesFilters('', [{ kind: 'include', term: 'net', field: 'subsystem' }], '', { subsystem: 'com.app.net', message: '' })"), "true")
        XCTAssertEqual(value(context, "matchesFilters('net', [{ kind: 'include', term: 'net', field: 'subsystem' }], '', { subsystem: 'com.app.ui', message: 'net' })"), "false")
    }

    func testAnExcludeChipReplacesTheSameIncludeInsteadOfStacking() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(withChip([{ kind: 'include', term: 'Cart' }], 'exclude', 'cart'))"), #"[{"kind":"exclude","term":"cart"}]"#)
        XCTAssertEqual(value(context, "withChip([], 'include', '   ').length"), "0")
    }

    // MARK: - Logs

    func testAnErrorIsALevelNotAWordInTheMessage() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "isLogError({ level: 'Info', message: 'Did post notification. error:0' })"), "false")
        XCTAssertEqual(value(context, "isLogError({ level: 'Error', message: 'ok' })"), "true")
        XCTAssertEqual(value(context, "isLogError({ level: 'fault' })"), "true")
        XCTAssertEqual(value(context, "logLevel({})"), "Default", "a line without a level is Default")
    }

    func testALineAtOrBelowTheCursorIsNeverTakenAgain() throws {
        let context = try makeContext()
        context.evaluateScript("var lines = [{ sequence: 4 }, { sequence: 5 }, { sequence: 6 }];")
        XCTAssertEqual(value(context, "linesAfter(lines, 5).map(l => l.sequence).join()"), "6")
        XCTAssertEqual(value(context, "linesAfter(lines, null).length"), "3", "no cursor yet: every line")
        XCTAssertEqual(value(context, "linesAfter(lines, 9).length"), "0")
        XCTAssertEqual(value(context, "linesAfter(undefined, 1).length"), "0")
    }

    // MARK: - State

    func testStateDiffsNameTheChangedPaths() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(diffStateValues({ total: 1, items: ['a'], nested: { on: false } }, { total: 2, items: ['a'], nested: { on: true } }, '', []))"),
                       #"[{"path":"total","before":1,"after":2},{"path":"nested.on","before":false,"after":true}]"#)
        XCTAssertEqual(value(context, "diffStateValues({ $modelId: 'A' }, { $modelId: 'B' }, '', []).length"), "0", "the marker never diffs")
    }

    func testAModelEmbeddedInALiveParentIsFoldedIntoIt() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(embeddedModelIds({ Parent: { snapshot: { child: { $modelId: 'Child', n: 1 } } }, Child: { snapshot: { n: 1 } } }))"), #"{"Child":"Parent"}"#)
        XCTAssertEqual(value(context, "JSON.stringify(embeddedModelIds({ Parent: { deallocated: true, snapshot: { child: { $modelId: 'Child' } } } }))"), "{}",
                       "a child resurfaces once its parent deallocates")
    }

    // MARK: - Tests and recordings

    func testOutcomesSayWhatTheVerdictMeansForTheKind() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "outcomeOf({ verdict: 'unsatisfied', kind: 'bug' }).text"), "Bug reproduced")
        XCTAssertEqual(value(context, "outcomeOf({ verdict: 'satisfied', kind: 'feature' }).text"), "Confirmed")
        XCTAssertEqual(value(context, "outcomeOf({ verdict: 'infra' }).text"), "Infra — cannot be trusted")
        XCTAssertEqual(value(context, "outcomeOf({ status: 'failed' }).text"), "Failed", "tests without a kind keep pass/fail")
    }

    func testStepTextSplitsIntoMarkPositionHeadAndReason() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(parseStepText('✗ 3/3 Wait for \"Done\" · AC-1 — no element appeared'))"),
                       #"{"mark":"failed","index":3,"total":3,"text":"Wait for \"Done\" · AC-1 — no element appeared"}"#)
        XCTAssertEqual(value(context, "JSON.stringify(splitStep('Wait for \"Done\" — no element appeared'))"), #"{"head":"Wait for \"Done\"","tail":"no element appeared"}"#)
        XCTAssertEqual(value(context, "parseStepText('Launched com.example').mark"), "note")
    }

    func testStepOffsetsScaleOntoAVideoShorterThanTheWallClock() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var session = { startedAt: '2026-01-01T00:00:00Z', recordingStartedAt: '2026-01-01T00:00:00Z', endedAt: '2026-01-01T00:00:20Z', videoDurationSeconds: 10 };
        """)
        XCTAssertEqual(value(context, "entryOffsetSeconds(session, { at: '2026-01-01T00:00:10Z' })"), "5")
        XCTAssertEqual(value(context, "entryOffsetSeconds(session, { at: '2026-01-01T00:00:30Z' })"), "10", "never past the end of the video")
        XCTAssertEqual(value(context, "entryOffsetSeconds({ startedAt: '2026-01-01T00:00:00Z' }, { at: '2026-01-01T00:00:04Z' })"), "4")
    }

    func testTheLastRunOfEachTestIsItsNewestFinishedSession() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, """
        (r => r['a.yml'].id + ',' + r['b.yml'].id)(lastRunByFile([
          { id: 'old', file: 'a.yml', status: 'failed', startedAt: '2026-01-01T00:00:00Z' },
          { id: 'new', file: 'a.yml', status: 'passed', startedAt: '2026-01-02T00:00:00Z' },
          { id: 'live', file: 'a.yml', status: 'running', startedAt: '2026-01-03T00:00:00Z' },
          { id: 'b', file: 'b.yml', status: 'passed', startedAt: '2026-01-01T00:00:00Z' }
        ]))
        """), "new,b")
    }

    // MARK: - Accessibility

    // Measured on an iPhone 17 Pro: a still Settings screen sends 169–215-byte
    // frames five times a second, the clock ticking over sends 612 bytes.
    func testOnlyAFrameThatChangesThePictureCountsAsAChange() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "frameChangesScreen('delta', 215, 169)"), "false", "the same picture again")
        XCTAssertEqual(value(context, "frameChangesScreen('delta', 612, 169)"), "true", "the clock ticked over")
        XCTAssertEqual(value(context, "frameChangesScreen('delta', 25519, 169)"), "true")
        XCTAssertEqual(value(context, "frameChangesScreen('keyframe', 30000, 169)"), "true")
        XCTAssertEqual(value(context, "frameChangesScreen('delta', 380, 120)"), "false", "never below 400 bytes")
        XCTAssertEqual(value(context, "frameChangesScreen('delta', 5637, 5637)"), "false", "the first frame after a keyframe is its own measure")
    }

    func testAStepNamesAnElementTheWayTheRunnerFindsIt() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "axYamlStep({ accessibilityIdentifier: 'About', label: 'About us' })"), #"- tap: { id: "About" }"#)
        XCTAssertEqual(value(context, "axYamlStep({ label: ' Settings ' })"), #"- tap: { label: "Settings" }"#)
        XCTAssertEqual(value(context, "axYamlStep({ frame: { x: 10, y: 20, width: 100, height: 40 } })"), "- tap: { x: 60, y: 40 }", "a nameless element is tapped at its centre")
        XCTAssertEqual(value(context, "axCliCommand({ label: \"Bob's\" })"), #"simtool input tap --label 'Bob'\''s'"#)
        XCTAssertEqual(value(context, "axIsAnonymous({ role: 'AXGroup', label: '  ' })"), "true")
        XCTAssertEqual(value(context, "axRoleName({ role: 'AXButton' })"), "Button")
    }

    // MARK: - Formatting

    func testFormattingUsesOneClockAndReadableUnits() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "formatClock(new Date(2026, 0, 2, 3, 4, 5, 6), true)"), "03:04:05.006")
        XCTAssertEqual(value(context, "formatClock('not a date')"), "not a date", "a bad timestamp shows as it came")
        XCTAssertEqual(value(context, "formatDuration(84)"), "84 ms")
        XCTAssertEqual(value(context, "formatDuration(2310)"), "2.31 s")
        XCTAssertEqual(value(context, "formatBytes(2416)"), "2.4 kB")
        XCTAssertEqual(value(context, "formatOffset(83.4)"), "1:23")
        XCTAssertEqual(value(context, "plural(1, 'step', 'steps') + ' / ' + plural(2, 'step', 'steps')"), "1 step / 2 steps")
        XCTAssertEqual(value(context, "runtimeName('com.apple.CoreSimulator.SimRuntime.iOS-26-4')"), "iOS 26.4")
    }

    // MARK: - Theme

    // The theme button pins the other theme, and forgets the pin once the other
    // theme is the system's: two clicks always lead back to following the system.
    func testTheThemeButtonPinsTheOtherThemeUnlessTheSystemShowsIt() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "themeAfterToggle('dark', 'dark')"), "light")
        XCTAssertEqual(value(context, "themeAfterToggle('light', 'dark')"), "null", "back to the system's dark")
        XCTAssertEqual(value(context, "themeAfterToggle('light', 'light')"), "dark")
        XCTAssertEqual(value(context, "themeAfterToggle('dark', 'light')"), "null", "back to the system's light")
    }
}
