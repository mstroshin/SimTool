import Foundation

/// The web pages this module serves are authored as real .html/.css/.js files
/// under Resources/, so an editor treats them as web sources instead of Swift
/// string literals. SwiftPM embeds their bytes into the binary (`.embedInCode`)
/// rather than into a resource bundle: a release ships the bare `simtool`
/// executable, and a `Bundle.module` bundle would not travel with it.
enum WebAsset {
    static func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Fills the `{{name}}` placeholders of an embedded page template.
    static func page(_ template: [UInt8], _ substitutions: [(name: String, value: String)]) -> String {
        substitutions.reduce(text(template)) { page, substitution in
            page.replacingOccurrences(of: "{{\(substitution.name)}}", with: substitution.value)
        }
    }
}
