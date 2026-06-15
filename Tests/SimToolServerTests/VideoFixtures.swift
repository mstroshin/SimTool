import AVFoundation
import Foundation

/// Builds small mp4 fixtures shaped like `simctl io recordVideo` output and
/// reads container durations back, so tests can reproduce the trailing-gap
/// duration mismatch without a simulator.
enum VideoFixtures {
    struct Durations {
        /// `mvhd` duration in seconds (wall-clock span of the recording).
        var movieSeconds: Double
        /// `mdhd` duration in seconds (what browsers report as the video length).
        var mediaSeconds: Double
        var mediaTimescale: UInt32
        /// File offset of the version-0 `mdhd` duration field, for patching.
        var mediaDurationFieldOffset: Int
        /// Total sample count from `stts`, to detect dropped frames.
        var sampleCount: Int
    }

    /// A short VFR clip: a burst of frames, then one last frame after a long
    /// static gap — the shape simctl produces when the screen changes once
    /// after a pause. Ends past the last frame so the movie spans ~5.1s.
    static func writeTrailingGapVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        for (index, seconds) in [0.0, 0.1, 0.2, 5.0].enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            let buffer = try makePixelBuffer(shade: UInt8(40 * (index + 1)))
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 5.1, preferredTimescale: 600))
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    /// Shrinks the `mdhd` duration in place, mimicking simctl leaving the
    /// trailing static gap out of the media timeline.
    static func patchMediaDuration(of url: URL, toSeconds seconds: Double) throws {
        var data = try Data(contentsOf: url)
        let durations = try parseDurations(of: data)
        let ticks = UInt32(seconds * Double(durations.mediaTimescale))
        for (index, byte) in withUnsafeBytes(of: ticks.bigEndian, Array.init).enumerated() {
            data[durations.mediaDurationFieldOffset + index] = byte
        }
        try data.write(to: url)
    }

    static func durations(of url: URL) throws -> Durations {
        try parseDurations(of: Data(contentsOf: url))
    }

    private static func parseDurations(of data: Data) throws -> Durations {
        var movie: (timescale: UInt32, duration: UInt64)?
        var media: (timescale: UInt32, duration: UInt64, fieldOffset: Int)?
        var sampleCount = 0

        func readUInt32(_ offset: Int) -> UInt32 {
            data[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func readUInt64(_ offset: Int) -> UInt64 {
            data[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
        }

        func scan(_ start: Int, _ end: Int) {
            var offset = start
            while offset + 8 <= end {
                var boxSize = Int(readUInt32(offset))
                var headerSize = 8
                let type = String(bytes: data[offset + 4..<offset + 8], encoding: .ascii) ?? ""
                if boxSize == 1 {
                    boxSize = Int(readUInt64(offset + 8))
                    headerSize = 16
                } else if boxSize == 0 {
                    boxSize = end - offset
                }
                guard boxSize >= headerSize, offset + boxSize <= end else { return }
                let body = offset + headerSize
                switch type {
                case "moov", "trak", "mdia", "minf", "stbl":
                    scan(body, offset + boxSize)
                case "stts":
                    let entries = Int(readUInt32(body + 4))
                    for index in 0..<entries {
                        sampleCount += Int(readUInt32(body + 8 + index * 8))
                    }
                case "mvhd", "mdhd":
                    let version = data[body]
                    let timescale = readUInt32(version == 0 ? body + 12 : body + 20)
                    let duration = version == 0 ? UInt64(readUInt32(body + 16)) : readUInt64(body + 24)
                    if type == "mvhd" {
                        movie = (timescale, duration)
                    } else if version == 0 {
                        media = (timescale, duration, body + 16)
                    }
                default:
                    break
                }
                offset += boxSize
            }
        }
        scan(0, data.count)

        guard let movie, let media else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Durations(
            movieSeconds: Double(movie.duration) / Double(movie.timescale),
            mediaSeconds: Double(media.duration) / Double(media.timescale),
            mediaTimescale: media.timescale,
            mediaDurationFieldOffset: media.fieldOffset,
            sampleCount: sampleCount
        )
    }

    private static func makePixelBuffer(shade: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(shade), CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
