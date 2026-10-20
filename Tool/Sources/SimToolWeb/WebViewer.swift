import Foundation

/// The browser viewer. Its HTML, CSS and JS are the files under `web/` in the
/// repository; `Scripts/sync-web-viewer.swift` embeds them as
/// `WebViewerAssets`, so the binary still serves the page on its own.
public enum WebViewer {
    /// `web/viewer.html` with `{{title}}` replaced by the page title and every
    /// `{{<path>}}` by the file at `web/<path>`.
    public static func html(title: String = "SimTool") -> String {
        let template = asset("viewer.html")
        var page = ""
        var rest = template[...]
        while let open = rest.range(of: "{{"), let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            page += rest[..<open.lowerBound]
            let name = String(rest[open.upperBound..<close.lowerBound])
            if name == "title" {
                page += escape(title)
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

    /// The live-touch channel, kept apart from the page script so it can be
    /// exercised on its own.
    static var touchScript: String { asset("touch.js") }

    /// The Mac keyboard bridge, kept apart from the page script so it can be
    /// exercised on its own.
    static var keyboardScript: String { asset("keyboard.js") }

    static func asset(_ path: String) -> String {
        guard let contents = WebViewerAssets.files[path] else {
            preconditionFailure("web/\(path) is not embedded; run Scripts/sync-web-viewer.swift")
        }
        return contents
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
