import Foundation

public enum AVCCEnvelope {
    public static let descriptionTag: UInt8 = 0x01
    public static let keyframeTag: UInt8 = 0x02
    public static let deltaTag: UInt8 = 0x03
    /// The 3D preview's frame map: where each panel's picture lands on the
    /// frame that follows (JSON, `Duo3DProjection`).
    public static let projectionTag: UInt8 = 0x04

    public static func description(avcc: Data) -> Data { wrap(tag: descriptionTag, payload: avcc) }
    public static func keyframe(avcc: Data) -> Data { wrap(tag: keyframeTag, payload: avcc) }
    public static func delta(avcc: Data) -> Data { wrap(tag: deltaTag, payload: avcc) }
    public static func projection(json: Data) -> Data { wrap(tag: projectionTag, payload: json) }

    private static func wrap(tag: UInt8, payload: Data) -> Data {
        let length = UInt32(payload.count + 1)
        var out = Data(capacity: payload.count + 5)
        out.append(UInt8((length >> 24) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(tag)
        out.append(payload)
        return out
    }
}

/// Splits a byte stream back into envelopes, whatever sizes it arrives in.
public struct AVCCEnvelopeReader {
    public struct Envelope: Equatable, Sendable {
        public var tag: UInt8
        public var payload: Data
        /// The envelope as it came, length and tag included.
        public var bytes: Data
    }

    private var buffer = Data()

    public init() {}

    public mutating func push(_ data: Data) -> [Envelope] {
        buffer.append(data)
        var envelopes: [Envelope] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 5 {
            let length = buffer[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1 else { offset += 4; continue }
            guard buffer.endIndex - offset - 4 >= length else { break }
            let start = offset + 4
            envelopes.append(Envelope(tag: buffer[start], payload: Data(buffer[(start + 1)..<(start + length)]), bytes: Data(buffer[offset..<(start + length)])))
            offset = start + length
        }
        buffer = Data(buffer[offset...])
        return envelopes
    }
}
