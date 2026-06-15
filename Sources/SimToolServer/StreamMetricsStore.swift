import Foundation
import SimToolCore
import SimToolStream

final class StreamMetricsStore: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = Date()
    private var capturedFrames = 0
    private var h264EncodedFrames = 0
    private var h264Keyframes = 0
    private var h264DeltaFrames = 0
    private var droppedH264Frames = 0
    private var sentAVCCEnvelopes = 0

    func recordCapturedFrame() {
        lock.lock(); capturedFrames += 1; lock.unlock()
    }

    func recordH264Encoded(kind: H264Encoder.Encoded.Kind, sent: Int) {
        lock.lock()
        h264EncodedFrames += 1
        switch kind {
        case .keyframe: h264Keyframes += 1
        case .delta: h264DeltaFrames += 1
        }
        sentAVCCEnvelopes += sent
        lock.unlock()
    }

    func recordAVCCDescription(sent: Int) {
        lock.lock(); sentAVCCEnvelopes += sent; lock.unlock()
    }

    func recordDroppedH264Frame() {
        lock.lock(); droppedH264Frames += 1; lock.unlock()
    }

    func snapshot(clients: StreamClientCounts) -> StreamMetricsPayload {
        lock.lock()
        defer { lock.unlock() }
        return StreamMetricsPayload(
            capturedFrames: capturedFrames,
            h264EncodedFrames: h264EncodedFrames,
            h264Keyframes: h264Keyframes,
            h264DeltaFrames: h264DeltaFrames,
            droppedH264Frames: droppedH264Frames,
            sentAVCCEnvelopes: sentAVCCEnvelopes,
            avccClients: clients.avcc,
            totalClients: clients.total,
            uptimeSeconds: Date().timeIntervalSince(startedAt)
        )
    }
}

struct StreamClientCounts: Equatable, Sendable {
    var avcc: Int
    var total: Int { avcc }
}
