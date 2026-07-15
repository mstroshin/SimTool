import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import ObjectiveC
import SimToolCore

public final class FrameCapture: @unchecked Sendable {
    private static let idleTimerIntervalMs: UInt64 = 200
    private static let idleIntervalMs: UInt64 = 200
    private static let idleTimerToleranceMs: UInt64 = 50

    private var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    private var frameCount: UInt64 = 0
    private(set) public var capturedWidth: Int = 0
    private(set) public var capturedHeight: Int = 0
    private var idleTimer: DispatchSourceTimer?
    private let captureQueue = DispatchQueue(label: "simtool.frame-capture", qos: .userInteractive)
    private let captureQueueKey = DispatchSpecificKey<Void>()
    private var lastCaptureTimeMs: UInt64 = 0
    private var lastSeeds: [ObjectIdentifier: UInt32] = [:]
    private var rewireTickCount = 0
    private var descriptors: [NSObject] = []
    // Descriptors are ROCKit remote proxies: every message to them is an XPC
    // round-trip that also leaks a forwarding-proxy registration inside
    // ROCKSessionManager, so the framebuffer surface must be fetched once per
    // (re)wire and cached — never queried from the capture hot path.
    private var surfaces: [ObjectIdentifier: IOSurface] = [:]
    private var callbackUUIDs: [ObjectIdentifier: NSUUID] = [:]
    private var ioClient: NSObject?

    public init() {
        captureQueue.setSpecific(key: captureQueueKey, value: ())
    }

    public func start(deviceUDID: String, onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) throws {
        self.onFrame = onFrame
        let developerDir = Self.getDeveloperDir()
        if let coreSim = DeveloperFrameworks.frameworkBundlePath("CoreSimulator", developerDir: developerDir) {
            _ = dlopen("\(coreSim)/CoreSimulator", RTLD_NOW)
        }
        if let simKit = DeveloperFrameworks.frameworkBundlePath("SimulatorKit", developerDir: developerDir) {
            _ = dlopen("\(simKit)/SimulatorKit", RTLD_NOW)
        }

        guard let device = Self.findSimDevice(udid: deviceUDID) else {
            throw makeError(1, "Device \(deviceUDID) not found")
        }
        let state = device.value(forKey: "stateString") as? String ?? "unknown"
        guard state == "Booted" else {
            throw makeError(2, "Device not booted (state: \(state))")
        }
        guard let io = device.perform(NSSelectorFromString("io"))?.takeUnretainedValue() as? NSObject else {
            throw makeError(3, "Failed to get simulator IO client")
        }
        ioClient = io
        try syncOnCaptureQueue {
            try wireUpFramebuffer()
            startIdleTimer()
        }
    }

    public func stop() {
        syncOnCaptureQueue { stopOnCaptureQueue() }
    }

