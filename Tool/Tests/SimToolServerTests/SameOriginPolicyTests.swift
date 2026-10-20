import Foundation
import Swifter
import XCTest
@testable import SimToolServer

// What the policy decides from the headers alone — the browser names the page
// behind every request (Origin, Sec-Fetch-Site) and the host it believes it
// is talking to; a client that is not a browser names neither page.
final class SameOriginPolicyTests: XCTestCase {
    private let policy = SameOriginPolicy(serverHost: "127.0.0.1")

    func testClientsThatAreNotBrowsersGoThrough() {
        // The CLI, curl, the app-side loggers' URLSession: no Origin, no Sec-Fetch-*.
        XCTAssertNil(rejection(headers: ["host": "127.0.0.1:3200"]))
        XCTAssertNil(rejection(headers: [:]), "HTTP/1.0 without a Host")
    }

    func testTheViewerItselfGoesThrough() {
        XCTAssertNil(rejection(headers: ["host": "127.0.0.1:3200", "origin": "http://127.0.0.1:3200", "sec-fetch-site": "same-origin", "sec-fetch-mode": "cors"]))
        XCTAssertNil(rejection(headers: ["host": "localhost:3200", "origin": "http://localhost:3200"]))
        XCTAssertNil(rejection(headers: ["host": "[::1]:3200", "origin": "http://[::1]:3200"]))
        XCTAssertNil(rejection(headers: ["host": "127.0.0.1:3200", "sec-fetch-site": "none", "sec-fetch-mode": "navigate"]), "typed into the address bar")
    }

    func testAnotherOriginIsRefused() throws {
        for origin in ["https://evil.example", "http://127.0.0.1:5173", "http://localhost:3200", "https://127.0.0.1:3200", "null", "chrome-extension://abc"] {
            let reason = try XCTUnwrap(rejection(headers: ["host": "127.0.0.1:3200", "origin": origin]), origin)
            XCTAssertTrue(reason.contains("Origin \(origin)"), reason)
        }
        XCTAssertNotNil(rejection(headers: ["origin": "http://127.0.0.1:3200"]), "an Origin without a Host cannot be matched")
    }

    // A page on rebind.example, whose name now resolves to 127.0.0.1, is
    // same-origin with itself; its Host says which name it used.
    func testANameThatOnlyResolvesHereIsRefused() throws {
        for host in ["rebind.example:3200", "7f000001.rebind.network:3200", "127.0.0.1.nip.io:3200", "evil.example"] {
            let reason = try XCTUnwrap(rejection(headers: ["host": host, "origin": "http://\(host)"]), host)
            XCTAssertTrue(reason.hasPrefix("Host \(host)"), reason)
        }
        XCTAssertNotNil(rejection(headers: ["host": "127.0.0.1:3200 'unsafe-inline'"]), "nothing but a host and port")
        XCTAssertNotNil(rejection(headers: ["host": ":3200"]))
    }

    func testLoopbackNamesAddressesAndTheConfiguredHostAreThisServer() {
        for host in ["127.0.0.1:3200", "localhost:3200", "LocalHost", "[::1]:3200", "0.0.0.0:3200", "192.168.1.20:3200"] {
            XCTAssertTrue(policy.isAllowedHost(host), host)
        }
        // Names that only look local: resolved through DNS, they point wherever the resolver says.
        for host in ["app.localhost:3200", "localhost.:3200", "localhost.evil.example:3200"] {
            XCTAssertFalse(policy.isAllowedHost(host), host)
        }
        XCTAssertTrue(SameOriginPolicy(serverHost: "my-mac.local").isAllowedHost("my-mac.local:3200"))
        XCTAssertFalse(policy.isAllowedHost("my-mac.local:3200"))
    }

    // An <img>, <script> or <video> on another page sends no Origin.
    func testLoadsFromAnotherSiteAreRefused() {
        XCTAssertNotNil(rejection(headers: ["host": "127.0.0.1:3200", "sec-fetch-site": "cross-site", "sec-fetch-mode": "no-cors", "sec-fetch-dest": "image"]))
        // localhost:5173 and 127.0.0.1:3200 are different origins of one site.
        XCTAssertNotNil(rejection(headers: ["host": "127.0.0.1:3200", "sec-fetch-site": "same-site", "sec-fetch-mode": "no-cors", "sec-fetch-dest": "script"]))
        // A form posted from elsewhere is a navigation, but it carries its Origin.
        XCTAssertNotNil(rejection(method: "POST", path: "/api/v1/input", headers: ["host": "127.0.0.1:3200", "origin": "https://evil.example", "sec-fetch-site": "cross-site", "sec-fetch-mode": "navigate", "sec-fetch-dest": "document"]))
    }

