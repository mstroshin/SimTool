@testable import SimToolWeb
import XCTest

final class WebViewerAssetsTests: XCTestCase {
    // `web/` holds the copies you edit by hand; the literals are what ships.
    // Drift means the binary serves a stale page — regenerate with
    // `Scripts/sync-web-viewer.swift`.
    func testEveryEmbeddedFileMatchesItsRepositoryCopy() throws {
        let webRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SimToolWebTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // Tool/
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("web", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: webRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw XCTSkip("no web/ at \(webRoot.path) (building outside a checkout)")
        }
        var authored: [String: String] = [:]
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let path = String(url.standardizedFileURL.path.dropFirst(webRoot.standardizedFileURL.path.count + 1))
            var contents = try String(contentsOf: url, encoding: .utf8)
            if contents.hasSuffix("\n") { contents.removeLast() }
            authored[path] = contents
        }
        XCTAssertEqual(Set(authored.keys), Set(WebViewerAssets.files.keys), "run Scripts/sync-web-viewer.swift")
        for (path, contents) in authored {
            XCTAssertEqual(contents, WebViewerAssets.files[path], "run Scripts/sync-web-viewer.swift for web/\(path)")
        }
    }

    func testThePageNamesOnlyFilesThatAreEmbedded() {
        let page = WebViewer.html()
        XCTAssertFalse(page.contains("{{"), "a {{marker}} in web/viewer.html names no file under web/")
    }

    func testTheTitleIsEscaped() {
        XCTAssertTrue(WebViewer.html(title: "<b>&\"").contains("<title>&lt;b&gt;&amp;&quot;</title>"))
    }
}
