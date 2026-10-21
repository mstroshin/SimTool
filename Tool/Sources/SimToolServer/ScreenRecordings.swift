import AVFoundation
import CoreImage
import Foundation
import SimToolCore

/// A screen recording someone started from the viewer: recording, being
/// saved, ready to download, or failed with the reason.
public struct ScreenRecording: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case recording, saving, ready, failed }

    public var id: String
    public var state: State
    public var startedAt: Date
    public var endedAt: Date?
    /// The screen recorded: a foldable's lit panel, nil on a phone.
    public var display: String?
    /// Whether the saved video shows the device around the screen.
    public var bezel: Bool?
    public var durationSeconds: Double?
    public var byteCount: Int?
    public var error: String?
}

/// `recording`: the one in progress and the last one saved — sent whole
/// whenever either changes, so every viewer shows the same.
public struct RecordingTopicPayload: Codable, Equatable, Sendable {
    public var current: ScreenRecording?
    public var last: ScreenRecording?
}

public enum ScreenRecordingError: Error, LocalizedError, Equatable {
    case alreadyRecording
    case notRecording
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already running — stop it first"
        case .notRecording: return "No recording is running"
        case let .notFound(id): return "No saved recording \(id) — only the newest is kept"
        }
    }
}

/// Screen recordings made from the viewer, one at a time — `simctl io
/// recordVideo` of the screen the stream shows, as a test session records it.
/// Stopping finalizes the file, aligns its duration and, when asked, puts the
/// device around the screen. Only the newest recording is kept; the server
/// removes its folder when it stops.
public final class ScreenRecordingController: @unchecked Sendable {
    /// Puts the device around the recorded screen: the raw file in, the framed one out.
    public typealias Framer = @Sendable (_ input: URL, _ output: URL) async throws -> Void

    private let directory: URL
    private let deviceUDID: String
    /// A recorder of the screen; `masked` for a recording that gets the bezel.
    private let makeRecorder: @Sendable (_ masked: Bool) -> TestVideoRecorder
    private let display: @Sendable () -> String?
    private let onChange: @Sendable (RecordingTopicPayload) -> Void
    private let lock = NSLock()
    private var current: ScreenRecording?
    private var recorder: TestVideoRecorder?
    private var framer: Framer?
    private var last: ScreenRecording?
    private let now: @Sendable () -> Date

    public init(
        directory: URL,
        deviceUDID: String,
        display: @escaping @Sendable () -> String? = { nil },
        now: @escaping @Sendable () -> Date = Date.init,
        makeRecorder: @escaping @Sendable (_ masked: Bool) -> TestVideoRecorder,
        onChange: @escaping @Sendable (RecordingTopicPayload) -> Void = { _ in }
    ) {
        self.directory = directory
        self.deviceUDID = deviceUDID
        self.display = display
        self.now = now
        self.makeRecorder = makeRecorder
        self.onChange = onChange
    }

    public var topic: RecordingTopicPayload {
        lock.withLock { RecordingTopicPayload(current: current, last: last) }
    }

    /// Starts recording the screen — to be saved with the device around it
    /// when `framer` is given: the device's glass is recorded as well then.
    /// The previous recording's file goes: only the newest is kept.
    public func start(framer: Framer? = nil) throws -> ScreenRecording {
        let (recording, payload): (ScreenRecording, RecordingTopicPayload) = try lock.withLock {
            guard current == nil else { throw ScreenRecordingError.alreadyRecording }
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = Self.makeId(now())
            let recorder = makeRecorder(framer != nil)
            try recorder.start(deviceUDID: deviceUDID, outputFile: rawFile(id))
            let recording = ScreenRecording(id: id, state: .recording, startedAt: now(), display: display(), bezel: framer != nil)
            self.recorder = recorder
            self.framer = framer
            current = recording
            last = nil
            return (recording, RecordingTopicPayload(current: recording, last: nil))
        }
        onChange(payload)
        return recording
    }

