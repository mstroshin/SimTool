import Foundation
import XCTest
import SimToolCore
import SimToolServer

// The page at / loads its stylesheets and scripts from /assets/; every one it
// names has to be there, with a type the browser will run.
final class ViewerRouteTests: XCTestCase {
    func testEveryFileThePageLoadsIsServed() async throws {
        let port = try freeLoopbackPort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"

        let (pageData, pageResponse) = try await URLSession.shared.data(from: URL(string: base + "/")!)
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        let page = String(decoding: pageData, as: UTF8.self)
        let reference = try NSRegularExpression(pattern: #"(?:href|src)="(/assets/[^"]+)""#)
        let paths = reference.matches(in: page, range: NSRange(page.startIndex..., in: page)).map { String(page[Range($0.range(at: 1), in: page)!]) }
        XCTAssertTrue(paths.contains("/assets/viewer.css"))
        XCTAssertTrue(paths.contains("/assets/js/main.js"))

        for path in paths {
            let (data, response) = try await URLSession.shared.data(from: URL(string: base + path)!)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200, path)
            XCTAssertFalse(data.isEmpty, path)
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            XCTAssertTrue(type.hasPrefix(path.hasSuffix(".css") ? "text/css" : "text/javascript"), "\(path) is \(type)")
        }

        let (_, template) = try await URLSession.shared.data(from: URL(string: base + "/assets/viewer.html")!)
        XCTAssertEqual((template as? HTTPURLResponse)?.statusCode, 404, "the template is served only filled in, at /")
    }
}
