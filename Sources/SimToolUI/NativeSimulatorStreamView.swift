#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import SimToolStream
import SwiftUI

struct NativeSimulatorStreamView: NSViewRepresentable {
    var deviceUDID: String?
    var refreshID: Int
    var onFrame: @MainActor (CGSize) -> Void
    var onError: @MainActor (String) -> Void
    var onTap: @MainActor (CGPoint, CGSize) -> Void
    var onSwipe: @MainActor (CGPoint, CGPoint, CGSize, Double) -> Void

    func makeNSView(context _: Context) -> NativeSimulatorStreamNSView {
        let view = NativeSimulatorStreamNSView()
        view.configure(deviceUDID: deviceUDID, onFrame: onFrame, onError: onError, onTap: onTap, onSwipe: onSwipe)
        return view
    }

    func updateNSView(_ nsView: NativeSimulatorStreamNSView, context _: Context) {
        nsView.configure(deviceUDID: deviceUDID, onFrame: onFrame, onError: onError, onTap: onTap, onSwipe: onSwipe)
        nsView.refreshIfNeeded(id: refreshID)
    }

    static func dismantleNSView(_ nsView: NativeSimulatorStreamNSView, coordinator _: ()) {
        nsView.stop()
    }
}

final class NativeSimulatorStreamNSView: NSView {
    private let imageLayer = CALayer()
    private let placeholderLayer = CATextLayer()
    private let renderQueue = DispatchQueue(label: "simtool.native-render", qos: .userInteractive)
    private let renderLock = NSLock()
    private let frameRenderer = NativeFrameRenderer(scale: 1.0)
    private var renderGate = NativeFrameRenderGate(fps: 60)
    private var pendingFrame: NativeStreamFrame?
    private var renderScheduled = false
    private var frameCapture: FrameCapture?
    private var currentDeviceUDID: String?
    private var currentRefreshID = 0
    private var configured = false
    private var currentImageSize: CGSize = .zero
    private var mouseDownRatio: CGPoint?
    private var mouseDownTime: TimeInterval = 0

    private var onFrame: (@MainActor (CGSize) -> Void)?
    private var onError: (@MainActor (String) -> Void)?
    private var onTap: (@MainActor (CGPoint, CGSize) -> Void)?
    private var onSwipe: (@MainActor (CGPoint, CGPoint, CGSize, Double) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let root = layer else { return }
        root.cornerRadius = 18
        root.masksToBounds = true

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.masksToBounds = true
        imageLayer.contentsScale = scale
        root.addSublayer(imageLayer)

        placeholderLayer.string = "connecting..."
        placeholderLayer.font = NSFont.systemFont(ofSize: 12) as CTFont
        placeholderLayer.fontSize = 12
        placeholderLayer.alignmentMode = .center
        placeholderLayer.contentsScale = scale
        placeholderLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
        root.addSublayer(placeholderLayer)

        root.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { nil }

    deinit { stop() }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
        placeholderLayer.frame = CGRect(x: 0, y: bounds.midY - 8, width: bounds.width, height: 16)
    }

    func configure(
        deviceUDID: String?,
        onFrame: @escaping @MainActor (CGSize) -> Void,
        onError: @escaping @MainActor (String) -> Void,
        onTap: @escaping @MainActor (CGPoint, CGSize) -> Void,
        onSwipe: @escaping @MainActor (CGPoint, CGPoint, CGSize, Double) -> Void
    ) {
        self.onFrame = onFrame
        self.onError = onError
        self.onTap = onTap
        self.onSwipe = onSwipe

        guard !configured || currentDeviceUDID != deviceUDID else { return }
        configured = true
        stop()
        currentDeviceUDID = deviceUDID
        placeholderLayer.string = deviceUDID == nil ? "waiting for simulator..." : "connecting..."
        placeholderLayer.isHidden = false
        imageLayer.contents = nil
        currentImageSize = .zero
        guard let deviceUDID else { return }
        start(deviceUDID: deviceUDID)
    }

    func refreshIfNeeded(id: Int) {
        guard id != currentRefreshID else { return }
        currentRefreshID = id
        frameCapture?.refresh()
    }

    func stop() {
        frameCapture?.stop()
        frameCapture = nil
        renderLock.lock()
        pendingFrame = nil
        renderScheduled = false
        renderLock.unlock()
        mouseDownRatio = nil
    }

    private func start(deviceUDID: String) {
        let capture = FrameCapture()
        renderGate = NativeFrameRenderGate(fps: 60)
        do {
            try capture.start(deviceUDID: deviceUDID) { [weak self] pixelBuffer, _ in
                self?.handle(pixelBuffer: pixelBuffer)
            }
            frameCapture = capture
        } catch {
            let message = error.localizedDescription
            placeholderLayer.string = message
            onError?(message)
        }
    }

