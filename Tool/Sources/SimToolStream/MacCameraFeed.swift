import AVFoundation
import CoreImage
import Foundation
import SimToolCore

/// The Mac's webcam as a simulator's camera: frames captured here, scaled to
/// at most 1280 pixels on the long side and written as JPEG for the apps that
/// have SimTool's camera (`SimulatorCamera.writeFrame`), about twenty a second.
/// macOS asks once, for the app that started simtool, whether it may use the camera.
public final class MacCameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let camera: MacCamera
    private let deviceUDID: String
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "simtool.mac-camera")
    private let context = CIContext()
    private var lastWritten: CFTimeInterval = 0
    private var reportedFailure = false

    static let maxSide: CGFloat = 1280
    static let interval: CFTimeInterval = 1.0 / 20

    private init(camera: MacCamera, deviceUDID: String) {
        self.camera = camera
        self.deviceUDID = deviceUDID
    }

    /// The Mac's cameras: built in, external, Continuity.
    public static func cameras() -> [MacCamera] {
        devices().map { MacCamera(id: $0.uniqueID, name: $0.localizedName) }
    }

    private static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    }

    /// Starts capturing from the camera `requested` names — its id, or a part
    /// of its name — or the Mac's default one.
    public static func start(camera requested: String?, deviceUDID: String) async throws -> MacCameraFeed {
        try await authorize()
        let devices = devices()
        let device: AVCaptureDevice?
        if let requested, !requested.isEmpty {
            device = devices.first { $0.uniqueID == requested } ?? devices.first { $0.localizedName.localizedCaseInsensitiveContains(requested) }
            guard device != nil else {
                throw SimToolError("No Mac camera named \(requested): the Mac has \(devices.map(\.localizedName).joined(separator: ", ").nilIfEmpty ?? "none")")
            }
        } else {
            device = AVCaptureDevice.default(for: .video) ?? devices.first
        }
        guard let device else { throw SimToolError("This Mac has no camera") }
        let feed = MacCameraFeed(camera: MacCamera(id: device.uniqueID, name: device.localizedName), deviceUDID: deviceUDID)
        try feed.run(device)
        return feed
    }

    static let askTimeout: TimeInterval = 60

    private static func authorize() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            switch await requestAccess(timeout: askTimeout) {
            case true?: return
            case false?: break
            case nil:
                throw SimToolError("macOS is asking whether the app that started simtool may use the camera. Answer its dialog, then turn the Mac's camera on again.")
            }
        default:
            break
        }
        throw SimToolError("macOS does not let simtool use the Mac's camera. Allow the app that started it (the terminal, or the editor it runs in) in System Settings › Privacy & Security › Camera, then try again.")
    }

    /// macOS's answer, or nil when nobody answers its dialog in time — a
    /// request must not hang on a dialog on a screen nobody looks at.
    private static func requestAccess(timeout: TimeInterval) async -> Bool? {
        await withCheckedContinuation { continuation in
            let answered = OnceFlag()
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if answered.claim() { continuation.resume(returning: granted) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if answered.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private func run(_ device: AVCaptureDevice) throws {
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw SimToolError("\(device.localizedName) cannot be captured from")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
    }

    public func stop() {
        session.stopRunning()
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastWritten >= Self.interval, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastWritten = now
        var image = CIImage(cvPixelBuffer: pixels)
        let side = max(image.extent.width, image.extent.height)
        if side > Self.maxSide { image = image.transformed(by: CGAffineTransform(scaleX: Self.maxSide / side, y: Self.maxSide / side)) }
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]) else { return }
        do {
            try SimulatorCamera.writeFrame(jpeg, deviceUDID: deviceUDID)
            reportedFailure = false
        } catch {
            if !reportedFailure { DebugLog.write("camera", "cannot write the webcam's frame: \(error.localizedDescription)") }
            reportedFailure = true
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
