import AVFoundation
import Foundation
import SimToolCore

/// `simctl io recordVideo` writes an mp4 whose media duration (the stts sum)
/// stops at the last screen change, while the movie duration covers the full
/// wall-clock span. Browsers trust the shorter media duration, so frames after
/// a long trailing static pause — e.g. the result of the final tap — sit
/// beyond the seekable range and step offsets point past the video's end.
/// A passthrough remux rebuilds the container from the samples and aligns
/// both durations without re-encoding.
public enum VideoDurationNormalizer {
    public static func normalize(file: URL) async throws {
        let asset = AVURLAsset(url: file)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw SimToolError("Cannot create a passthrough export session for \(file.lastPathComponent).")
        }
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(".normalizing-" + file.lastPathComponent)
        try? FileManager.default.removeItem(at: temp)
        export.outputURL = temp
        export.outputFileType = .mp4
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: temp)
            throw export.error ?? SimToolError("Passthrough export failed for \(file.lastPathComponent).")
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
    }

    /// The finalized movie duration in seconds, or nil when the file is
    /// missing/unreadable or reports a non-positive duration.
    public static func durationSeconds(of file: URL) async -> Double? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let duration = try? await AVURLAsset(url: file).load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
