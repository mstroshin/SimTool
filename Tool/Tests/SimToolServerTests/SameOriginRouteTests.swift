import Foundation
import XCTest
import SimToolCore
import SimToolNetworkLogger
import SimToolServer
import SimToolStateLogger

// The server as a browser meets it: a page on another origin can neither read
// an answer nor make the server act or open the input socket, while the
// viewer and the clients that are not browsers — the CLI, the app-side
// loggers — keep working.
final class SameOriginRouteTests: XCTestCase {
    private var server: StreamServer!
    private var port: UInt16 = 0
    private var own: String { "http://127.0.0.1:\(port)" }

    override func setUpWithError() throws {
        port = try freeLoopbackPort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
    }

    override func tearDown() {
        server.stop()
    }

    func testAnotherOriginCannotReadAnAnswer() throws {
        for path in ["/config", "/api/v1/network/events", "/api/v1/logs/capture", "/api/v1/state/events", "/api/v1/tests"] {
            let answer = try rawHTTP(port: port, path, headers: ["Origin": "https://evil.example", "Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "cors"])
            XCTAssertEqual(answer.status, 403, path)
            XCTAssertNil(answer.headers["access-control-allow-origin"], path)
            XCTAssertTrue(answer.body.contains("evil.example"), "the refusal says why: \(answer.body)")
        }
        // Nor ask first: the preflight is refused, with no CORS header to allow anything.
        let preflight = try rawHTTP(port: port, "OPTIONS", "/api/v1/input", headers: [
            "Origin": "https://evil.example", "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "content-type",
        ])
        XCTAssertEqual(preflight.status, 403)
        XCTAssertNil(preflight.headers["access-control-allow-origin"])
    }

    // A "simple" POST needs no preflight: without the server's check, any page
    // could tap, add a mock or delete a run blind.
    func testAnotherOriginCannotMakeTheServerAct() throws {
        let tap = try rawHTTP(port: port, "POST", "/api/v1/input", headers: ["Origin": "https://evil.example", "Content-Type": "text/plain"], body: #"{"action":"tap","x":10,"y":10}"#)
        XCTAssertEqual(tap.status, 403)
        XCTAssertTrue(tap.body.contains("Origin https://evil.example"), tap.body)
        let draft = String(decoding: try JSONEncoder().encode(MockRuleDraft(match: MockMatch(method: "*/GetSettings"), response: MockResponse(kind: .error))), as: UTF8.self)
        let mock = try rawHTTP(port: port, "POST", "/api/v1/mocks", headers: ["Origin": "http://localhost:5173", "Content-Type": "text/plain"], body: draft)
        XCTAssertEqual(mock.status, 403)
        let mocks = try rawHTTP(port: port, "/api/v1/mocks")
        XCTAssertEqual(mocks.status, 200)
        XCTAssertFalse(mocks.body.contains("GetSettings"), "the refused mock must not exist: \(mocks.body)")
        // The same draft from a client that is not a browser is taken.
        XCTAssertEqual(try rawHTTP(port: port, "POST", "/api/v1/mocks", headers: ["Content-Type": "application/json"], body: draft).status, 200)
        // An <img> or <video> pointed here sends no Origin, only Sec-Fetch-Site.
        let embed = try rawHTTP(port: port, "/api/v1/screenshot", headers: ["Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "no-cors", "Sec-Fetch-Dest": "image"])
        XCTAssertEqual(embed.status, 403)
    }

    // A link may open the viewer in a tab. Framed, its clicks would be the
    // page's to steer; opened on an API route, a GET still does something
    // (a mock poll records an ack).
    func testAnotherSiteCanLinkToTheViewerButNotFrameItOrOpenTheAPI() throws {
        let link = ["Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document"]
        let tab = try rawHTTP(port: port, "/", headers: link)
        XCTAssertEqual(tab.status, 200)
        XCTAssertEqual(tab.headers["x-frame-options"], "DENY")
        XCTAssertTrue(tab.headers["content-security-policy"]?.contains("frame-ancestors 'none'") == true)

        let frame = try rawHTTP(port: port, "/", headers: link.merging(["Sec-Fetch-Dest": "iframe"]) { $1 })
        XCTAssertEqual(frame.status, 403)

        let poll = try rawHTTP(port: port, "/api/v1/mocks?since=999999", headers: link)
        XCTAssertEqual(poll.status, 403)
        let ack = try rawHTTP(port: port, "/api/v1/mocks/ack").body
        XCTAssertFalse(ack.contains("acknowledged"), "the refused poll must not have recorded an ack: \(ack)")
    }

    func testTheInputSocketOpensOnlyForTheViewer() throws {
        func upgrade(_ extra: [String: String]) throws -> Int {
            try rawHTTP(port: port, "/api/v1/input/stream", headers: [
                "Upgrade": "websocket", "Connection": "Upgrade",
                "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==", "Sec-WebSocket-Version": "13",
            ].merging(extra) { $1 }).status
        }
        XCTAssertEqual(try upgrade(["Origin": "https://evil.example"]), 403)
        XCTAssertEqual(try upgrade(["Origin": "http://127.0.0.1:1"]), 403, "another port is another origin")
        XCTAssertEqual(try upgrade(["Origin": own]), 101, "the viewer's own page")
        XCTAssertEqual(try upgrade([:]), 101, "a client that is not a browser sends no Origin")
    }

    // DNS rebinding: a page on rebind.example, whose name now resolves to
    // 127.0.0.1, is same-origin with itself — only Host gives it away.
    func testANameThatResolvesHereIsNotThisServer() throws {
        let host = "rebind.example:\(port)"
        let page = try rawHTTP(port: port, "/", headers: ["Host": host])
        XCTAssertEqual(page.status, 403)
        let events = try rawHTTP(port: port, "/api/v1/network/events", headers: ["Host": host, "Origin": "http://\(host)"])
        XCTAssertEqual(events.status, 403)
        XCTAssertTrue(events.body.contains("rebind.example"), events.body)
        XCTAssertEqual(try rawHTTP(port: port, "/", headers: ["Host": "localhost:\(port)"]).status, 200)
    }

    func testTheViewerKeepsWorking() throws {
        let page = try rawHTTP(port: port, "/", headers: ["Sec-Fetch-Site": "none", "Sec-Fetch-Mode": "navigate"])
        XCTAssertEqual(page.status, 200)
        let csp = try XCTUnwrap(page.headers["content-security-policy"])
        XCTAssertTrue(csp.contains("script-src 'self'"), csp)
        XCTAssertTrue(csp.contains("connect-src 'self' ws://127.0.0.1:\(port)"), csp)
        XCTAssertEqual(page.headers["x-content-type-options"], "nosniff")
        XCTAssertTrue(page.body.contains(#"<script src="/assets/js/main.js"></script>"#))

        let script = try rawHTTP(port: port, "/assets/js/main.js", headers: ["Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "no-cors", "Sec-Fetch-Dest": "script"])
        XCTAssertEqual(script.status, 200)
        XCTAssertEqual(script.headers["cross-origin-resource-policy"], "same-origin")

        let config = try rawHTTP(port: port, "/config", headers: ["Origin": own, "Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "cors"])
        XCTAssertEqual(config.status, 200)
        XCTAssertTrue(config.body.contains(#""udid":"TEST-UDID""#))
        XCTAssertNil(config.headers["access-control-allow-origin"], "same-origin needs no CORS header")

        let action = try rawHTTP(port: port, "POST", "/api/v1/input", headers: ["Origin": own, "Content-Type": "application/json"], body: #"{"action":"paste","text":""}"#)
        XCTAssertEqual(action.status, 400, "the viewer's POST reaches its route")
        XCTAssertTrue(action.body.contains("Paste input requires text"), action.body)

        let unknown = try rawHTTP(port: port, "/nothing-here")
        XCTAssertEqual(unknown.status, 404)
        XCTAssertEqual(unknown.headers["x-content-type-options"], "nosniff", "Swifter's own answers go through the policy too")
    }

    // The loggers post from the simulator over URLSession: no Origin, no
    // CORS. These are the transports an app links, pointed at this server.
    func testTheAppSideLoggersKeepWorking() async throws {
        let serverURL = URL(string: own)!
        await NetworkLoggerServerSink(serverURL: serverURL).record([NetworkLoggerEvent(
            id: "evt-1",
            timestamp: "2026-10-20T12:00:00.000Z",
            appBundleID: "com.example.app",
            networkProtocol: .http,
            durationMilliseconds: 1,
            request: NetworkLoggerRequest(method: "GET", url: "https://api.example.com/v1/items"),
            response: NetworkLoggerResponse(statusCode: 200)
        )])
        await StateLoggerServerSink(serverURL: serverURL).record([StateLoggerEvent(
            modelId: "Cart#0", name: "Cart", seq: 0, timestamp: 1_760_961_600, snapshot: .object(["items": .number(1)])
        )])
        XCTAssertTrue(try rawHTTP(port: port, "/api/v1/network/events").body.contains("evt-1"), "the network logger's batch arrived")
        XCTAssertTrue(try rawHTTP(port: port, "/api/v1/state/events").body.contains("Cart#0"), "the state logger's batch arrived")

        let draft = String(decoding: try JSONEncoder().encode(MockRuleDraft(match: MockMatch(method: "*/GetSettings"), response: MockResponse(kind: .error))), as: UTF8.self)
        XCTAssertEqual(try rawHTTP(port: port, "POST", "/api/v1/mocks", headers: ["Content-Type": "application/json"], body: draft).status, 200)
        let store = MockStore()
        await MockRulePoller(serverURL: serverURL, store: store).refresh()
        XCTAssertNotNil(store.decision(fullMethod: "/shop.v1.Settings/GetSettings", headers: [:], requestJSON: nil), "the app's mock poller sees the rule")
    }
}
