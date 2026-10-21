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

    // MARK: - A call's detail

    func testAJSONBodyIsATreeOfKeysAndItems() throws {
        let context = try makeContext()
        context.evaluateScript(#"var tree = parseBodyTree('{"user":{"id":42,"vip":true,"note":null},"tags":["a","b"]}');"#)
        XCTAssertEqual(value(context, "tree.format + ' ' + tree.complete"), "json true")
        XCTAssertEqual(value(context, "tree.root.children.map(c => c.key + ':' + c.kind).join(',')"), "user:object,tags:array")
        XCTAssertEqual(value(context, "tree.root.children[0].children.map(c => c.key + '=' + c.type + ' ' + c.text).join(',')"), "id=num 42,vip=lit true,note=null null")
        XCTAssertEqual(value(context, "tree.root.children[1].children.map(c => c.key + '=' + c.text).join(',')"), #"0="a",1="b""#)
        XCTAssertEqual(value(context, "treeSize(tree.root)"), "8")
    }

    // gRPC loggers print messages in the protobuf text format, cut at the preview's length.
    func testAProtobufTextMessageIsATreeAndACutOneReadsAsFarAsItGoes() throws {
        let context = try makeContext()
        context.evaluateScript(#"""
        var whole = parseBodyTree('InvestAPI.PBPortfolioResponse:\nportfolio {\n  account_id: "acc \\"1\\""\n  total {\n    currency_code: "USD"\n    units: 5000\n  }\n  kind: KIND_CASH\n  open: true\n}\n');
        var cut = parseBodyTree('Payments.Response:\nresponse {\n  attributes {\n    key: "account"\n    value {\n      per_o');
        """#)
        XCTAssertEqual(value(context, "whole.format + ' ' + whole.complete + ' ' + whole.root.typeName"), "proto true InvestAPI.PBPortfolioResponse")
        let portfolio = "whole.root.children[0]"
        XCTAssertEqual(value(context, "\(portfolio).key + ' ' + \(portfolio).kind"), "portfolio message")
        XCTAssertEqual(value(context, "\(portfolio).children.map(c => c.key + '=' + (c.type || c.kind)).join(',')"), "account_id=str,total=message,kind=enum,open=lit")
        XCTAssertEqual(value(context, "\(portfolio).children[0].value"), #"acc "1""#)
        XCTAssertEqual(value(context, "\(portfolio).children[1].children[1].type"), "num")
        XCTAssertEqual(value(context, "cut.format + ' ' + cut.complete"), "proto false", "a cut preview is still a tree, and says it is cut")
        XCTAssertEqual(value(context, "cut.root.children[0].children[0].children[0].value"), "account")
    }

    func testTextThatIsNeitherStaysText() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "parseBodyTree('hello world, nothing structured').format"), "text")
        XCTAssertEqual(value(context, "parseBodyTree('{\"cut\": [1, 2').format"), "text", "a cut JSON preview is shown as text")
        XCTAssertEqual(value(context, "parseBodyTree('').format"), "empty")
    }

    func testTheQueryIsDecodedAndTheStatusNamed() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(queryParams('https://x.test/a?limit=20&cursor=abc%20def&flag&q=a+b#frag'))"),
                       #"[["limit","20"],["cursor","abc def"],["flag",""],["q","a b"]]"#)
        XCTAssertEqual(value(context, "queryParams('/svc.Service/Method').length"), "0")
        XCTAssertEqual(value(context, "httpStatusText(404) + '|' + httpStatusText(503) + '|' + httpStatusText(299)"), "Not Found|Service Unavailable|")
    }

    // A search reads headers and bodies too, and says where it found the term.
    func testASearchFindsATermInHeadersAndBodiesAndSaysWhere() throws {
        let context = try makeContext()
        context.evaluateScript(#"""
        var call = { protocol: 'grpc',
          request: { grpcService: 'pkg.Svc', grpcMethod: 'GetThing', path: '/pkg.Svc/GetThing', metadata: { 'x-trace': 'T-77' }, bodyPreview: 'Req:\nid: "abc"\n' },
          response: { grpcStatusCode: '5', metadata: { server: 'envoy' }, bodyPreview: 'Resp:\nowner: "ABC Corp"\n' } };
        var fields = networkSearchFields(call);
        """#)
        XCTAssertEqual(value(context, "networkHits(fields, 'abc').join(',')"), "request body,response body")
        XCTAssertEqual(value(context, "networkHits(fields, 't-77').join(',')"), "request headers")
        XCTAssertEqual(value(context, "networkHits(fields, 'not_found').join(',')"), "status", "a gRPC code is found by its name")
        XCTAssertEqual(value(context, "networkHits(fields, 'abc', 'header').length"), "0", "header: searches the headers alone")
        XCTAssertEqual(value(context, "networkHits(fields, 'getthing').join(',')"), "url,method")
        XCTAssertEqual(value(context, "matchesFilters(fields.url + fields.body, [], 'corp', fields, 'body')"), "true")
    }

    func testMarksAreEscapedAndCaseInsensitive() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "markHTML('<b>Token</b> token', 'TOKEN')"), "&lt;b&gt;<mark>Token</mark>&lt;/b&gt; <mark>token</mark>")
        XCTAssertEqual(value(context, "markHTML('a&b', '')"), "a&amp;b")
    }

    // MARK: - Table columns (Logs, Network)

    func testASavedLayoutIsMadeWholeAndKeptInBounds() throws {
        let context = try makeContext()
        context.evaluateScript("var describe = (l) => l.map(c => c.key + (c.hidden ? '-' : '') + (c.width ? c.width : '')).join(',');")
        XCTAssertEqual(value(context, "describe(columnLayout(LOG_COLUMNS, null))"),
                       "time86,level62,subsystem160,category-120,process-110,message", "by default category and process are off")
        // Unknown and repeated columns go, widths are bounded, a missing column comes back after the one it follows.
        let saved = #"[{"key":"message"},{"key":"bogus","width":10},{"key":"time","width":5},{"key":"level","width":9999,"hidden":true},{"key":"time","width":300}]"#
        XCTAssertEqual(value(context, "describe(columnLayout(LOG_COLUMNS, \(saved)))"),
                       "message,time60,level-640,subsystem160,category-120,process-110")
        XCTAssertEqual(value(context, "columnLayout(LOG_COLUMNS, [{ key: 'message', hidden: true }])[0].hidden"), "false", "the flexible column is never hidden")
        XCTAssertEqual(value(context, "columnLayout(LOG_COLUMNS, 'not a list').length"), "6")
        // A column a later viewer adds lands after its neighbour in an older saved order.
        XCTAssertEqual(value(context, "describe(columnLayout(NETWORK_COLUMNS, ['name', 'time', 'status', 'method', 'size', 'duration'].map(key => ({ key }))))"),
                       "name,time86,status118,method46,size62,duration64,wf90")
    }

    func testAMovedColumnStandsBeforeTheOneItWasDroppedOn() throws {
        let context = try makeContext()
        context.evaluateScript("var layout = columnLayout(LOG_COLUMNS, null); var keys = (l) => l.map(c => c.key).join(',');")
        XCTAssertEqual(value(context, "keys(moveColumn(layout, 'message', 1))"), "time,message,level,subsystem,category,process")
        XCTAssertEqual(value(context, "keys(moveColumn(layout, 'time', 3))"), "level,subsystem,time,category,process,message", "moving right counts the gap it leaves")
        XCTAssertEqual(value(context, "keys(moveColumn(layout, 'level', layout.length))"), "time,subsystem,category,process,message,level")
        XCTAssertEqual(value(context, "keys(moveColumn(layout, 'nope', 0))"), "time,level,subsystem,category,process,message")
    }

    func testTheRowsGridFollowsTheShownColumnsAndEachNarrowerStepDropsItsColumns() throws {
        let context = try makeContext()
        context.evaluateScript("var logs = moveColumn(columnLayout(LOG_COLUMNS, [{ key: 'subsystem', width: 200 }, { key: 'process', hidden: false }]), 'message', 0);")
        XCTAssertEqual(value(context, "gridTemplate(LOG_COLUMNS, logs, 0)"), "minmax(120px, 1fr) 86px 62px 200px 110px")
        XCTAssertEqual(value(context, "gridTemplate(LOG_COLUMNS, logs, 1)"), "minmax(120px, 1fr) 86px 62px")
        XCTAssertEqual(value(context, "shownColumns(LOG_COLUMNS, logs, 1).map(c => c.key).join(',')"), "message,time,level")
        context.evaluateScript("var net = moveColumn(columnLayout(NETWORK_COLUMNS, null), 'duration', 0);")
        XCTAssertEqual(value(context, "gridTemplate(NETWORK_COLUMNS, net, 0)"), "64px 86px 46px minmax(140px, 1fr) 118px 62px 90px")
        XCTAssertEqual(value(context, "gridTemplate(NETWORK_COLUMNS, net, 1)"), "64px 86px 46px minmax(140px, 1fr) 118px", "≤ 760 px: no size, no waterfall")
        XCTAssertEqual(value(context, "gridTemplate(NETWORK_COLUMNS, net, 2)"), "64px 86px minmax(140px, 1fr) 118px", "≤ 560 px: no method either")
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
        // The iPhone Duo's device-specific runtime: the OS version, not the model.
        XCTAssertEqual(value(context, "runtimeName('com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4')"), "iOS 27.2")
        XCTAssertEqual(value(context, "runtimeName('com.apple.CoreSimulator.SimRuntime.watchOS-11-0')"), "watchOS 11.0")
    }

    // MARK: - A screen's picture

    // The open inner panel of an iPhone Duo streams a portrait framebuffer
    // under a landscape picture: its frames are turned once their shape is
    // the panel's, and a cover frame still in flight is not.
    func testAFrameTurnsWithTheScreenItShows() throws {
        let context = try makeContext()
        context.evaluateScript("var inner = { id: 'primary-1', width: 2007, height: 2853, rotation: 90 };")
        XCTAssertEqual(value(context, "frameRotation(900, 1280, inner)"), "90", "the encoder scales, the shape stays")
        XCTAssertEqual(value(context, "frameRotation(880, 1280, inner)"), "0", "a cover frame (1398×2034) is not the inner panel's")
        XCTAssertEqual(value(context, "frameRotation(900, 1280, null)"), "0")
        XCTAssertEqual(value(context, "frameRotation(900, 1280, { width: 2007, height: 2853, rotation: -90 })"), "270")
    }

    // The canvas transform must put the framebuffer's bottom-left corner at
    // the top-left of a picture turned 90° clockwise.
    func testTheCanvasTurnPutsEachCornerWhereThePictureHasIt() throws {
        let context = try makeContext()
        context.evaluateScript("""
        function place(rotation, x, y) {
          var t = canvasTurn(rotation, 300, 200);
          return Math.round(t.a * x + t.c * y + t.e) + "," + Math.round(t.b * x + t.d * y + t.f);
        }
        """)
        // Drawn at (turn.width × turn.height) = (200 × 300) in frame space.
        XCTAssertEqual(value(context, "place(90, 0, 300)"), "0,0", "the frame's bottom-left lands top-left")
        XCTAssertEqual(value(context, "place(90, 0, 0)"), "300,0", "the frame's top-left lands top-right")
        XCTAssertEqual(value(context, "[canvasTurn(90, 300, 200).width, canvasTurn(90, 300, 200).height].join('x')"), "200x300")
        XCTAssertEqual(value(context, "place(180, 0, 0)"), "300,200")
        XCTAssertEqual(value(context, "place(270, 0, 0)"), "0,200")
        XCTAssertEqual(value(context, "place(0, 10, 20)"), "10,20")
    }

    // A click on the 3D device lands on the panel's framebuffer through the
    // projected quad of the leaf it hit, and goes out as a picture fraction.
    func testA3DClickLandsOnThePanelUnderIt() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var flat = { pieces: [[[0.1, 0.2], [0.5, 0.2], [0.5, 0.8], [0.1, 0.8], [0, 0.5, 1, 0.5]],
                              [[0.5, 0.2], [0.9, 0.2], [0.9, 0.8], [0.5, 0.8], [0, 0, 1, 0.5]]] };
        function at(x, y) { var p = pointOnDuoScreen(flat, x, y); return p ? p.x.toFixed(3) + "," + p.y.toFixed(3) : "none"; }
        """)
        XCTAssertEqual(value(context, "at(0.1, 0.2)"), "0.000,0.500", "the first leaf's top-left is its region's top-left")
        XCTAssertEqual(value(context, "at(0.3, 0.5)"), "0.500,0.750")
        XCTAssertEqual(value(context, "at(0.7, 0.5)"), "0.500,0.250")
        XCTAssertEqual(value(context, "at(0.05, 0.5)"), "none", "beside the screen touches nothing")
        XCTAssertEqual(value(context, "pointOnDuoScreen(null, 0.5, 0.5)"), "null")
        // The inverse of the server's turn (SimulatorDisplayRotation.framebufferRatio).
        XCTAssertEqual(value(context, "JSON.stringify(pictureRatio({ x: 0.496, y: 0.832 }, 90))"), #"{"x":0.16800000000000004,"y":0.496}"#)
        XCTAssertEqual(value(context, "JSON.stringify(pictureRatio({ x: 0.9, y: 0.25 }, 270))"), #"{"x":0.25,"y":0.09999999999999998}"#)
        XCTAssertEqual(value(context, "JSON.stringify(pictureRatio({ x: 0.75, y: 0.9 }, 180))"), #"{"x":0.25,"y":0.09999999999999998}"#)
        XCTAssertEqual(value(context, "JSON.stringify(pictureRatio({ x: 0.3, y: 0.4 }, 0))"), #"{"x":0.3,"y":0.4}"#)
        XCTAssertEqual(value(context, "cssColorHex('rgb(27, 29, 32)')"), "1b1d20")
        // A stage that changed shape asks for frames of its new shape; a pixel's worth does not.
        XCTAssertEqual(value(context, "stageReframes(0.8, 0.81)"), "false")
        XCTAssertEqual(value(context, "stageReframes(0.8, 1.1)"), "true")
        XCTAssertEqual(value(context, "stageReframes(0.8, 0.7)"), "true")
        XCTAssertEqual(value(context, "stageReframes(0, 1.1)"), "false", "no 3D frames asked for yet")
        XCTAssertEqual(value(context, "cssColorHex('transparent')"), "000000")
    }

    func testTheToolbarSaysHowTheDeviceIsFolded() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "foldReadout({ hingeDegrees: 130, pose: 'book', panel: 'inner' })"), "book · 130° · inner")
        XCTAssertEqual(value(context, "foldReadout({ hingeDegrees: 92.64, panel: 'inner' })"), "92.6° · inner")
        XCTAssertEqual(value(context, "foldReadout({ panel: 'cover' })"), "cover")
        XCTAssertEqual(value(context, "foldReadout(null)"), "")
    }

    func testTheScreensCornersComeFromItsDeviceTypeInProportion() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "screenRadius({ cornerRadii: [8, 59, 59, 8], points: { width: 466, height: 678 } }, 233)"), "4px 30px 30px 4px")
        XCTAssertEqual(value(context, "screenRadius({ points: { width: 466, height: 678 } }, 233)"), "", "no radii: the page's own heuristic")
        XCTAssertEqual(value(context, "screenRadius(null, 233)"), "")
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

// What drives the device, and what the activity feed draws and copies.
final class WebViewerActivityLogicTests: XCTestCase {
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

    func testARunningTestDrivesTheDeviceAndSaysWhichStepIsNext() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var steps = [{ id: 1, actor: 'test', kind: 'step', title: '✓ 2/5 tap “General”', at: '2026-10-20T12:00:00.000Z', status: 'done' }];
        var cli = { active: true, sessionId: 's-1', name: 'Settings flow', completedSteps: 0, totalSteps: 0 };
        """)
        XCTAssertEqual(value(context, "(d => d.actor + ' ' + d.key + ' ' + d.step.index + '/' + d.step.total)(deviceDriver(steps, cli, 0))"), "test test:s-1 3/5",
                       "a run started from the CLI has no counts: the last step says where it is")
        XCTAssertEqual(value(context, "deviceDriver(steps, { active: true, file: 'a.yml', completedSteps: 1, totalSteps: 4 }, 0).step.index"), "2")
    }

    func testAnAgentDrivesUntilItHasBeenQuietForHalfAMinute() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var t = Date.parse('2026-10-20T12:00:00.000Z');
        var at = (s) => new Date(t + s * 1000).toISOString();
        var feed = [
          { id: 1, actor: 'agent', kind: 'tap', title: 'Tap “Wi-Fi”', at: at(0), endedAt: at(0.1), status: 'done' },
          { id: 2, actor: 'agent', kind: 'tap', title: 'Tap “General”', at: at(60), endedAt: at(60.1), status: 'done' },
          { id: 3, actor: 'viewer', kind: 'button', title: 'Press Home', at: at(65), endedAt: at(65.2), status: 'done' },
          { id: 4, actor: 'agent', kind: 'scroll', title: 'Scroll up 300 pt', at: at(80), endedAt: at(80.8), status: 'done' }
        ];
        """)
        XCTAssertEqual(value(context, "(d => d.actor + ' ' + d.key + ' ' + d.title)(deviceDriver(feed, null, t + 90000))"), "agent agent:2 Scroll up 300 pt",
                       "one stretch starts after a quiet half minute; the viewer's own press does not count")
        XCTAssertEqual(value(context, "deviceDriver(feed, null, t + 111000)"), "null", "quiet for 30 s: nobody drives")
        XCTAssertEqual(value(context, "deviceDriver(feed.concat([{ id: 5, actor: 'agent', kind: 'launch', title: 'Launch', at: at(200), status: 'running' }]), null, t + 300000).key"), "agent:5",
                       "a running action drives however long it takes")
    }

    func testAGesturePlacesItselfOnTheScreenItWasPlayedOn() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "JSON.stringify(gestureRatios({ from: { x: 201, y: 437 }, to: { x: 201, y: 437 }, screen: { width: 402, height: 874 } }))"),
                       #"{"from":{"x":0.5,"y":0.5},"to":{"x":0.5,"y":0.5},"moved":false}"#)
        XCTAssertEqual(value(context, "gestureRatios({ from: { x: 0, y: 874 }, to: { x: 0, y: 0 } }, { width: 402, height: 874 }).moved"), "true",
                       "without the server's size the page's own is used")
        XCTAssertEqual(value(context, "gestureRatios({ from: { x: 1, y: 1 }, to: { x: 1, y: 1 } }, null)"), "null")
    }

    func testATouchCopiesAsTheCommandThatRepeatsIt() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "activityCommand({ kind: 'tap', gesture: { from: { x: 201.4, y: 339.6 }, to: { x: 201.4, y: 339.6 }, press: 0.06 } })"),
                       "simtool input tap --x 201 --y 340")
        XCTAssertEqual(value(context, "activityCommand({ kind: 'scroll', gesture: { from: { x: 201, y: 655 }, to: { x: 201, y: 345 }, press: 0 } })"),
                       "simtool input swipe --start-x 201 --start-y 655 --end-x 201 --end-y 345")
        XCTAssertEqual(value(context, "activityCommand({ kind: 'type', title: 'Type “a”' })"), "")
    }

    func testAgesReadInSecondsThenMinutes() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "[formatSince(400), formatSince(3200), formatSince(61000), formatSince(7300000)].join(' | ')"), "now | 3 s ago | 1 min ago | 2 h ago")
    }
}