    private func handle(pixelBuffer: CVPixelBuffer) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        guard renderGate.begin(nowNs: nowNs) else { return }
        let sendable = SendablePixelBuffer(value: pixelBuffer)
        renderQueue.async { [weak self] in
            guard let self else { return }
            if let frame = self.frameRenderer.render(sendable.value) {
                self.didReceive(frame)
            }
            self.renderGate.end()
        }
    }

    private func didReceive(_ frame: NativeStreamFrame) {
        renderLock.lock()
        pendingFrame = frame
        guard !renderScheduled else {
            renderLock.unlock()
            return
        }
        renderScheduled = true
        renderLock.unlock()

        performSelector(onMainThread: #selector(renderLatestFrameOnMain), with: nil, waitUntilDone: false)
    }

    @objc private func renderLatestFrameOnMain() {
        renderLock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        renderScheduled = false
        renderLock.unlock()
        guard let frame else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = frame.image
        placeholderLayer.isHidden = true
        CATransaction.commit()
        currentImageSize = frame.size
        onFrame?(frame.size)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let ratio = ratioPoint(for: event) else { return }
        mouseDownRatio = ratio
        mouseDownTime = event.timestamp
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseDownRatio != nil else { return }
        _ = ratioPoint(for: event, clampToImage: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let startRatio = mouseDownRatio else { return }
        let endRatio = ratioPoint(for: event, clampToImage: true) ?? startRatio
        mouseDownRatio = nil
        guard currentImageSize.width > 0, currentImageSize.height > 0 else { return }
        let start = pixelPoint(from: startRatio)
        let end = pixelPoint(from: endRatio)
        let duration = max(0.05, event.timestamp - mouseDownTime)
        let distance = hypot(end.x - start.x, end.y - start.y)

        if distance < 8 {
            let onTap = onTap
            let size = currentImageSize
            Task { @MainActor in onTap?(end, size) }
        } else {
            let onSwipe = onSwipe
            let size = currentImageSize
            Task { @MainActor in onSwipe?(start, end, size, duration) }
        }
    }

    private func pixelPoint(from ratio: CGPoint) -> CGPoint {
        CGPoint(x: ratio.x * currentImageSize.width, y: ratio.y * currentImageSize.height)
    }

    private func ratioPoint(for event: NSEvent, clampToImage: Bool = false) -> CGPoint? {
        guard currentImageSize.width > 0, currentImageSize.height > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let view = bounds
        guard view.width > 0, view.height > 0 else { return nil }

        let viewAspect = view.width / view.height
        let imageAspect = currentImageSize.width / currentImageSize.height
        let drawn: CGRect
        if imageAspect > viewAspect {
            let height = view.width / imageAspect
            drawn = CGRect(x: 0, y: (view.height - height) / 2, width: view.width, height: height)
        } else {
            let width = view.height * imageAspect
            drawn = CGRect(x: (view.width - width) / 2, y: 0, width: width, height: view.height)
        }
        guard drawn.contains(local) || clampToImage else { return nil }
        let mapped: CGPoint
        if clampToImage {
            mapped = CGPoint(
                x: local.x.clamped(to: drawn.minX...drawn.maxX),
                y: local.y.clamped(to: drawn.minY...drawn.maxY)
            )
        } else {
            mapped = local
        }
        return CGPoint(
            x: ((mapped.x - drawn.minX) / drawn.width).clamped(),
            y: ((mapped.y - drawn.minY) / drawn.height).clamped()
        )
    }
}

private struct NativeStreamFrame: @unchecked Sendable {
    let image: CGImage
    var size: CGSize { CGSize(width: image.width, height: image.height) }
}

private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

private final class NativeFrameRenderGate: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumIntervalNs: UInt64
    private var rendering = false
    private var lastAcceptedNs: UInt64 = 0

    init(fps: Int) {
        minimumIntervalNs = fps > 0 ? 1_000_000_000 / UInt64(fps) : 0
    }

    func begin(nowNs: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if rendering { return false }
        if lastAcceptedNs > 0, nowNs &- lastAcceptedNs < minimumIntervalNs { return false }
        rendering = true
        lastAcceptedNs = nowNs
        return true
    }

    func end() {
        lock.lock()
        rendering = false
        lock.unlock()
    }
}

private final class NativeFrameRenderer: @unchecked Sendable {
    private let scale: CGFloat

    init(scale: Double) {
        self.scale = CGFloat(max(0.1, min(1.0, scale)))
    }

    func render(_ pixelBuffer: CVPixelBuffer) -> NativeStreamFrame? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let source = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )?.makeImage() else { return nil }

        if scale >= 0.999 { return NativeStreamFrame(image: source) }
        guard let scaled = scaledImage(source) else { return nil }
        return NativeStreamFrame(image: scaled)
    }

    private func scaledImage(_ image: CGImage) -> CGImage? {
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

private extension CGFloat {
    func clamped() -> CGFloat { Swift.max(0, Swift.min(1, self)) }
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.max(range.lowerBound, Swift.min(range.upperBound, self)) }
}
#endif
