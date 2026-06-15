import Foundation

public enum AVCCEnvelope {
    public static let descriptionTag: UInt8 = 0x01
    public static let keyframeTag: UInt8 = 0x02
    public static let deltaTag: UInt8 = 0x03

    public static func description(avcc: Data) -> Data { wrap(tag: descriptionTag, payload: avcc) }
    public static func keyframe(avcc: Data) -> Data { wrap(tag: keyframeTag, payload: avcc) }
    public static func delta(avcc: Data) -> Data { wrap(tag: deltaTag, payload: avcc) }

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
