import CoreImage
import CoreVideo
import Foundation
import Metal
import SimToolCore

/// The 3D preview of an iPhone Duo, run as a process of its own (`simtool
/// duo-render`): it captures the device's lit panel, renders the folded
/// device around it (`Duo3DRenderer`) and writes the frames to stdout as the
/// same H.264 envelopes the screen stream uses, each preceded by its
/// projection — where the panel's picture landed — when that moved.
///
/// A process of its own because RealityKit asserts kill the process they
/// happen in: a crash here costs the preview, never the server.
///
/// stdin takes one JSON object per line, every field optional:
/// `{"panel": "cover"|"inner", "hinge": 130, "dark": true,
/// "background": "#1b1d20", "keyframe": true}`. End of input stops it.
@available(macOS 15.0, *)
public enum Duo3DWorker {
    public struct Options: Sendable {
        public var deviceUDID: String
        public var modelURL: URL
        /// Each panel's framebuffer, as the device type declares it.
        public var cover: (width: Int, height: Int)
        public var inner: (width: Int, height: Int)

        public init(deviceUDID: String, modelURL: URL, cover: (width: Int, height: Int), inner: (width: Int, height: Int)) {
            self.deviceUDID = deviceUDID
            self.modelURL = modelURL
            self.cover = cover
            self.inner = inner
        }
    }

    struct Input: Decodable {
        var panel: String?
        var hinge: Double?
        var dark: Bool?
        var background: String?
        var keyframe: Bool?
    }

