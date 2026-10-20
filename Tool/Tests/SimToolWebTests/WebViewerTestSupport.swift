import Foundation
@testable import SimToolWeb

extension WebViewer {
    /// The files the page loads from `assetsPath`, as paths under `web/`, in
    /// the order they appear in it.
    static var pageAssets: [String] {
        let page = html()
        let pattern = try! NSRegularExpression(pattern: #"(?:href|src)="\#(NSRegularExpression.escapedPattern(for: assetsPath))([^"]+)""#)
        return pattern.matches(in: page, range: NSRange(page.startIndex..., in: page))
            .map { String(page[Range($0.range(at: 1), in: page)!]) }
    }

    /// The scripts the page loads, in the order it runs them.
    static var pageScripts: [String] {
        pageAssets.filter { $0.hasSuffix(".js") }
    }

    /// The page and every file it loads, as one text: what the browser ends
    /// up running, for tests that look for what the viewer does.
    static var pageWithAssets: String {
        ([html()] + pageAssets.map(asset)).joined(separator: "\n")
    }
}