    /// Stops the recording and saves it, with the device around the screen
    /// when it was started so. Returns it ready, or failed with the reason.
    public func stop() async throws -> ScreenRecording {
        let (stopping, recorder, framer): (ScreenRecording, TestVideoRecorder?, Framer?) = try lock.withLock {
            guard var recording = current, recording.state == .recording else { throw ScreenRecordingError.notRecording }
            recording.state = .saving
            recording.endedAt = now()
            current = recording
            defer { self.recorder = nil; self.framer = nil }
            return (recording, self.recorder, self.framer)
        }
        onChange(topic)
        await recorder?.stop()
        var recording = stopping
        do {
            let raw = rawFile(recording.id), saved = videoFile(recording.id)
            guard FileManager.default.fileExists(atPath: raw.path) else {
                throw SimToolError(recorder?.failure ?? "simctl wrote no video — the recording may have been too short")
            }
            // A failed remux keeps the original: a slightly short video beats none.
            try? await VideoDurationNormalizer.normalize(file: raw)
            if let framer {
                try await framer(raw, saved)
                try? FileManager.default.removeItem(at: raw)
            } else {
                try FileManager.default.moveItem(at: raw, to: saved)
            }
            recording.state = .ready
            recording.durationSeconds = await VideoDurationNormalizer.durationSeconds(of: saved)
            recording.byteCount = (try? FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? NSNumber)?.intValue
        } catch {
            recording.state = .failed
            recording.error = error.localizedDescription
        }
        lock.withLock {
            current = nil
            last = recording
        }
        onChange(topic)
        return recording
    }

    /// The saved video of the newest recording.
    public func videoFile(id: String) throws -> URL {
        let file: URL? = lock.withLock {
            guard let last, last.id == id, last.state == .ready else { return nil }
            return videoFile(last.id)
        }
        guard let file, FileManager.default.fileExists(atPath: file.path) else { throw ScreenRecordingError.notFound(id) }
        return file
    }

    /// The server is going away: a running recording stops unsaved and the folder goes.
    public func shutdown() async {
        let recorder = lock.withLock {
            defer { self.recorder = nil; self.framer = nil; current = nil }
            return self.recorder
        }
        await recorder?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func rawFile(_ id: String) -> URL { directory.appendingPathComponent(id + ".raw.mp4") }
    private func videoFile(_ id: String) -> URL { directory.appendingPathComponent(id + ".mp4") }

    static func makeId(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "rec-" + formatter.string(from: date) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }
}

/// A recorded screen put inside its bezel: each frame drawn into the screen's
/// place on the device picture, re-encoded as H.264.
public enum BezelVideo {
    /// `bezel` gets the recorded screen's size in pixels. The picture around
    /// the device is `background` — white by default: a video has no transparency.
    public static func frame(input: URL, output: URL, background: CGColor = CGColor(gray: 1, alpha: 1), bezel makeBezel: (CGSize) -> DeviceBezel) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SimToolError("The recording has no video track") }
        let natural = try await track.load(.naturalSize)
        let bezel = makeBezel(natural)
        let scale = natural.width / bezel.layout.screen.width
        let pixels = bezel.pixelSize(scale: scale)
        guard let device = bezel.render(scale: scale, background: background), let mask = bezel.screenMask(scale: scale) else {
            throw SimToolError("Could not draw the device bezel")
        }
        let deviceImage = CIImage(cgImage: device), maskImage = CIImage(cgImage: mask)
        // Core Image counts from the bottom-left.
        let screen = bezel.layout.screen
        let origin = CGPoint(x: screen.minX * scale, y: CGFloat(pixels.height) - screen.maxY * scale)
        let extent = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let frame = request.sourceImage.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
            let blended = frame.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: deviceImage,
                kCIInputMaskImageKey: maskImage,
            ])
            request.finish(with: blended.cropped(to: extent), context: nil)
        }
        composition.renderSize = CGSize(width: pixels.width, height: pixels.height)
        // simctl writes a frame only when the screen changes; 60 fps keeps every one.
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw SimToolError("Cannot create an export session for the bezel")
        }
        try? FileManager.default.removeItem(at: output)
        export.videoComposition = composition
        export.outputURL = output
        export.outputFileType = .mp4
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw export.error ?? SimToolError("Putting the bezel on the recording failed")
        }
    }
}