    /// Loads the model as the preview would; nil when it renders, else why not.
    @MainActor
    public static func check(modelURL: URL) async -> String? {
        do {
            _ = try await Duo3DRenderer(modelURL: modelURL, dark: true, width: 64, height: 64)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @MainActor
    public static func run(_ options: Options) async throws {
        let session = try await Duo3DSession(options: options)
        try await session.run()
    }
}

/// One worker's state: everything is touched on the main actor but the
/// capture callback, which only hands over its latest frame.
@available(macOS 15.0, *)
@MainActor
private final class Duo3DSession {
    private let options: Duo3DWorker.Options
    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let ci: CIContext
    private let capture = FrameCapture()
    private let encoder = H264Encoder(fps: 30, bitrate: 4_000_000, maxDimension: 1280)
    private let output = StandardOutputWriter()
    private var renderer: Duo3DRenderer
    private var pool: CVPixelBufferPool?
    private var panel: Duo3DRenderer.Panel = .cover
    private var hinge: Double = 0
    private var dark = true
    private var background = CIColor(red: 0, green: 0, blue: 0)
    private var dirty = true
    private var keyframe = true
    private var encoding = false
    private var lastProjection = Data()
    private let pending = PendingFrame()
    private var finished = false

    init(options: Duo3DWorker.Options) async throws {
        self.options = options
        guard let device = MTLCreateSystemDefaultDevice() else { throw Duo3DError("No Metal device to render the 3D preview on") }
        self.device = device
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { throw Duo3DError("Cannot read the screen into Metal") }
        textureCache = cache
        ci = CIContext(mtlDevice: device)
        renderer = try await Duo3DRenderer(modelURL: options.modelURL, dark: dark)
    }

    func run() async throws {
        encoder.onEncoded = { [output] encoded in
            if let description = encoded.description { output.write(AVCCEnvelope.description(avcc: description)) }
            output.write(encoded.kind == .keyframe ? AVCCEnvelope.keyframe(avcc: encoded.avcc) : AVCCEnvelope.delta(avcc: encoded.avcc))
        }
        let pending = pending, cache = textureCache
        try capture.start(deviceUDID: options.deviceUDID) { buffer, _ in
            pending.set(Self.texture(of: buffer, cache: cache))
        }
        aim()
        readInput()
        while !finished {
            if pending.hasFrame || dirty, !encoding { try await renderFrame() }
            try await Task.sleep(for: .milliseconds(33))
        }
        capture.stop()
        encoder.stop()
    }

    /// stdin on a thread of its own; each line lands on the main actor.
    private func readInput() {
        Thread.detachNewThread { [weak self] in
            while let line = readLine() {
                guard let input = try? JSONDecoder().decode(Duo3DWorker.Input.self, from: Data(line.utf8)) else { continue }
                Task { @MainActor in await self?.apply(input) }
            }
            Task { @MainActor in self?.finished = true }
        }
    }

    private func apply(_ input: Duo3DWorker.Input) async {
        if let raw = input.panel, let next = Duo3DRenderer.Panel(rawValue: raw), next != panel {
            panel = next
            renderer.blank(next == .cover ? .inner : .cover)
            aim()
        }
        if let hinge = input.hinge, hinge.isFinite { self.hinge = min(180, max(0, hinge)) }
        if let background = input.background.flatMap(Self.color(hex:)) { self.background = background }
        if let dark = input.dark, dark != self.dark {
            self.dark = dark
            // The shell's finish is chosen as the model loads.
            if let next = try? await Duo3DRenderer(modelURL: options.modelURL, dark: dark) { renderer = next }
        }
        if input.keyframe == true {
            keyframe = true
            lastProjection = Data()
        }
        dirty = true
    }

    /// Streams the lit panel only: the other one is dark glass.
    private func aim() {
        let size = panel == .cover ? options.cover : options.inner
        capture.setScreens([options.cover, options.inner], preferred: size)
    }

    private func renderFrame() async throws {
        dirty = false
        if let frame = pending.take(), matches(frame.texture, self.panel) {
            try renderer.show(frame.texture, on: self.panel)
        }
        // Input may land while the frame renders: the projection is the frame's own.
        let (panel, hinge) = (self.panel, self.hinge)
        let rendered = try await renderer.render(hinge: hinge, panel: panel)
        // Rounded to a tenth of a pixel: the same pose is the same projection.
        let pieces = rendered.pieces.map { $0.map { $0.map { ($0 * 10_000).rounded() / 10_000 } } }
        let projection = Duo3DProjection(pieces: pieces, panel: panel.rawValue, hinge: hinge, width: renderer.width, height: renderer.height)
        if let json = try? JSONEncoder().encode(projection), json != lastProjection {
            lastProjection = json
            output.write(AVCCEnvelope.projection(json: json))
        }
        guard let buffer = try pixelBuffer() else { return }
        let image = CIImage(mtlTexture: rendered.texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!])!
            .oriented(.downMirrored)
        let flat = image.composited(over: CIImage(color: background).cropped(to: image.extent))
        ci.render(flat, to: buffer, bounds: image.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        encoding = true
        let force = keyframe
        keyframe = false
        encoder.encode(buffer, forceKeyframe: force) { [weak self] in
            Task { @MainActor in self?.encoding = false }
        }
    }

    private func matches(_ texture: MTLTexture, _ panel: Duo3DRenderer.Panel) -> Bool {
        let size = panel == .cover ? options.cover : options.inner
        return [texture.width, texture.height].sorted() == [size.width, size.height].sorted()
    }

    private func pixelBuffer() throws -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: renderer.width,
                kCVPixelBufferHeightKey: renderer.height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { throw Duo3DError("Cannot allocate the 3D frames") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    /// The captured framebuffer as an sRGB texture, without a copy.
    nonisolated private static func texture(of buffer: CVPixelBuffer, cache: CVMetalTextureCache) -> CapturedTexture? {
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm_srgb, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &texture)
        guard let texture, let metal = CVMetalTextureGetTexture(texture) else { return nil }
        return CapturedTexture(owner: texture, texture: metal)
    }

    /// `#1b1d20` → the colour, as the viewer's stage shows it.
    static func color(hex: String) -> CIColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return CIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

/// Where a panel's picture landed on a 3D frame, for the viewer to aim
/// touches with: per leaf of the panel four corners in frame fractions
/// (top-left origin) and the part of the panel's framebuffer it shows.
public struct Duo3DProjection: Codable, Equatable, Sendable {
    public var pieces: [[[Double]]]
    public var panel: String
    public var hinge: Double
    public var width: Int
    public var height: Int
}

/// A captured frame's texture and the Core Video object keeping it alive.
private struct CapturedTexture: @unchecked Sendable {
    let owner: CVMetalTexture
    let texture: MTLTexture
}

/// The newest captured frame, handed from the capture queue to the renderer;
/// a frame not rendered yet is replaced by the next.
private final class PendingFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CapturedTexture?

    var hasFrame: Bool { lock.withLock { frame != nil } }

    func set(_ next: CapturedTexture?) {
        guard let next else { return }
        lock.withLock { frame = next }
    }

    func take() -> CapturedTexture? {
        lock.withLock {
            defer { frame = nil }
            return frame
        }
    }
}

/// stdout, written whole envelopes at a time from any thread.
private final class StandardOutputWriter: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ data: Data) {
        lock.withLock { try? FileHandle.standardOutput.write(contentsOf: data) }
    }
}
