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

/// Pretty-prints for humans at a terminal; emits compact JSON when stdout is
/// piped (agents and scripts), where indentation only inflates the payload.
public func printJSON<T: Encodable>(_ value: T, pretty: Bool = isatty(STDOUT_FILENO) != 0) throws {
    FileHandle.standardOutput.write(try JSON.data(value, pretty: pretty))
    FileHandle.standardOutput.write(Data("\n".utf8))
}