// A recorded run reviewed step by step: which part of it a step covers.
final class WebViewerReviewLogicTests: XCTestCase {
    private func makeContext(file: StaticString = #filePath, line: UInt = #line) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("JS exception: \(exception?.toString() ?? "?")", file: file, line: line)
        }
        context.evaluateScript(WebViewer.asset("js/logic.js"))
        context.evaluateScript("""
        var session = { startedAt: '2026-10-20T21:40:30Z', endedAt: '2026-10-20T21:40:50.500Z', entries: [
          { kind: 'step', at: '2026-10-20T21:40:31.300Z', text: 'Launched com.example.app' },
          { kind: 'step', at: '2026-10-20T21:40:38.775Z', text: '✓ 1/3 Wait for label "General"' },
          { kind: 'log', at: '2026-10-20T21:40:39.000Z', logs: ['On screen:'] },
          { kind: 'step', at: '2026-10-20T21:40:39.743Z', text: '✓ 2/3 Tap label "General"' },
          { kind: 'step', at: '2026-10-20T21:40:44.459Z', text: '✓ 3/3 Wait for label "About"' }
        ] };
        """)
        return context
    }

    private func value(_ context: JSContext, _ expression: String) -> String {
        context.evaluateScript(expression)?.toString() ?? ""
    }

    func testEveryTimeTheEvidenceCarriesIsRead() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "Math.round(parseInstant('2026-10-20 18:40:11.226211-0300')) === Date.parse('2026-10-20T21:40:11.226Z')"), "true", "OSLog's local time with an offset")
        XCTAssertEqual(value(context, "parseInstant(1792532411.5) === 1792532411500"), "true", "state's epoch seconds")
        XCTAssertEqual(value(context, "parseInstant('2026-10-20T21:40:39.743Z') === Date.parse('2026-10-20T21:40:39.743Z')"), "true")
        XCTAssertEqual(value(context, "isNaN(parseInstant('later'))"), "true")
    }

    func testAStepCoversFromItsActionToTheNextStepsAction() throws {
        let context = try makeContext()
        XCTAssertEqual(value(context, "stepWindows(session).map(w => w.index + ':' + (w.to - w.from)).join(' ')"), "0:7475 1:968 3:4716 4:6041",
                       "a log entry is not a step; the last step runs to the end of the run")
        XCTAssertEqual(value(context, "(w => w.step + ' ' + w.text)(reviewWindow(session, 3, 'step'))"), #"3 ✓ 2/3 Tap label "General""#)
        XCTAssertEqual(value(context, "(w => w.step + ' ' + (w.to - w.from))(reviewWindow(session, -1, 'step'))"), "0 1300", "before the first step")
        XCTAssertEqual(value(context, "(w => (w.to - w.from) + ' ' + w.step)(reviewWindow(session, 3, 'run'))"), "20500 null")
    }

    func testARequestBelongsToTheStepItStartedIn() throws {
        let context = try makeContext()
        context.evaluateScript("var tap = reviewWindow(session, 3, 'step');")
        // Finished during the next step, started during the tap's.
        XCTAssertEqual(value(context, "inWindow('network', { timestamp: '2026-10-20T21:40:44.600Z', durationMilliseconds: 4000 }, tap)"), "true")
        XCTAssertEqual(value(context, "inWindow('network', { timestamp: '2026-10-20T21:40:39.800Z', durationMilliseconds: 900 }, tap)"), "false", "it started before the tap")
        XCTAssertEqual(value(context, "inWindow('logs', { timestamp: '2026-10-20 18:40:40.000000-0300' }, tap)"), "true")
        XCTAssertEqual(value(context, "inWindow('state', { timestamp: Date.parse('2026-10-20T21:40:44.600Z') / 1000 }, tap)"), "false", "the window ends where the next step begins")
    }

    func testStateIsWhatTheModelsHeldAtTheEndOfTheStep() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var t = (s) => Date.parse('2026-10-20T21:40:00Z') / 1000 + s;
        var events = [
          { modelId: 'Cart#1', seq: 1, timestamp: t(32), snapshot: { items: 0 } },
          { modelId: 'Cart#1', seq: 2, timestamp: t(40), snapshot: { items: 1 } },
          { modelId: 'Cart#1', seq: 3, timestamp: t(46), snapshot: { items: 2 } }
        ];
        var folded = foldStateEvents(events, reviewWindow(session, 3, 'step'));
        """)
        XCTAssertEqual(value(context, "folded.latest['Cart#1'].snapshot.items"), "1", "the change after the step is not yet there")
        XCTAssertEqual(value(context, "folded.changes.map(c => c.diffs.map(d => d.path + ' ' + d.before + '→' + d.after).join()).join('|')"), "items 0→1")
        XCTAssertEqual(value(context, "JSON.stringify(folded.lastChange)"), #"{"Cart#1":["items"]}"#)
    }
}