    // A link elsewhere may open the viewer in a tab — and nothing else: not
    // the viewer in a frame (whose clicks the page above would steer), not an
    // API route in a window (`GET /api/v1/mocks?since=` records an ack).
    func testALinkFromAnotherSiteOpensOnlyTheViewerInATab() {
        let link = ["host": "127.0.0.1:3200", "sec-fetch-site": "cross-site", "sec-fetch-mode": "navigate", "sec-fetch-dest": "document"]
        XCTAssertNil(rejection(path: "/", headers: link))
        XCTAssertNotNil(rejection(path: "/", headers: link.merging(["sec-fetch-dest": "iframe"]) { $1 }))
        XCTAssertNotNil(rejection(path: "/", headers: link.merging(["sec-fetch-dest": "object"]) { $1 }))
        XCTAssertNotNil(rejection(path: "/api/v1/mocks", headers: link))
        XCTAssertNotNil(rejection(path: "/api/v1/screenshot", headers: link.merging(["sec-fetch-site": "same-site"]) { $1 }))
        XCTAssertNil(rejection(path: "/api/v1/mocks", headers: link.merging(["sec-fetch-site": "none"]) { $1 }), "typed or pasted into the address bar")
    }

    func testNoResponseLeavesWithACORSHeader() {
        let route = HttpResponse.raw(200, "OK", [
            "Content-Type": "text/event-stream",
            "Access-Control-Allow-Origin": "*",
            "access-control-allow-headers": "Content-Type",
        ], nil)
        let headers = policy.secured(route, host: "127.0.0.1:3200").headers()
        XCTAssertNil(headers.first { $0.key.lowercased().hasPrefix("access-control-") }, "\(headers)")
        XCTAssertEqual(headers["Content-Type"], "text/event-stream")
        XCTAssertEqual(headers["X-Content-Type-Options"], "nosniff")
        XCTAssertEqual(headers["Cross-Origin-Resource-Policy"], "same-origin")
        XCTAssertNil(headers["Content-Security-Policy"], "only pages carry a CSP")
    }

    func testAPageCarriesTheContentSecurityPolicyAndItsBody() throws {
        let secured = policy.secured(.ok(.html("<p>hi</p>")), host: "127.0.0.1:3200")
        let headers = secured.headers()
        let csp = try XCTUnwrap(headers["Content-Security-Policy"])
        for directive in ["default-src 'none'", "script-src 'self'", "style-src 'self'", "connect-src 'self' ws://127.0.0.1:3200", "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'"] {
            XCTAssertTrue(csp.contains(directive), "\(directive) missing from \(csp)")
        }
        XCTAssertFalse(csp.contains("unsafe-eval"))
        XCTAssertEqual(headers["X-Frame-Options"], "DENY", "browsers without frame-ancestors")
        XCTAssertFalse(policy.contentSecurityPolicy(host: "[::1]:3200").contains("ws://["), "an IPv6 host is no CSP source")
        XCTAssertFalse(csp.contains("script-src 'self' 'unsafe-inline'"))
        XCTAssertEqual(headers["Content-Type"], "text/html")
        XCTAssertEqual(headers["Content-Length"], "9")
        XCTAssertEqual(try body(of: secured), "<p>hi</p>")
    }

    func testTheWebSocketHandshakeIsLeftToSwifter() {
        guard case .switchProtocols = policy.secured(.switchProtocols(["Upgrade": "websocket"], { _ in }), host: nil) else {
            return XCTFail("the upgrade must stay an upgrade, or the socket is never handed over")
        }
    }

    func testARefusalSaysWhy() throws {
        let refusal = policy.forbidden("Origin https://evil.example is not this server's viewer")
        XCTAssertEqual(refusal.statusCode, 403)
        XCTAssertEqual(refusal.headers()["Content-Type"], "application/json")
        XCTAssertTrue(try body(of: refusal).contains("evil.example"))
    }

    private func rejection(method: String = "GET", path: String = "/config", headers: [String: String]) -> String? {
        policy.rejection(method: method, path: path, headers: headers)
    }

    private func body(of response: HttpResponse) throws -> String {
        guard case let .raw(_, _, _, writer) = response, let writer else { return "" }
        let sink = Sink()
        try writer(sink)
        return String(decoding: sink.data, as: UTF8.self)
    }

    private final class Sink: HttpResponseBodyWriter {
        var data = Data()
        func write(_ file: String.File) throws {}
        func write(_ data: [UInt8]) throws { self.data.append(contentsOf: data) }
        func write(_ data: ArraySlice<UInt8>) throws { self.data.append(contentsOf: data) }
        func write(_ data: NSData) throws { self.data.append(data as Data) }
        func write(_ data: Data) throws { self.data.append(data) }
    }
}