    public func refresh() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            try? self.wireUpFramebuffer()
        }
    }

    private func stopOnCaptureQueue() {
        idleTimer?.cancel()
        idleTimer = nil
        let unregSel = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
        for desc in descriptors {
            if let uuid = callbackUUIDs[ObjectIdentifier(desc)], desc.responds(to: unregSel) {
                desc.perform(unregSel, with: uuid)
            }
        }
        callbackUUIDs.removeAll()
        descriptors.removeAll()
        surfaces.removeAll()
        lastSeeds.removeAll()
        ioClient = nil
        onFrame = nil
    }

    private func syncOnCaptureQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: captureQueueKey) != nil {
            return try work()
        }
        return try captureQueue.sync(execute: work)
    }

    private func wireUpFramebuffer() throws {
        guard let io = ioClient else { throw makeError(3, "No simulator IO client") }
        io.perform(NSSelectorFromString("updateIOPorts"))
        let candidates = try findFramebufferDescriptors(io: io)

        let unregSel = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
        for oldDesc in descriptors {
            if let uuid = callbackUUIDs[ObjectIdentifier(oldDesc)], oldDesc.responds(to: unregSel) {
                oldDesc.perform(unregSel, with: uuid)
            }
        }
        callbackUUIDs.removeAll()
        lastSeeds.removeAll()
        surfaces.removeAll()
        descriptors = candidates
        for desc in candidates {
            try registerFrameCallbacks(desc: desc)
            refreshSurface(for: desc)
        }

        if let surface = bestSurface() {
            capturedWidth = IOSurfaceGetWidth(surface)
            capturedHeight = IOSurfaceGetHeight(surface)
        }
        captureFrame()
    }

    private func findFramebufferDescriptors(io: NSObject) throws -> [NSObject] {
        guard let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] else {
            throw makeError(4, "Failed to read simulator IO ports")
        }
        let pidSel = NSSelectorFromString("portIdentifier")
        let descSel = NSSelectorFromString("descriptor")
        let surfSel = NSSelectorFromString("framebufferSurface")
        var candidates: [NSObject] = []

        for port in ports {
            guard port.responds(to: pidSel),
                  let pid = port.perform(pidSel)?.takeUnretainedValue(),
                  "\(pid)" == "com.apple.framebuffer.display",
                  port.responds(to: descSel),
                  let desc = port.perform(descSel)?.takeUnretainedValue() as? NSObject,
                  desc.responds(to: surfSel) else { continue }
            candidates.append(desc)
        }
        if candidates.isEmpty { throw makeError(5, "No simulator framebuffer display descriptor found") }
        return candidates
    }

    private func registerFrameCallbacks(desc: NSObject) throws {
        let regSel = NSSelectorFromString(
            "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"
        )
        guard desc.responds(to: regSel) else {
            throw makeError(8, "Framebuffer descriptor does not support screen callbacks")
        }
        guard let msgSendPtr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else {
            throw makeError(9, "objc_msgSend not found")
        }

        typealias MsgSendFunc = @convention(c) (
            AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject
        ) -> Void
        let msgSend = unsafeBitCast(msgSendPtr, to: MsgSendFunc.self)
        let uuid = NSUUID()
        callbackUUIDs[ObjectIdentifier(desc)] = uuid

        let frameCallback: @convention(block) () -> Void = { [weak self] in
            self?.captureQueue.async { self?.captureFrame() }
        }
        let surfacesCallback: @convention(block) () -> Void = { [weak self] in
            self?.captureQueue.async {
                self?.refreshSurface(for: desc)
                self?.captureFrame()
            }
        }
        let propertiesCallback: @convention(block) () -> Void = {}

        msgSend(
            desc,
            regSel,
            uuid,
            captureQueue as AnyObject,
            frameCallback as AnyObject,
            surfacesCallback as AnyObject,
            propertiesCallback as AnyObject
        )
    }

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now().advanced(by: .milliseconds(Int(Self.idleTimerIntervalMs))),
                       repeating: .milliseconds(Int(Self.idleTimerIntervalMs)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
            if nowMs &- self.lastCaptureTimeMs >= Self.idleIntervalMs - Self.idleTimerToleranceMs {
                self.captureFrame(forceIdleRefresh: true)
            }
            if self.frameCount == 0 {
                self.rewireTickCount += 1
                if self.rewireTickCount % 5 == 0 { try? self.wireUpFramebuffer() }
            }
        }
        timer.resume()
        idleTimer = timer
    }

    private func captureFrame(forceIdleRefresh: Bool = false) {
        guard let surface = bestSurface() else { return }

        let key = ObjectIdentifier(surface)
        let seed = IOSurfaceGetSeed(surface)
        let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
        let seedChanged = lastSeeds[key] != seed
        let idleRefreshDue = frameCount > 0 && (forceIdleRefresh || nowMs &- lastCaptureTimeMs >= Self.idleIntervalMs)
        if frameCount > 0, !seedChanged, !idleRefreshDue { return }
        lastSeeds[key] = seed

        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else { return }
        capturedWidth = width
        capturedHeight = height

        var pixelBuffer: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBuffer?.takeRetainedValue() else { return }

        lastCaptureTimeMs = nowMs
        frameCount += 1
        onFrame?(pixelBuffer, CMTime(value: CMTimeValue(frameCount), timescale: 60))
    }

    private func refreshSurface(for desc: NSObject) {
        let key = ObjectIdentifier(desc)
        if let old = surfaces.removeValue(forKey: key) {
            lastSeeds[ObjectIdentifier(old)] = nil
        }
        guard let surfObj = desc.perform(NSSelectorFromString("framebufferSurface"))?.takeUnretainedValue() else {
            return
        }
        surfaces[key] = unsafeBitCast(surfObj, to: IOSurface.self)
    }

    private func bestSurface() -> IOSurface? {
        var best: IOSurface?
        var bestArea = 0
        for surface in surfaces.values {
            let area = IOSurfaceGetWidth(surface) * IOSurfaceGetHeight(surface)
            if area > bestArea {
                best = surface
                bestArea = area
            }
        }
        return best
    }

    private func makeError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "SimTool.FrameCapture", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func findSimDevice(udid: String) -> NSObject? {
        guard let contextClass = NSClassFromString("SimServiceContext") as? NSObject.Type else { return nil }
        let sharedSel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let context = contextClass.perform(sharedSel, with: getDeveloperDir(), with: nil)?
            .takeUnretainedValue() as? NSObject else { return nil }
        let deviceSetSel = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let deviceSet = context.perform(deviceSetSel, with: nil)?
            .takeUnretainedValue() as? NSObject else { return nil }
        guard let devices = deviceSet.value(forKey: "devices") as? [NSObject] else { return nil }
        return devices.first { ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid }
    }

    private static func getDeveloperDir() -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "/Applications/Xcode.app/Contents/Developer"
    }
}
