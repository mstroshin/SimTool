import Foundation

/// RFC 7233 single-range subset for serving mp4 to <video>. Malformed headers
/// are ignored (serve the whole file, 200); syntactically valid but
/// unsatisfiable ranges map to 416. Multi-range requests honor only the first
/// range — browsers never send them for media playback.
public enum HTTPRange {
    public struct ByteRange: Equatable, Sendable {
        public var offset: Int
        public var length: Int

        public init(offset: Int, length: Int) {
            self.offset = offset
            self.length = length
        }
    }

    public enum Outcome: Equatable, Sendable {
        case full
        case partial(ByteRange)
        case unsatisfiable
    }

    public static func parse(header: String?, fileSize: Int) -> Outcome {
        guard let header else { return .full }
        let trimmed = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("bytes=") else { return .full }
        guard let spec = trimmed.dropFirst("bytes=".count).split(separator: ",").first else { return .full }
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return .full }

        switch (Int(parts[0]), Int(parts[1])) {
        case let (first?, last?):
            guard first >= 0, first <= last else { return .full }
            guard first < fileSize else { return .unsatisfiable }
            return .partial(ByteRange(offset: first, length: min(last, fileSize - 1) - first + 1))
        case let (first?, nil):
            guard parts[1].isEmpty, first >= 0 else { return .full }
            guard first < fileSize else { return .unsatisfiable }
            return .partial(ByteRange(offset: first, length: fileSize - first))
        case let (nil, suffix?):
            guard parts[0].isEmpty, suffix >= 0 else { return .full }
            guard suffix > 0, fileSize > 0 else { return .unsatisfiable }
            let length = min(suffix, fileSize)
            return .partial(ByteRange(offset: fileSize - length, length: length))
        default:
            return .full
        }
    }
}
