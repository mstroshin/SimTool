import Foundation

public enum JSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let compactEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func data<T: Encodable>(_ value: T, pretty: Bool = true) throws -> Data {
        try (pretty ? encoder : compactEncoder).encode(value)
    }

    public static func string<T: Encodable>(_ value: T, pretty: Bool = true) throws -> String {
        let data = try data(value, pretty: pretty)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SimToolError("Encoded JSON is not UTF-8")
        }
        return string
    }
}

/// ISO 8601 with milliseconds for times that order events a few hundred
/// milliseconds apart; reads whole seconds too, so older files still decode.
enum PreciseTime {
    private static let precise: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSeconds = ISO8601DateFormatter()

    static func string(_ date: Date) -> String { precise.string(from: date) }

    static func date<Key: CodingKey>(_ text: String, key: Key, in container: KeyedDecodingContainer<Key>) throws -> Date {
        guard let date = precise.date(from: text) ?? wholeSeconds.date(from: text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Not an ISO 8601 time: \(text)")
        }
        return date
    }
}

/// Pretty-prints for humans at a terminal; emits compact JSON when stdout is
/// piped (agents and scripts), where indentation only inflates the payload.
public func printJSON<T: Encodable>(_ value: T, pretty: Bool = isatty(STDOUT_FILENO) != 0) throws {
    FileHandle.standardOutput.write(try JSON.data(value, pretty: pretty))
    FileHandle.standardOutput.write(Data("\n".utf8))
}
