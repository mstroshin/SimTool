import Foundation

public struct NetworkLoggerRedactionConfiguration: Equatable, Sendable {
    public static let defaultSensitiveKeys: Set<String> = [
        "authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "api-key",
        "apikey",
        "proxy-authorization",
    ]

    public var sensitiveKeys: Set<String>
    public var replacement: String

    public init(
        sensitiveKeys: Set<String> = Self.defaultSensitiveKeys,
        replacement: String = "<redacted>"
    ) {
        self.sensitiveKeys = sensitiveKeys
        self.replacement = replacement
    }
}

public enum NetworkLoggerRedactor {
    public static func isSensitive(_ key: String, sensitiveKeys: Set<String> = NetworkLoggerRedactionConfiguration.defaultSensitiveKeys) -> Bool {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sensitiveKeys.contains(normalized)
            || normalized.contains("token")
            || normalized.contains("secret")
            || normalized.contains("api-key")
            || normalized.contains("apikey")
    }

    public static func redacted(
        _ values: [String: String],
        configuration: NetworkLoggerRedactionConfiguration = NetworkLoggerRedactionConfiguration()
    ) -> [String: String] {
        values.reduce(into: [:]) { result, pair in
            result[pair.key] = isSensitive(pair.key, sensitiveKeys: configuration.sensitiveKeys)
                ? configuration.replacement
                : pair.value
        }
    }

    public static func preview(data: Data?, maxBytes: Int) -> String? {
        guard let data, maxBytes > 0 else { return nil }
        let bounded = data.prefix(maxBytes)
        if let string = String(data: bounded, encoding: .utf8) {
            return string
        }
        return Data(bounded).base64EncodedString()
    }
}
