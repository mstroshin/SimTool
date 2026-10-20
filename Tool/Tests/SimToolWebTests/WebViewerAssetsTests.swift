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

    // Nothing the page runs or styles itself with is inline, so it works
    // under a policy that allows only the server's own files.
    func testThePageLoadsItsStylesAndScriptsAsFiles() throws {
        let page = WebViewer.html()
        XCTAssertTrue(page.contains(#"<link rel="stylesheet" href="/assets/viewer.css">"#))
        XCTAssertEqual(WebViewer.pageScripts.first, "js/touch.js")
        XCTAssertEqual(WebViewer.pageScripts.last, "js/main.js", "main.js starts the viewer, after everything it calls")
        let inline = try NSRegularExpression(pattern: #"<script(?![^>]*\bsrc=)[^>]*>|<style\b"#)
        XCTAssertEqual(inline.numberOfMatches(in: page, range: NSRange(page.startIndex..., in: page)), 0, "an inline <script> or <style> in the page")
        for path in WebViewer.pageAssets {
            XCTAssertNotNil(WebViewer.servedAsset(path), "the page loads /assets/\(path), which is not served")
        }
    }

    // Handlers in markup — onclick="…", javascript: links — are inline script too.
    func testNoMarkupCarriesScript() throws {
        let handler = try NSRegularExpression(pattern: #"\son[a-z]+\s*=\s*["']|javascript:"#, options: .caseInsensitive)
        for (path, contents) in WebViewerAssets.files where path.hasSuffix(".html") || path.hasSuffix(".js") {
            let matches = handler.matches(in: contents, range: NSRange(contents.startIndex..., in: contents))
                .map { String(contents[Range($0.range, in: contents)!]) }
            XCTAssertEqual(matches, [], "web/\(path)")
        }
    }

    func testTheServerServesStylesAndScriptsButNotTheTemplate() throws {
        XCTAssertEqual(WebViewer.servedAsset("viewer.css")?.contentType, "text/css; charset=utf-8")
        XCTAssertEqual(WebViewer.servedAsset("js/main.js")?.contentType, "text/javascript; charset=utf-8")
        XCTAssertEqual(WebViewer.servedAsset("js/main.js")?.contents, WebViewerAssets.files["js/main.js"])
        XCTAssertNil(WebViewer.servedAsset("viewer.html"), "the template is served only filled in, at /")
        XCTAssertNil(WebViewer.servedAsset("js/missing.js"))
        XCTAssertEqual(Set(WebViewer.assetPaths), Set(WebViewerAssets.files.keys.filter { $0 != "viewer.html" }))
    }

    func testTheTitleIsEscaped() {
        XCTAssertTrue(WebViewer.html(title: "<b>&\"").contains("<title>&lt;b&gt;&amp;&quot;</title>"))
    }
}
