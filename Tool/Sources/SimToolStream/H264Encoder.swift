import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public final class H264Encoder: @unchecked Sendable {
    public struct Encoded: Sendable {
        public let description: Data?
        public let kind: Kind
        public let avcc: Data

        public enum Kind: Sendable { case keyframe, delta }
    }

    public var onEncoded: (@Sendable (Encoded) -> Void)?

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var pool: CVPixelBufferPool?
    private var transferSession: VTPixelTransferSession?
    /// Encoded (downscaled) output dimensions for the compression session and pixel pool.
    private var width: Int32 = 0
    private var height: Int32 = 0
    /// Source pixel-buffer dimensions, tracked to detect rotations/resizes that require a rebuild.
    private var sourceWidth = 0
    private var sourceHeight = 0
    private let fps: Int32
    private let bitrate: Int
    /// Longest-side cap for the encoded stream. The simulator framebuffer is full retina
    /// (e.g. 1206×2622) but the viewer paints it small, so encoding at a cap of ~1280 cuts encode
    /// latency, decode cost, and bandwidth with no visible loss at fit scale. `0` disables scaling.
    private let maxDimension: Int
    private let stateQueue = DispatchQueue(label: "simtool.h264.state")
    private var emittedDescription = false
    private var frameCount: Int64 = 0

    public init(fps: Int = 60, bitrate: Int = 6_000_000, maxDimension: Int = 1280) {
        self.fps = Int32(fps)
        self.bitrate = bitrate
        self.maxDimension = maxDimension
    }

    deinit { stop() }

    /// Computes the encoded frame size for a source, clamping the longest side to `maxDimension`
    /// while preserving aspect ratio and keeping both dimensions even (required for 4:2:0 H.264).
    /// A `maxDimension` of `0` (or a source already within the cap) only forces even dimensions.
    public static func encodeSize(sourceWidth: Int, sourceHeight: Int, maxDimension: Int) -> (width: Int, height: Int) {
        let w = max(2, sourceWidth)
        let h = max(2, sourceHeight)
        let longest = max(w, h)
        guard maxDimension > 0, longest > maxDimension else {
            return (forceEven(w), forceEven(h))
        }
        let scale = Double(maxDimension) / Double(longest)
        return (
            forceEven(Int((Double(w) * scale).rounded())),
            forceEven(Int((Double(h) * scale).rounded()))
        )
    }

    private static func forceEven(_ value: Int) -> Int {
        let v = max(2, value)
        return v - (v % 2)
    }

    public func encode(_ source: CVPixelBuffer, forceKeyframe: Bool = false, completion: (() -> Void)? = nil) {
        lock.lock()
        let sw = Int(CVPixelBufferGetWidth(source))
        let sh = Int(CVPixelBufferGetHeight(source))
        if session == nil || sw != sourceWidth || sh != sourceHeight {
            sourceWidth = sw
            sourceHeight = sh
            let target = Self.encodeSize(sourceWidth: sw, sourceHeight: sh, maxDimension: maxDimension)
            width = Int32(target.width)
            height = Int32(target.height)
            rebuildSession()
        }
        guard let session, let scaled = scaleBuffer(source) else {
            lock.unlock()
            completion?()
            return
        }

        frameCount += 1
        let pts = CMTime(value: frameCount, timescale: fps)
        let props: NSDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as NSDictionary
            : nil
        lock.unlock()

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: scaled,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: props,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            defer { completion?() }
            guard let self, status == noErr, let sampleBuffer else { return }
            if let encoded = self.extract(from: sampleBuffer) { self.onEncoded?(encoded) }
        }
        if status != noErr { completion?() }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
        if let transferSession {
            VTPixelTransferSessionInvalidate(transferSession)
            self.transferSession = nil
        }
        pool = nil
    }

    /// Scales (and copies) the live source IOSurface-backed buffer into a fresh pooled buffer of
    /// the encoded target size. The copy is required because the simulator reuses the source
    /// surface for the next frame; doing it through the GPU pixel-transfer session folds the
    /// downscale into the same step.
    private func scaleBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool, let transferSession else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let dst = out else { return nil }
        guard VTPixelTransferSessionTransferImage(transferSession, from: source, to: dst) == noErr else {
            return nil
        }
        return dst
    }

    private func rebuildSession() {
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }

        let lowLatencySpec: NSDictionary = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!,
        ]
        var next: VTCompressionSession?
        func create(spec: CFDictionary?) -> OSStatus {
            VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: width,
                height: height,
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: spec,
                imageBufferAttributes: nil,
                compressedDataAllocator: kCFAllocatorDefault,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &next
            )
        }
        var status = create(spec: lowLatencySpec)
        if status != noErr || next == nil {
            next = nil
            status = create(spec: nil)
        }
        guard status == noErr, let next else { return }

        let props: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps * 5)),
        ]
        for (key, value) in props {
            VTSessionSetProperty(next, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(next)
        session = next
        stateQueue.sync { emittedDescription = false }

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(width),
            kCVPixelBufferHeightKey as String: Int(height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool)
        pool = newPool

        rebuildTransferSession()
    }

    private func rebuildTransferSession() {
        if let transferSession {
            VTPixelTransferSessionInvalidate(transferSession)
            self.transferSession = nil
        }
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
              let session else { return }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Trim)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DownsamplingMode, value: kVTDownsamplingMode_Average)
        transferSession = session
    }

    private func extract(from sample: CMSampleBuffer) -> Encoded? {
        let isKeyframe = !notSync(sample)
        guard let dataBuf = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuf,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == noErr, let dataPointer else { return nil }
        let avcc = Data(bytes: dataPointer, count: totalLength)

        var description: Data?
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            let nextDescription = avcCBlob(from: format)
            let shouldEmit = stateQueue.sync { () -> Bool in
                if emittedDescription { return false }
                emittedDescription = nextDescription != nil
                return nextDescription != nil
            }
            if shouldEmit { description = nextDescription }
        }
        return Encoded(description: description, kind: isKeyframe ? .keyframe : .delta, avcc: avcc)
    }

    private func notSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0,
              let dict = CFArrayGetValueAtIndex(attachments, 0) else { return false }
        let cfDict = unsafeBitCast(dict, to: CFDictionary.self)
        return CFDictionaryContainsKey(cfDict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
    }

    private func avcCBlob(from format: CMFormatDescription) -> Data? {
        var spsCount = 0
        var spsPtr: UnsafePointer<UInt8>?
        var spsSize = 0
        var nalSize: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPtr,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: &nalSize
        ) == noErr, let spsPtr, spsSize >= 4 else { return nil }

        var ppsPtr: UnsafePointer<UInt8>?
        var ppsSize = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPtr,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        ) == noErr, let ppsPtr else { return nil }

        let sps = UnsafeBufferPointer(start: spsPtr, count: spsSize)
        let pps = UnsafeBufferPointer(start: ppsPtr, count: ppsSize)
        var blob = Data()
        blob.append(0x01)
        blob.append(sps[1]); blob.append(sps[2]); blob.append(sps[3])
        blob.append(0xFF)
        blob.append(0xE1)
        blob.append(UInt8((spsSize >> 8) & 0xFF)); blob.append(UInt8(spsSize & 0xFF))
        blob.append(contentsOf: sps)
        blob.append(0x01)
        blob.append(UInt8((ppsSize >> 8) & 0xFF)); blob.append(UInt8(ppsSize & 0xFF))
        blob.append(contentsOf: pps)
        return blob
    }
}
