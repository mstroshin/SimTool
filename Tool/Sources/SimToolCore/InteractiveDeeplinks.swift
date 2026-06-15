import Foundation

/// One row in the interactive deeplink prompt: a configured deeplink or the
/// trailing Exit entry. Kept in SimToolCore so the option-list shape is unit
/// testable without driving a terminal prompt.
public enum InteractiveDeeplinkChoice: Equatable, Sendable, CustomStringConvertible {
    case deeplink(ProjectConfig.Deeplink)
    case exit

    public var description: String {
        switch self {
        case .deeplink(let link): return link.description
        case .exit: return "Exit"
        }
    }

    /// Prompt options for a config: deeplinks in config order, Exit last.
    public static func choices(for config: ProjectConfig) -> [InteractiveDeeplinkChoice] {
        config.deeplinks.map { .deeplink($0) } + [.exit]
    }
}
