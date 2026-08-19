import Foundation

/// The stream viewer page. Markup, styles and script live in
/// Resources/viewer.{html,css,js}; only the window title is substituted here.
public enum WebViewer {
    public static func html(title: String = "SimTool") -> String {
        WebAsset.page(PackageResources.viewer_html, [
            (name: "title", value: escape(title)),
            (name: "css", value: WebAsset.text(PackageResources.viewer_css)),
            (name: "js", value: WebAsset.text(PackageResources.viewer_js)),
        ])
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
