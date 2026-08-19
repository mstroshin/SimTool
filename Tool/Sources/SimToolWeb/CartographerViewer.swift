import Foundation

/// The Картограф tab: a React Flow canvas over the exploration graph the
/// server's ExploreController builds. Served as a self-contained page; React
/// and React Flow load as ES modules from esm.sh, so there is no build step —
/// the price is that the tab needs internet access on first open.
///
/// Markup, styles and script live in Resources/cartographer.{html,css,js}.
public enum CartographerViewer {
    public static func html() -> String {
        WebAsset.page(PackageResources.cartographer_html, [
            (name: "css", value: WebAsset.text(PackageResources.cartographer_css)),
            (name: "js", value: WebAsset.text(PackageResources.cartographer_js)),
        ])
    }
}
