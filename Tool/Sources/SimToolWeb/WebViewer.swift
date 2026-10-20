import Foundation

/// The browser viewer. Its HTML, CSS and JS are the files under `web/` in the
/// repository; `Scripts/sync-web-viewer.swift` embeds them as
/// `WebViewerAssets`, so the binary still serves the page on its own.
public enum WebViewer {
    /// Where the page loads its stylesheets and scripts from: `web/<path>` is
    /// served at `/assets/<path>`.
    public static let assetsPath = "/assets/"

    /// A file the page loads: its text and media type.
    public struct Asset: Sendable {
        public let contents: String
        public let contentType: String
    }

    /// `web/viewer.html` with `{{title}}` replaced by the page title and every
    /// `{{<path>}}` by what brings in `web/<path>`: for a stylesheet or a
    /// script, the tag that loads it from `assetsPath`, so nothing the page
    /// runs is inline; for anything else, the file itself.
    public static func html(title: String = "SimTool") -> String {
        let template = asset("viewer.html")
        var page = ""
        var rest = template[...]
        while let open = rest.range(of: "{{"), let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            page += rest[..<open.lowerBound]
            let name = String(rest[open.upperBound..<close.lowerBound])
            if name == "title" {
                page += escape(title)
            } else if let tag = loadingTag(for: name) {
                page += tag
            } else if let contents = WebViewerAssets.files[name] {
                page += contents
            } else {
                page += rest[open.lowerBound..<close.upperBound]
            }
            rest = rest[close.upperBound...]
        }
        page += rest
        return page
    }

    /// The paths under `web/` a server serves at `assetsPath`.
    public static var assetPaths: [String] {
        WebViewerAssets.files.keys.filter { contentType(of: $0) != nil }.sorted()
    }

    /// `web/<path>` as served at `assetsPath` + path, or nil when the page
    /// loads no such file — the HTML template among them.
    public static func servedAsset(_ path: String) -> Asset? {
        guard let contents = WebViewerAssets.files[path], let contentType = contentType(of: path) else { return nil }
        return Asset(contents: contents, contentType: contentType)
    }

    /// The live-touch channel, kept apart from the page script so it can be
    /// exercised on its own.
    static var touchScript: String { asset("js/touch.js") }

    /// The Mac keyboard bridge, kept apart from the page script so it can be
    /// exercised on its own.
    static var keyboardScript: String { asset("js/keyboard.js") }

    static func asset(_ path: String) -> String {
        guard let contents = WebViewerAssets.files[path] else {
            preconditionFailure("web/\(path) is not embedded; run Scripts/sync-web-viewer.swift")
        }
        return contents
    }

    private static func contentType(of path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "css": return "text/css; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "json": return "application/json"
        default: return nil
        }
    }

    private static func loadingTag(for path: String) -> String? {
        guard WebViewerAssets.files[path] != nil else { return nil }
        let url = escape(assetsPath + path)
        switch (path as NSString).pathExtension.lowercased() {
        case "css": return #"<link rel="stylesheet" href="\#(url)">"#
        case "js": return #"<script src="\#(url)"></script>"#
        default: return nil
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
