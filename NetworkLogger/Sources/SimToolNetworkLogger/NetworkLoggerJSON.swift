import Foundation

public enum NetworkLoggerJSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder = JSONDecoder()

    public static func data<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        try (pretty ? prettyEncoder : encoder).encode(value)
    }

    public static func string<T: Encodable>(_ value: T, pretty: Bool = false) throws -> String {
        let data = try data(value, pretty: pretty)
        return String(decoding: data, as: UTF8.self)
    }
}

public enum NetworkLoggerTimestamp {
    public static func now() -> String { string(from: Date()) }

    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
