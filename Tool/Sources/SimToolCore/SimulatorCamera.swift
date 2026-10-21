import CryptoKit
import Darwin
import Foundation

/// Where a simulated camera's picture comes from.
public enum SimulatorCameraSource: String, Codable, Sendable {
    case none, image, video, webcam
}

/// An app that has SimTool's camera: it was launched with it, and says so
/// every second.
public struct SimulatorCameraClient: Codable, Equatable, Sendable {
    public var bundleId: String
    public var pid: Int
    /// A capture session runs on the camera.
    public var running: Bool

    public init(bundleId: String, pid: Int, running: Bool) {
        self.bundleId = bundleId
        self.pid = pid
        self.running = running
    }
}

/// A camera of the Mac.
public struct MacCamera: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct SimulatorCameraState: Codable, Equatable, Sendable {
    public var source: SimulatorCameraSource
    /// The image's or the video's name; the Mac camera's for the webcam.
    public var name: String?
    /// The apps that have the camera now.
    public var apps: [SimulatorCameraClient]
    /// The Mac's cameras the webcam source can take (a server fills it in).
    public var macCameras: [MacCamera]?

    public init(source: SimulatorCameraSource, name: String? = nil, apps: [SimulatorCameraClient] = [], macCameras: [MacCamera]? = nil) {
        self.source = source
        self.name = name
        self.apps = apps
        self.macCameras = macCameras
    }

    /// `image qr.png`, `video clip.mov, in a loop`, `the Mac's MacBook Pro Camera`, `off`.
    public var summary: String {
        switch source {
        case .none: "off"
        case .image: "image" + (name.map { " " + $0 } ?? "")
        case .video: "video" + (name.map { " " + $0 } ?? "") + ", in a loop"
        case .webcam: "the Mac's " + (name ?? "camera")
        }
    }
}

/// The simulator has no camera. SimTool gives one to the apps it launches —
/// the CLI, the server's Relaunch, a test run — by loading a library into them
/// (`DYLD_INSERT_LIBRARIES`) that answers AVFoundation's camera APIs with a
/// picture from this device's source: an image, a video in a loop, or the
/// Mac's webcam, whose frames the server writes. The source can change while
/// the app runs; an app launched while the camera was off, or by something
/// other than SimTool, has no camera until it is launched again.
///
/// Per device, in `~/Library/Caches/SimTool/Camera/<udid>/`: `camera.json`
/// (the source), the image or the video, `frame.jpg` (the webcam's newest
/// frame) and `clients/<pid>.json` (each app that has the camera).
public enum SimulatorCamera {
    private static let injectorVersion = "1"
    private static let injectorFingerprint = SHA256.hash(data: Data(SimulatorCameraInjectorSource.source.utf8))
        .prefix(6).map { String(format: "%02x", $0) }.joined()

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// What a file would show: an image or a video, by its extension.
    public static func sourceKind(ofFile name: String) -> SimulatorCameraSource? {
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    static var acceptedFiles: String {
        "an image (\(imageExtensions.sorted().joined(separator: ", "))) or a video (\(videoExtensions.sorted().joined(separator: ", ")))"
    }

    public static func directory(deviceUDID: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("SimTool/Camera/\(deviceUDID)", isDirectory: true)
    }

    private struct Config: Codable {
        var source: SimulatorCameraSource
        var file: String?
        var name: String?
    }

    private static func config(deviceUDID: String) -> Config? {
        guard let data = try? Data(contentsOf: directory(deviceUDID: deviceUDID).appendingPathComponent("camera.json")) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    private static func write(_ config: Config, deviceUDID: String) throws {
        let directory = directory(deviceUDID: deviceUDID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("camera.json"), options: .atomic)
    }

    /// The source, and the apps that have the camera: those that spoke in the
    /// last three seconds, and those still running that have gone quiet.
    public static func state(deviceUDID: String, now: Date = Date()) -> SimulatorCameraState {
        let config = config(deviceUDID: deviceUDID)
        let source = config?.source ?? .none
        return SimulatorCameraState(source: source, name: source == .none ? nil : config?.name, apps: clients(deviceUDID: deviceUDID, now: now))
    }

    static func clients(deviceUDID: String, now: Date, startOfProcess: (Int) -> Double? = processStart) -> [SimulatorCameraClient] {
        struct Heartbeat: Decodable { var bundleId: String; var pid: Int; var running: Bool; var at: Double }
        let folder = directory(deviceUDID: deviceUDID).appendingPathComponent("clients", isDirectory: true)
        // An app runs once: a relaunched one's predecessor may linger a moment, and its last word is older.
        var newest: [String: (client: SimulatorCameraClient, at: Double)] = [:]
        func add(_ client: SimulatorCameraClient, at: Double) {
            if let known = newest[client.bundleId], known.at >= at { return }
            newest[client.bundleId] = (client, at)
        }
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let beat = try? JSONDecoder().decode(Heartbeat.self, from: data) else { continue }
            if now.timeIntervalSince1970 - beat.at <= 3 {
                add(SimulatorCameraClient(bundleId: beat.bundleId, pid: beat.pid, running: beat.running), at: beat.at)
                continue
            }
            // Quiet: suspended in the background — iOS stops its timers, it
            // keeps the camera — or ended. A simulator's app is a process of
            // the Mac; the one that wrote this beat started before it.
            if let started = startOfProcess(beat.pid), started <= beat.at {
                add(SimulatorCameraClient(bundleId: beat.bundleId, pid: beat.pid, running: false), at: beat.at)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return newest.values.map(\.client).sorted { $0.pid < $1.pid }
    }

    /// When the Mac process `pid` started, if it runs.
    static func processStart(_ pid: Int) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    /// An image or a video becomes the camera's picture. It is copied under a
    /// new name each time, so the original may move and an app never reads a
    /// file half-written.
    @discardableResult
    public static func setFile(_ file: URL, deviceUDID: String) async throws -> SimulatorCameraState {
        let ext = file.pathExtension.lowercased()
        guard let source = sourceKind(ofFile: file.lastPathComponent) else {
            throw SimToolError("The camera takes \(acceptedFiles), not \(file.lastPathComponent)")
        }
        guard FileManager.default.fileExists(atPath: file.path) else { throw SimToolError("\(file.path) does not exist") }
        _ = try await injectorURL()
        let directory = directory(deviceUDID: deviceUDID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = "source-\(UUID().uuidString.prefix(8)).\(ext)"
        try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent(stored))
        let previous = config(deviceUDID: deviceUDID)?.file
        try write(Config(source: source, file: stored, name: file.lastPathComponent), deviceUDID: deviceUDID)
        if let previous, previous != stored { try? FileManager.default.removeItem(at: directory.appendingPathComponent(previous)) }
        return state(deviceUDID: deviceUDID)
    }

    /// The Mac's webcam becomes the picture; its frames come from whoever
    /// runs it (`writeFrame`).
    @discardableResult
    public static func setWebcam(name: String, deviceUDID: String) async throws -> SimulatorCameraState {
        _ = try await injectorURL()
        let previous = config(deviceUDID: deviceUDID)?.file
        try write(Config(source: .webcam, file: nil, name: name), deviceUDID: deviceUDID)
        if let previous { try? FileManager.default.removeItem(at: directory(deviceUDID: deviceUDID).appendingPathComponent(previous)) }
        return state(deviceUDID: deviceUDID)
    }

    /// The webcam's newest frame, a JPEG, swapped in whole.
    public static func writeFrame(_ jpeg: Data, deviceUDID: String) throws {
        let directory = directory(deviceUDID: deviceUDID)
        let temporary = directory.appendingPathComponent("frame.jpg.\(ProcessInfo.processInfo.processIdentifier).tmp")
        try jpeg.write(to: temporary)
        guard rename(temporary.path, directory.appendingPathComponent("frame.jpg").path) == 0 else {
            throw SimToolError("Cannot write the camera's frame: \(String(cString: strerror(errno)))")
        }
    }

    @discardableResult
    public static func off(deviceUDID: String) throws -> SimulatorCameraState {
        let directory = directory(deviceUDID: deviceUDID)
        let previous = config(deviceUDID: deviceUDID)
        try write(Config(source: .none, file: nil, name: nil), deviceUDID: deviceUDID)
        if let file = previous?.file { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("frame.jpg"))
        return state(deviceUDID: deviceUDID)
    }

    /// What an app launched now needs in its environment to have the camera —
    /// nothing while the camera is off, unless `evenWhenOff`: a test that turns
    /// it on halfway launches its app with the camera there but dark, since an
    /// app looks for cameras as it starts. `environment` is the launch's own; a
    /// library it already inserts stays first.
    public static func launchEnvironment(deviceUDID: String, merging environment: [String: String] = [:], evenWhenOff: Bool = false) -> [String: String] {
        var result = environment
        let source = config(deviceUDID: deviceUDID)?.source ?? .none
        guard source != .none || evenWhenOff, let injector = builtInjector() else { return result }
        let existing = environment["DYLD_INSERT_LIBRARIES"].flatMap { $0.isEmpty ? nil : $0 }
        result["DYLD_INSERT_LIBRARIES"] = [existing, injector.path].compactMap { $0 }.joined(separator: ":")
        result["SIMTOOL_CAMERA_DIR"] = directory(deviceUDID: deviceUDID).path
        result["SIMTOOL_CAMERA_PRESENT"] = "1"
        return result
    }

    private static func injectorLocation() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SimTool/SimulatorHelpers/simtool-camera-\(injectorVersion)-\(injectorFingerprint).dylib")
    }

    private static func builtInjector() -> URL? {
        guard let url = injectorLocation(), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The library, built for the simulator once per source — both
    /// architectures, so an app running under Rosetta takes it too — ad-hoc
    /// signed, and cached next to the other helpers. Several processes may
    /// build it at once: each writes its own files and renames the result into place.
    public static func injectorURL() async throws -> URL {
        if let built = builtInjector() { return built }
        guard let output = injectorLocation() else { throw SimToolError("Failed to locate user caches directory") }
        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unique = UUID().uuidString
        let source = directory.appendingPathComponent("\(output.lastPathComponent).\(unique).m")
        let temporary = directory.appendingPathComponent("\(output.lastPathComponent).tmp.\(unique)")
        try SimulatorCameraInjectorSource.source.write(to: source, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: temporary)
        }
        let frameworks = ["Foundation", "AVFoundation", "CoreImage", "CoreMedia", "CoreVideo", "CoreGraphics", "QuartzCore", "ImageIO", "UIKit", "Vision", "VideoToolbox"]
        let built = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--sdk", "iphonesimulator", "clang", "-arch", "arm64", "-arch", "x86_64", "-mios-simulator-version-min=16.0", "-dynamiclib", "-fobjc-arc"]
                + frameworks.flatMap { ["-framework", $0] } + ["-Wl,-adhoc_codesign", "-o", temporary.path, source.path],
            timeoutSeconds: 120
        )
        guard built.status == 0 else {
            throw SimToolError(built.stderrString.isEmpty ? "Failed to build the camera library" : built.stderrString)
        }
        guard rename(temporary.path, output.path) == 0 else {
            throw SimToolError("Failed to install the camera library: \(String(cString: strerror(errno)))")
        }
        return output
    }
}

enum SimulatorCameraInjectorSource {
    static let source = #"""
    #import <AVFoundation/AVFoundation.h>
    #import <CoreImage/CoreImage.h>
    #import <ImageIO/ImageIO.h>
    #import <UIKit/UIKit.h>
    #import <Vision/Vision.h>
    #import <VideoToolbox/VideoToolbox.h>
    #import <objc/runtime.h>
    #import <sys/stat.h>
    #import <unistd.h>

    // SimTool's camera for the iOS Simulator, loaded into an app SimTool launched
    // (DYLD_INSERT_LIBRARIES). The simulator has no camera; with a source set, the
    // app gets a back and a front one whose picture is that source: an image, a
    // video played in a loop, or the Mac's webcam as the SimTool server writes its
    // frames. Everything lives in SIMTOOL_CAMERA_DIR:
    //
    //   camera.json    {"source": "image" | "video" | "webcam" | "none", "file": "<name>"}
    //   <file>         the image or the video
    //   frame.jpg      the newest webcam frame, replaced whole
    //   clients/<pid>  this app, rewritten every second: it has the camera
    //
    // What the app sees: AVCaptureDevice discovery and its defaults, a device
    // input, a session that takes it, adds outputs and runs; video data output
    // frames in the pixel format asked for; the preview layer; photo capture;
    // metadata output (barcodes, read with Vision); and the camera of
    // UIImagePickerController, which answers at once with the current picture.
    // An app that never had a source sees AVFoundation as it always is: no camera;
    // one that had it, or was launched with SIMTOOL_CAMERA_PRESENT=1, sees black
    // while the source is off.

    static const size_t MaxSide = 1920;
    static const double FramesPerSecond = 30;

    typedef enum { SourceNone, SourceImage, SourceVideo, SourceWebcam } SourceKind;

    static NSString *gDir;
    static dispatch_queue_t gQueue;          // reads the source, makes and delivers frames
    static dispatch_queue_t gPhotoQueue;     // answers photo captures, as AVFoundation's own queue would
    static SourceKind gKind = SourceNone;
    static NSString *gFile;
    static struct timespec gConfigTime, gFrameTime;

    // The picture now: BGRA pixels, the same as an image, and a count that moves when it changes.
    static CVPixelBufferRef gPixels;
    static CGImageRef gImage;
    static uint64_t gGeneration;

    static AVAssetReader *gReader;
    static AVAssetReaderTrackOutput *gTrack;
    static CMSampleBufferRef gPending;       // the video's next frame, not yet due
    static CFTimeInterval gVideoStart;
    static uint64_t gTicks;

    static NSHashTable *gSessions;           // sessions on SimTool's camera that run
    static NSHashTable *gPreviewLayers;
    static uint64_t gPreviewGeneration;

    // The app has SimTool's camera: from launch with SIMTOOL_CAMERA_PRESENT=1, or
    // since a source was first set. Turned off, it stays and shows black — an app
    // holding a session keeps its devices, as with a covered lens.
    static BOOL gPresent;
    static BOOL active(void) { return gPresent; }

    #pragma mark - pictures

    static CVPixelBufferRef pixelsOfImage(CGImageRef image) {
      size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
      NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES, (id)kCVPixelBufferCGImageCompatibilityKey: @YES};
      CVPixelBufferRef pixels = NULL;
      if (CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixels) != kCVReturnSuccess) { return NULL; }
      CVPixelBufferLockBaseAddress(pixels, 0);
      CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
      CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixels), width, height, 8, CVPixelBufferGetBytesPerRow(pixels), space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
      CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
      CGContextRelease(context);
      CGColorSpaceRelease(space);
      CVPixelBufferUnlockBaseAddress(pixels, 0);
      return pixels;
    }

    static CGImageRef imageOfPixels(CVPixelBufferRef pixels) {
      CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
      CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
      CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixels), CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 8, CVPixelBufferGetBytesPerRow(pixels), space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
      CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;
      if (context) { CGContextRelease(context); }
      CGColorSpaceRelease(space);
      CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
      return image;
    }

    // Decoded upright (EXIF orientation applied) and at most MaxSide on its long side.
    static CGImageRef decodeImage(CGImageSourceRef source) {
      if (!source) { return NULL; }
      NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES, (id)kCGImageSourceCreateThumbnailWithTransform: @YES, (id)kCGImageSourceThumbnailMaxPixelSize: @(MaxSide)};
      CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
      CFRelease(source);
      return image;
    }

    // Takes both; either may be NULL and is made from the other.
    static void setPicture(CGImageRef image, CVPixelBufferRef pixels) {
      if (!image && !pixels) { return; }
      if (!pixels) { pixels = pixelsOfImage(image); } else { CVPixelBufferRetain(pixels); }
      if (!image) { image = imageOfPixels(pixels); } else { CGImageRetain(image); }
      if (gPixels) { CVPixelBufferRelease(gPixels); }
      if (gImage) { CGImageRelease(gImage); }
      gPixels = pixels;
      gImage = image;
      gGeneration += 1;
    }

    static void blackPicture(void) {
      CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
      CGContextRef context = CGBitmapContextCreate(NULL, 1280, 720, 8, 0, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
      CGContextSetRGBFillColor(context, 0, 0, 0, 1);
      CGContextFillRect(context, CGRectMake(0, 0, 1280, 720));
      CGImageRef image = CGBitmapContextCreateImage(context);
      setPicture(image, NULL);
      CGImageRelease(image);
      CGContextRelease(context);
      CGColorSpaceRelease(space);
    }

    #pragma mark - the source

    // Whether the file changed since `seen`, which is updated.
    static BOOL changed(NSString *path, struct timespec *seen) {
      struct stat info;
      if (stat(path.fileSystemRepresentation, &info) != 0) { return NO; }
      if (info.st_mtimespec.tv_sec == seen->tv_sec && info.st_mtimespec.tv_nsec == seen->tv_nsec) { return NO; }
      *seen = info.st_mtimespec;
      return YES;
    }

    static void closeVideo(void) {
      [gReader cancelReading];
      gReader = nil;
      gTrack = nil;
      if (gPending) { CFRelease(gPending); gPending = NULL; }
    }

    static void openVideo(void) {
      closeVideo();
      AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[gDir stringByAppendingPathComponent:gFile]] options:nil];
      AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
      if (!track) { NSLog(@"SimTool camera: %@ holds no video track", gFile); return; }
      NSError *error = nil;
      gReader = [AVAssetReader assetReaderWithAsset:asset error:&error];
      gTrack = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
      if (!gReader || ![gReader canAddOutput:gTrack]) { NSLog(@"SimTool camera: cannot read %@: %@", gFile, error); gReader = nil; return; }
      [gReader addOutput:gTrack];
      [gReader startReading];
      gVideoStart = CACurrentMediaTime();
    }

    // The frames now due, the last one shown; at its end the video starts over.
    static void advanceVideo(void) {
      if (!gReader) { return; }
      CFTimeInterval elapsed = CACurrentMediaTime() - gVideoStart;
      for (;;) {
        if (!gPending) {
          gPending = [gTrack copyNextSampleBuffer];
          if (!gPending) {
            if (gReader.status == AVAssetReaderStatusCompleted) { openVideo(); }
            return;
          }
        }
        if (CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(gPending)) > elapsed) { return; }
        CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(gPending);
        if (pixels) { setPicture(NULL, pixels); }
        CFRelease(gPending);
        gPending = NULL;
      }
    }

    static void readConfig(void) {
      NSString *path = [gDir stringByAppendingPathComponent:@"camera.json"];
      if (!changed(path, &gConfigTime)) { return; }
      NSData *data = [NSData dataWithContentsOfFile:path];
      NSDictionary *config = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      NSString *source = [config isKindOfClass:[NSDictionary class]] ? config[@"source"] : nil;
      gFile = [config[@"file"] isKindOfClass:[NSString class]] ? config[@"file"] : nil;
      closeVideo();
      gFrameTime = (struct timespec){0, 0};
      if ([source isEqual:@"image"] && gFile) {
        gKind = SourceImage;
        gPresent = YES;
        CGImageRef image = decodeImage(CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:[gDir stringByAppendingPathComponent:gFile]], NULL));
        if (image) { setPicture(image, NULL); CGImageRelease(image); } else { NSLog(@"SimTool camera: cannot decode %@", gFile); blackPicture(); }
      } else if ([source isEqual:@"video"] && gFile) {
        gKind = SourceVideo;
        gPresent = YES;
        openVideo();
      } else if ([source isEqual:@"webcam"]) {
        gKind = SourceWebcam;
        gPresent = YES;
        blackPicture();
      } else {
        gKind = SourceNone;
        if (gPresent) { blackPicture(); }
      }
    }

    static void advanceWebcam(void) {
      NSString *path = [gDir stringByAppendingPathComponent:@"frame.jpg"];
      if (!changed(path, &gFrameTime)) { return; }
      NSData *data = [NSData dataWithContentsOfFile:path];
      if (!data) { return; }
      CGImageRef image = decodeImage(CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL));
      if (image) { setPicture(image, NULL); CGImageRelease(image); }
    }

    #pragma mark - the fake camera

    @interface STCameraDevice : AVCaptureDevice
    @property (nonatomic) AVCaptureDevicePosition stPosition;
    @end

    @implementation STCameraDevice
    - (NSString *)uniqueID { return self.stPosition == AVCaptureDevicePositionFront ? @"com.simtool.camera.front" : @"com.simtool.camera.back"; }
    - (NSString *)modelID { return @"SimTool Camera"; }
    - (NSString *)localizedName { return self.stPosition == AVCaptureDevicePositionFront ? @"SimTool Front Camera" : @"SimTool Back Camera"; }
    - (NSString *)manufacturer { return @"SimTool"; }
    - (AVCaptureDevicePosition)position { return self.stPosition; }
    - (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
    - (BOOL)hasMediaType:(AVMediaType)mediaType { return [mediaType isEqual:AVMediaTypeVideo]; }
    - (BOOL)isConnected { return YES; }
    - (BOOL)isSuspended { return NO; }
    - (BOOL)lockForConfiguration:(NSError **)outError { return YES; }
    - (void)unlockForConfiguration {}
    - (BOOL)hasFlash { return NO; }
    - (BOOL)hasTorch { return NO; }
    - (BOOL)isFlashAvailable { return NO; }
    - (BOOL)isTorchAvailable { return NO; }
    - (BOOL)isFocusModeSupported:(AVCaptureFocusMode)focusMode { return YES; }
    - (void)setFocusMode:(AVCaptureFocusMode)focusMode {}
    - (AVCaptureFocusMode)focusMode { return AVCaptureFocusModeContinuousAutoFocus; }
    - (BOOL)isFocusPointOfInterestSupported { return YES; }
    - (void)setFocusPointOfInterest:(CGPoint)point {}
    - (BOOL)isExposureModeSupported:(AVCaptureExposureMode)exposureMode { return YES; }
    - (void)setExposureMode:(AVCaptureExposureMode)exposureMode {}
    - (AVCaptureExposureMode)exposureMode { return AVCaptureExposureModeContinuousAutoExposure; }
    - (BOOL)isExposurePointOfInterestSupported { return YES; }
    - (void)setExposurePointOfInterest:(CGPoint)point {}
    - (BOOL)isAutoFocusRangeRestrictionSupported { return NO; }
    - (BOOL)isSmoothAutoFocusSupported { return NO; }
    - (CGFloat)videoZoomFactor { return 1; }
    - (void)setVideoZoomFactor:(CGFloat)factor {}
    - (void)rampToVideoZoomFactor:(CGFloat)factor withRate:(float)rate {}
    - (CGFloat)minAvailableVideoZoomFactor { return 1; }
    - (CGFloat)maxAvailableVideoZoomFactor { return 1; }
    - (NSArray<AVCaptureDeviceFormat *> *)formats { return @[]; }
    - (NSString *)description { return [NSString stringWithFormat:@"<SimTool camera %@>", self.localizedName]; }
    @end

    @interface STCameraInput : AVCaptureDeviceInput
    @property (nonatomic, strong) STCameraDevice *stDevice;
    @end

    @implementation STCameraInput
    - (AVCaptureDevice *)device { return self.stDevice; }
    - (NSArray<AVCaptureInputPort *> *)ports { return @[]; }
    @end

    @interface STConnection : AVCaptureConnection
    @property (nonatomic, weak) AVCaptureOutput *stOutput;
    @property (nonatomic) AVCaptureVideoOrientation stOrientation;
    @property (nonatomic) CGFloat stRotation;
    @property (nonatomic) BOOL stMirrored;
    @property (nonatomic) BOOL stEnabled;
    @end

    @implementation STConnection
    - (AVCaptureOutput *)output { return self.stOutput; }
    - (AVMediaType)mediaType { return AVMediaTypeVideo; }
    - (NSArray<AVCaptureInputPort *> *)inputPorts { return @[]; }
    - (BOOL)isEnabled { return YES; }
    - (void)setEnabled:(BOOL)enabled {}
    - (BOOL)isActive { return YES; }
    - (BOOL)isVideoOrientationSupported { return YES; }
    - (AVCaptureVideoOrientation)videoOrientation { return self.stOrientation ?: AVCaptureVideoOrientationPortrait; }
    - (void)setVideoOrientation:(AVCaptureVideoOrientation)orientation { self.stOrientation = orientation; }
    - (BOOL)isVideoRotationAngleSupported:(CGFloat)angle { return YES; }
    - (CGFloat)videoRotationAngle { return self.stRotation; }
    - (void)setVideoRotationAngle:(CGFloat)angle { self.stRotation = angle; }
    - (BOOL)isVideoMirroringSupported { return YES; }
    - (BOOL)isVideoMirrored { return self.stMirrored; }
    - (void)setVideoMirrored:(BOOL)mirrored { self.stMirrored = mirrored; }
    - (BOOL)automaticallyAdjustsVideoMirroring { return NO; }
    - (void)setAutomaticallyAdjustsVideoMirroring:(BOOL)value {}
    - (BOOL)isVideoStabilizationSupported { return NO; }
    - (void)setPreferredVideoStabilizationMode:(AVCaptureVideoStabilizationMode)mode {}
    @end

    @interface STResolvedSettings : AVCaptureResolvedPhotoSettings
    @property (nonatomic) CMVideoDimensions stDimensions;
    @property (nonatomic) int64_t stID;
    @end

    @implementation STResolvedSettings
    - (int64_t)uniqueID { return self.stID; }
    - (CMVideoDimensions)photoDimensions { return self.stDimensions; }
    - (CMVideoDimensions)previewDimensions { return (CMVideoDimensions){0, 0}; }
    - (BOOL)isFlashEnabled { return NO; }
    @end

    @interface STPhoto : AVCapturePhoto
    @property (nonatomic, strong) NSData *stData;
    @property (nonatomic) CGImageRef stImage;
    @property (nonatomic) CVPixelBufferRef stPixels;
    @property (nonatomic, strong) STResolvedSettings *stSettings;
    @end

    @implementation STPhoto
    - (NSData *)fileDataRepresentation { return self.stData; }
    - (CGImageRef)CGImageRepresentation { return self.stImage; }
    - (CGImageRef)previewCGImageRepresentation { return self.stImage; }
    - (CVPixelBufferRef)pixelBuffer { return self.stPixels; }
    - (CVPixelBufferRef)previewPixelBuffer { return NULL; }
    - (NSDictionary<NSString *, id> *)metadata { return @{}; }
    - (CMTime)timestamp { return CMClockGetTime(CMClockGetHostTimeClock()); }
    - (BOOL)isRawPhoto { return NO; }
    - (NSInteger)photoCount { return 1; }
    - (AVCaptureResolvedPhotoSettings *)resolvedSettings { return self.stSettings; }
    - (void)dealloc { if (_stImage) { CGImageRelease(_stImage); } if (_stPixels) { CVPixelBufferRelease(_stPixels); } }
    @end

    @interface STCode : AVMetadataMachineReadableCodeObject
    @property (nonatomic, copy) AVMetadataObjectType stType;
    @property (nonatomic, copy) NSString *stValue;
    @property (nonatomic) CGRect stBounds;
    @end

    @implementation STCode
    - (AVMetadataObjectType)type { return self.stType; }
    - (NSString *)stringValue { return self.stValue; }
    - (CGRect)bounds { return self.stBounds; }
    - (NSArray<NSDictionary *> *)corners {
      CGRect b = self.stBounds;
      CGPoint points[4] = {{CGRectGetMinX(b), CGRectGetMinY(b)}, {CGRectGetMinX(b), CGRectGetMaxY(b)}, {CGRectGetMaxX(b), CGRectGetMaxY(b)}, {CGRectGetMaxX(b), CGRectGetMinY(b)}};
      NSMutableArray *corners = [NSMutableArray array];
      for (int i = 0; i < 4; i++) { [corners addObject:CFBridgingRelease(CGPointCreateDictionaryRepresentation(points[i]))]; }
      return corners;
    }
    - (CMTime)time { return CMClockGetTime(CMClockGetHostTimeClock()); }
    - (CMTime)duration { return kCMTimeZero; }
    @end

    static STCameraDevice *gBack, *gFront;

    static NSArray *fakeDevices(void) { return @[gBack, gFront]; }

    static STCameraDevice *fakeDevice(AVCaptureDevicePosition position) {
      return position == AVCaptureDevicePositionFront ? gFront : gBack;
    }

    #pragma mark - sessions, outputs and their bookkeeping

    static char kInputs, kOutputs, kRunning, kSession, kConnection, kInFlight, kTypes, kPosition;

    static NSMutableArray *associatedArray(id object, const void *key) {
      NSMutableArray *array = objc_getAssociatedObject(object, key);
      if (!array) { array = [NSMutableArray array]; objc_setAssociatedObject(object, key, array, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
      return array;
    }

    static BOOL onSimToolCamera(AVCaptureSession *session) { return [objc_getAssociatedObject(session, &kInputs) count] > 0; }

    // A weak hold on the session an output was added to.
    @interface STWeakBox : NSObject
    @property (nonatomic, weak) id object;
    @end
    @implementation STWeakBox
    @end

    static AVCaptureSession *sessionOf(AVCaptureOutput *output) { return ((STWeakBox *)objc_getAssociatedObject(output, &kSession)).object; }

    static STConnection *connectionOf(AVCaptureOutput *output) {
      STConnection *connection = objc_getAssociatedObject(output, &kConnection);
      if (!connection) {
        connection = [STConnection alloc];
        connection.stOutput = output;
        connection.stOrientation = AVCaptureVideoOrientationPortrait;
        connection.stRotation = 90;
        objc_setAssociatedObject(output, &kConnection, connection, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      }
      return connection;
    }

    static BOOL outputOnSimToolCamera(AVCaptureOutput *output) {
      AVCaptureSession *session = sessionOf(output);
      return session && onSimToolCamera(session);
    }

    #pragma mark - delivery (gQueue)

    static VTPixelTransferSessionRef gTransfer;

    // The picture in the format the output asked for: BGRA as it is, anything
    // else converted; the default is AVFoundation's own, 420 full range.
    static CVPixelBufferRef pixelsFor(AVCaptureVideoDataOutput *output) {
      NSNumber *requested = output.videoSettings[(id)kCVPixelBufferPixelFormatTypeKey];
      OSType format = requested ? requested.unsignedIntValue : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
      if (format == kCVPixelFormatType_32BGRA) { CVPixelBufferRetain(gPixels); return gPixels; }
      if (!gTransfer && VTPixelTransferSessionCreate(NULL, &gTransfer) != noErr) { return NULL; }
      CVPixelBufferRef converted = NULL;
      NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
      if (CVPixelBufferCreate(NULL, CVPixelBufferGetWidth(gPixels), CVPixelBufferGetHeight(gPixels), format, (__bridge CFDictionaryRef)attributes, &converted) != kCVReturnSuccess) { return NULL; }
      if (VTPixelTransferSessionTransferImage(gTransfer, gPixels, converted) != noErr) { CVPixelBufferRelease(converted); return NULL; }
      return converted;
    }

    static CMSampleBufferRef sampleOf(CVPixelBufferRef pixels) {
      CMVideoFormatDescriptionRef description = NULL;
      if (CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixels, &description) != noErr) { return NULL; }
      CMSampleTimingInfo timing = {CMTimeMake(1, (int32_t)FramesPerSecond), CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
      CMSampleBufferRef sample = NULL;
      CMSampleBufferCreateReadyWithImageBuffer(NULL, pixels, description, &timing, &sample);
      CFRelease(description);
      return sample;
    }

    static void deliverVideo(AVCaptureVideoDataOutput *output) {
      id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = output.sampleBufferDelegate;
      dispatch_queue_t queue = output.sampleBufferCallbackQueue;
      if (!delegate || !queue || ![delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) { return; }
      NSNumber *inFlight = objc_getAssociatedObject(output, &kInFlight);
      if (inFlight.boolValue) { return; }   // a late frame is dropped, as alwaysDiscardsLateVideoFrames does
      CVPixelBufferRef pixels = pixelsFor(output);
      if (!pixels) { return; }
      CMSampleBufferRef sample = sampleOf(pixels);
      CVPixelBufferRelease(pixels);
      if (!sample) { return; }
      objc_setAssociatedObject(output, &kInFlight, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      STConnection *connection = connectionOf(output);
      dispatch_async(queue, ^{
        [delegate captureOutput:output didOutputSampleBuffer:sample fromConnection:connection];
        CFRelease(sample);
        dispatch_async(gQueue, ^{ objc_setAssociatedObject(output, &kInFlight, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC); });
      });
    }

    static NSDictionary<VNBarcodeSymbology, AVMetadataObjectType> *symbologies(void) {
      static NSDictionary *map;
      static dispatch_once_t once;
      dispatch_once(&once, ^{
        map = @{VNBarcodeSymbologyQR: AVMetadataObjectTypeQRCode, VNBarcodeSymbologyEAN13: AVMetadataObjectTypeEAN13Code,
                VNBarcodeSymbologyEAN8: AVMetadataObjectTypeEAN8Code, VNBarcodeSymbologyUPCE: AVMetadataObjectTypeUPCECode,
                VNBarcodeSymbologyCode128: AVMetadataObjectTypeCode128Code, VNBarcodeSymbologyCode39: AVMetadataObjectTypeCode39Code,
                VNBarcodeSymbologyCode93: AVMetadataObjectTypeCode93Code, VNBarcodeSymbologyPDF417: AVMetadataObjectTypePDF417Code,
                VNBarcodeSymbologyAztec: AVMetadataObjectTypeAztecCode, VNBarcodeSymbologyDataMatrix: AVMetadataObjectTypeDataMatrixCode,
                VNBarcodeSymbologyITF14: AVMetadataObjectTypeITF14Code, VNBarcodeSymbologyI2of5: AVMetadataObjectTypeInterleaved2of5Code};
      });
      return map;
    }

    static uint64_t gCodesGeneration = UINT64_MAX;
    static NSArray<STCode *> *gCodes;

    static STCode *codeOf(AVMetadataObjectType type, NSString *value, CGRect box) {
      STCode *code = [STCode alloc];
      code.stType = type;
      code.stValue = value;
      // Vision's and Core Image's origin is the bottom left; AVFoundation's the top left.
      code.stBounds = CGRectMake(box.origin.x, 1 - box.origin.y - box.size.height, box.size.width, box.size.height);
      return code;
    }

    // Barcodes in the picture, read once per picture. The simulator has no
    // inference context for Vision's current barcode model, so its first
    // revision reads them — the classic detector, every symbology; should that
    // fail too, Core Image still reads a QR code.
    static NSArray<STCode *> *codes(void) {
      if (gCodesGeneration == gGeneration) { return gCodes; }
      gCodesGeneration = gGeneration;
      NSMutableArray *found = [NSMutableArray array];
      VNDetectBarcodesRequest *request = [[VNDetectBarcodesRequest alloc] init];
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
      request.revision = VNDetectBarcodesRequestRevision1;
    #pragma clang diagnostic pop
      NSError *error = nil;
      if ([[[VNImageRequestHandler alloc] initWithCVPixelBuffer:gPixels options:@{}] performRequests:@[request] error:&error]) {
        for (VNBarcodeObservation *observation in request.results) {
          AVMetadataObjectType type = symbologies()[observation.symbology];
          if (type && observation.payloadStringValue) { [found addObject:codeOf(type, observation.payloadStringValue, observation.boundingBox)]; }
        }
      } else if (gImage) {
        CIImage *image = [CIImage imageWithCGImage:gImage];
        CGSize size = image.extent.size;
        for (CIQRCodeFeature *feature in [[CIDetector detectorOfType:CIDetectorTypeQRCode context:nil options:nil] featuresInImage:image]) {
          CGRect box = CGRectMake(feature.bounds.origin.x / size.width, feature.bounds.origin.y / size.height, feature.bounds.size.width / size.width, feature.bounds.size.height / size.height);
          if (feature.messageString) { [found addObject:codeOf(AVMetadataObjectTypeQRCode, feature.messageString, box)]; }
        }
      }
      gCodes = found;
      return gCodes;
    }

    static void deliverMetadata(AVCaptureMetadataOutput *output) {
      id<AVCaptureMetadataOutputObjectsDelegate> delegate = output.metadataObjectsDelegate;
      dispatch_queue_t queue = output.metadataObjectsCallbackQueue;
      NSArray *wanted = output.metadataObjectTypes;
      if (!delegate || !queue || !wanted.count || ![delegate respondsToSelector:@selector(captureOutput:didOutputMetadataObjects:fromConnection:)]) { return; }
      NSMutableArray *objects = [NSMutableArray array];
      for (STCode *code in codes()) { if ([wanted containsObject:code.stType]) { [objects addObject:code]; } }
      if (!objects.count) { return; }
      STConnection *connection = connectionOf(output);
      dispatch_async(queue, ^{ [delegate captureOutput:output didOutputMetadataObjects:objects fromConnection:connection]; });
    }

    static NSString *gravity(AVLayerVideoGravity videoGravity) {
      if ([videoGravity isEqual:AVLayerVideoGravityResizeAspectFill]) { return kCAGravityResizeAspectFill; }
      if ([videoGravity isEqual:AVLayerVideoGravityResize]) { return kCAGravityResize; }
      return kCAGravityResizeAspect;
    }

    static void deliverPreview(void) {
      if (gPreviewGeneration == gGeneration || !gImage) { return; }
      gPreviewGeneration = gGeneration;
      CGImageRef image = CGImageRetain(gImage);
      NSArray *layers = gPreviewLayers.allObjects;
      dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (AVCaptureVideoPreviewLayer *layer in layers) {
          AVCaptureSession *session = layer.session;
          if (!session || !onSimToolCamera(session)) { continue; }
          layer.contentsGravity = gravity(layer.videoGravity);
          layer.contents = (__bridge id)image;
        }
        [CATransaction commit];
        CGImageRelease(image);
      });
    }

    static void heartbeat(void) {
      NSString *clients = [gDir stringByAppendingPathComponent:@"clients"];
      [[NSFileManager defaultManager] createDirectoryAtPath:clients withIntermediateDirectories:YES attributes:nil error:nil];
      BOOL running = NO;
      for (AVCaptureSession *session in gSessions.allObjects) { if ([objc_getAssociatedObject(session, &kRunning) boolValue]) { running = YES; } }
      NSDictionary *client = @{@"bundleId": NSBundle.mainBundle.bundleIdentifier ?: @"", @"pid": @(getpid()), @"running": @(running), @"at": @([[NSDate date] timeIntervalSince1970])};
      NSData *data = [NSJSONSerialization dataWithJSONObject:client options:0 error:nil];
      [data writeToFile:[clients stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.json", getpid()]] atomically:YES];
    }

    static void tick(void) {
      @autoreleasepool {
        if (gTicks % 10 == 0) { readConfig(); }
        if (gTicks % 30 == 0) { heartbeat(); }
        gTicks += 1;
        if (gKind == SourceVideo) { advanceVideo(); }
        if (gKind == SourceWebcam) { advanceWebcam(); }
        if (!gPixels) { return; }
        BOOL metadataDue = gTicks % 6 == 0;
        for (AVCaptureSession *session in gSessions.allObjects) {
          if (![objc_getAssociatedObject(session, &kRunning) boolValue]) { continue; }
          for (AVCaptureOutput *output in [associatedArray(session, &kOutputs) copy]) {
            if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) { deliverVideo((AVCaptureVideoDataOutput *)output); }
            else if (metadataDue && [output isKindOfClass:[AVCaptureMetadataOutput class]]) { deliverMetadata((AVCaptureMetadataOutput *)output); }
          }
        }
        deliverPreview();
      }
    }

    #pragma mark - photos

    static NSData *jpegOf(CGImageRef image) {
      NSMutableData *data = [NSMutableData data];
      CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, (__bridge CFStringRef)@"public.jpeg", 1, NULL);
      CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @0.9});
      CGImageDestinationFinalize(destination);
      CFRelease(destination);
      return data;
    }

    static int64_t gPhotoID;

    static void capturePhoto(AVCapturePhotoOutput *output, id<AVCapturePhotoCaptureDelegate> delegate) {
      __block CGImageRef image = NULL;
      __block CVPixelBufferRef pixels = NULL;
      dispatch_sync(gQueue, ^{
        if (gImage) { image = CGImageRetain(gImage); }
        if (gPixels) { pixels = CVPixelBufferRetain(gPixels); }
      });
      STResolvedSettings *settings = [STResolvedSettings alloc];
      settings.stID = ++gPhotoID;
      settings.stDimensions = (CMVideoDimensions){image ? (int32_t)CGImageGetWidth(image) : 0, image ? (int32_t)CGImageGetHeight(image) : 0};
      dispatch_async(gPhotoQueue, ^{
        if ([delegate respondsToSelector:@selector(captureOutput:willBeginCaptureForResolvedSettings:)]) { [delegate captureOutput:output willBeginCaptureForResolvedSettings:settings]; }
        if ([delegate respondsToSelector:@selector(captureOutput:willCapturePhotoForResolvedSettings:)]) { [delegate captureOutput:output willCapturePhotoForResolvedSettings:settings]; }
        if ([delegate respondsToSelector:@selector(captureOutput:didCapturePhotoForResolvedSettings:)]) { [delegate captureOutput:output didCapturePhotoForResolvedSettings:settings]; }
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
          STPhoto *photo = [STPhoto alloc];
          photo.stData = image ? jpegOf(image) : nil;
          photo.stImage = image ? CGImageRetain(image) : NULL;
          photo.stPixels = pixels ? CVPixelBufferRetain(pixels) : NULL;
          photo.stSettings = settings;
          NSError *error = image ? nil : [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorNoDataCaptured userInfo:@{NSLocalizedDescriptionKey: @"SimTool's camera has no picture yet"}];
          [delegate captureOutput:output didFinishProcessingPhoto:photo error:error];
        }
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishCaptureForResolvedSettings:error:)]) { [delegate captureOutput:output didFinishCaptureForResolvedSettings:settings error:nil]; }
        if (image) { CGImageRelease(image); }
        if (pixels) { CVPixelBufferRelease(pixels); }
      });
    }

    #pragma mark - swizzles
    // Each replacement is a category method exchanged with the original, so
    // calling the replacement's own name inside it calls the original.

    static void exchange(Class cls, SEL original, SEL replacement) {
      Method a = class_getInstanceMethod(cls, original), b = class_getInstanceMethod(cls, replacement);
      if (!a || !b) { NSLog(@"SimTool camera: %@ has no %@", cls, NSStringFromSelector(original)); return; }
      // Add first, so a method inherited from a superclass is replaced on this class only.
      if (class_addMethod(cls, original, method_getImplementation(b), method_getTypeEncoding(b))) {
        class_replaceMethod(cls, replacement, method_getImplementation(a), method_getTypeEncoding(a));
      } else {
        method_exchangeImplementations(a, b);
      }
    }

    static void exchangeClass(Class cls, SEL original, SEL replacement) { exchange(object_getClass(cls), original, replacement); }

    @implementation AVCaptureDevice (SimToolCamera)
    + (AVCaptureDevice *)simtool_defaultDeviceWithMediaType:(AVMediaType)mediaType {
      if (active() && [mediaType isEqual:AVMediaTypeVideo]) { return gBack; }
      return [self simtool_defaultDeviceWithMediaType:mediaType];
    }
    + (AVCaptureDevice *)simtool_defaultDeviceWithDeviceType:(AVCaptureDeviceType)deviceType mediaType:(AVMediaType)mediaType position:(AVCaptureDevicePosition)position {
      if (active() && (!mediaType || [mediaType isEqual:AVMediaTypeVideo])) { return fakeDevice(position); }
      return [self simtool_defaultDeviceWithDeviceType:deviceType mediaType:mediaType position:position];
    }
    + (NSArray *)simtool_devices {
      return active() ? [[self simtool_devices] arrayByAddingObjectsFromArray:fakeDevices()] : [self simtool_devices];
    }
    + (NSArray *)simtool_devicesWithMediaType:(AVMediaType)mediaType {
      if (active() && [mediaType isEqual:AVMediaTypeVideo]) { return fakeDevices(); }
      return [self simtool_devicesWithMediaType:mediaType];
    }
    + (AVCaptureDevice *)simtool_deviceWithUniqueID:(NSString *)uniqueID {
      for (STCameraDevice *device in fakeDevices()) { if ([device.uniqueID isEqual:uniqueID]) { return device; } }
      return [self simtool_deviceWithUniqueID:uniqueID];
    }
    @end

    @implementation AVCaptureDeviceDiscoverySession (SimToolCamera)
    + (instancetype)simtool_discoverySessionWithDeviceTypes:(NSArray<AVCaptureDeviceType> *)deviceTypes mediaType:(AVMediaType)mediaType position:(AVCaptureDevicePosition)position {
      AVCaptureDeviceDiscoverySession *session = [self simtool_discoverySessionWithDeviceTypes:deviceTypes mediaType:mediaType position:position];
      if (session && (!mediaType || [mediaType isEqual:AVMediaTypeVideo])) { objc_setAssociatedObject(session, &kPosition, @(position), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
      return session;
    }
    - (NSArray<AVCaptureDevice *> *)simtool_devices {
      NSNumber *position = objc_getAssociatedObject(self, &kPosition);
      if (!active() || !position) { return [self simtool_devices]; }
      if (position.integerValue == AVCaptureDevicePositionUnspecified) { return fakeDevices(); }
      return @[fakeDevice((AVCaptureDevicePosition)position.integerValue)];
    }
    @end

    static STCameraInput *inputFor(STCameraDevice *device) {
      STCameraInput *input = [STCameraInput alloc];
      input.stDevice = device;
      return input;
    }

    @implementation AVCaptureDeviceInput (SimToolCamera)
    + (instancetype)simtool_deviceInputWithDevice:(AVCaptureDevice *)device error:(NSError **)outError {
      if ([device isKindOfClass:[STCameraDevice class]]) { return inputFor((STCameraDevice *)device); }
      return [self simtool_deviceInputWithDevice:device error:outError];
    }
    - (instancetype)initSimToolWithDevice:(AVCaptureDevice *)device error:(NSError **)outError {
      if ([device isKindOfClass:[STCameraDevice class]]) { self = inputFor((STCameraDevice *)device); return self; }
      return [self initSimToolWithDevice:device error:outError];
    }
    @end

    @implementation AVCaptureSession (SimToolCamera)
    - (BOOL)simtool_canAddInput:(AVCaptureInput *)input {
      return [input isKindOfClass:[STCameraInput class]] || [self simtool_canAddInput:input];
    }
    - (void)simtool_addInput:(AVCaptureInput *)input {
      if (![input isKindOfClass:[STCameraInput class]]) { [self simtool_addInput:input]; return; }
      dispatch_sync(gQueue, ^{ if (![associatedArray(self, &kInputs) containsObject:input]) { [associatedArray(self, &kInputs) addObject:input]; } });
    }
    - (void)simtool_addInputWithNoConnections:(AVCaptureInput *)input {
      if ([input isKindOfClass:[STCameraInput class]]) { [self addInput:input]; return; }
      [self simtool_addInputWithNoConnections:input];
    }
    - (void)simtool_removeInput:(AVCaptureInput *)input {
      if (![input isKindOfClass:[STCameraInput class]]) { [self simtool_removeInput:input]; return; }
      dispatch_sync(gQueue, ^{ [associatedArray(self, &kInputs) removeObject:input]; });
    }
    - (NSArray<AVCaptureInput *> *)simtool_inputs {
      __block NSArray *fake = nil;
      dispatch_sync(gQueue, ^{ fake = [associatedArray(self, &kInputs) copy]; });
      return [[self simtool_inputs] arrayByAddingObjectsFromArray:fake];
    }
    - (BOOL)simtool_canAddOutput:(AVCaptureOutput *)output {
      return [self simtool_canAddOutput:output] || active() || onSimToolCamera(self);
    }
    // The output joins the session for real when AVFoundation lets it, and is
    // fed by SimTool's camera either way.
    - (void)simtool_addOutput:(AVCaptureOutput *)output {
      @try { [self simtool_addOutput:output]; } @catch (NSException *exception) {}
      STWeakBox *box = [STWeakBox new];
      box.object = self;
      objc_setAssociatedObject(output, &kSession, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      dispatch_sync(gQueue, ^{ if (![associatedArray(self, &kOutputs) containsObject:output]) { [associatedArray(self, &kOutputs) addObject:output]; } });
    }
    - (void)simtool_addOutputWithNoConnections:(AVCaptureOutput *)output { [self addOutput:output]; }
    - (void)simtool_removeOutput:(AVCaptureOutput *)output {
      @try { [self simtool_removeOutput:output]; } @catch (NSException *exception) {}
      dispatch_sync(gQueue, ^{ [associatedArray(self, &kOutputs) removeObject:output]; });
    }
    - (NSArray<AVCaptureOutput *> *)simtool_outputs {
      NSMutableArray *outputs = [[self simtool_outputs] mutableCopy];
      __block NSArray *ours = nil;
      dispatch_sync(gQueue, ^{ ours = [associatedArray(self, &kOutputs) copy]; });
      for (AVCaptureOutput *output in ours) { if (![outputs containsObject:output]) { [outputs addObject:output]; } }
      return outputs;
    }
    - (void)simtool_startRunning {
      if (!onSimToolCamera(self)) { [self simtool_startRunning]; return; }
      dispatch_sync(gQueue, ^{
        objc_setAssociatedObject(self, &kRunning, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [gSessions addObject:self];
        gPreviewGeneration = 0;
      });
      [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionDidStartRunningNotification object:self];
    }
    - (void)simtool_stopRunning {
      if (!onSimToolCamera(self)) { [self simtool_stopRunning]; return; }
      dispatch_sync(gQueue, ^{
        objc_setAssociatedObject(self, &kRunning, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [gSessions removeObject:self];
      });
      [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionDidStopRunningNotification object:self];
    }
    - (BOOL)simtool_isRunning {
      if (!onSimToolCamera(self)) { return [self simtool_isRunning]; }
      return [objc_getAssociatedObject(self, &kRunning) boolValue];
    }
    @end

    @implementation AVCaptureOutput (SimToolCamera)
    - (AVCaptureConnection *)simtool_connectionWithMediaType:(AVMediaType)mediaType {
      if (outputOnSimToolCamera(self) && [mediaType isEqual:AVMediaTypeVideo]) { return connectionOf(self); }
      return [self simtool_connectionWithMediaType:mediaType];
    }
    @end

    @implementation AVCaptureMetadataOutput (SimToolCamera)
    - (NSArray<AVMetadataObjectType> *)simtool_availableMetadataObjectTypes {
      if (active() || outputOnSimToolCamera(self)) { return symbologies().allValues; }
      return [self simtool_availableMetadataObjectTypes];
    }
    - (void)simtool_setMetadataObjectTypes:(NSArray<AVMetadataObjectType> *)types {
      objc_setAssociatedObject(self, &kTypes, [types copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      @try { [self simtool_setMetadataObjectTypes:types]; } @catch (NSException *exception) {}
    }
    - (NSArray<AVMetadataObjectType> *)simtool_metadataObjectTypes {
      NSArray *types = objc_getAssociatedObject(self, &kTypes);
      return types ?: [self simtool_metadataObjectTypes];
    }
    @end

    @implementation AVCapturePhotoOutput (SimToolCamera)
    - (void)simtool_capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
      if (!outputOnSimToolCamera(self)) { [self simtool_capturePhotoWithSettings:settings delegate:delegate]; return; }
      capturePhoto(self, delegate);
    }
    @end

    @implementation AVCaptureVideoPreviewLayer (SimToolCamera)
    static void notePreviewLayer(AVCaptureVideoPreviewLayer *layer) {
      dispatch_async(gQueue, ^{ [gPreviewLayers addObject:layer]; gPreviewGeneration = 0; });
    }
    - (void)simtool_setSession:(AVCaptureSession *)session { [self simtool_setSession:session]; notePreviewLayer(self); }
    - (void)simtool_setSessionWithNoConnection:(AVCaptureSession *)session { [self simtool_setSessionWithNoConnection:session]; notePreviewLayer(self); }
    - (instancetype)initSimToolWithSession:(AVCaptureSession *)session {
      self = [self initSimToolWithSession:session];
      if (self) { notePreviewLayer(self); }
      return self;
    }
    - (instancetype)initSimToolWithSessionWithNoConnection:(AVCaptureSession *)session {
      self = [self initSimToolWithSessionWithNoConnection:session];
      if (self) { notePreviewLayer(self); }
      return self;
    }
    @end

    #pragma mark - UIImagePickerController

    static UIImage *currentPicture(void) {
      __block CGImageRef image = NULL;
      dispatch_sync(gQueue, ^{ if (gImage) { image = CGImageRetain(gImage); } });
      if (!image) { return nil; }
      UIImage *picture = [UIImage imageWithCGImage:image];
      CGImageRelease(image);
      return picture;
    }

    @implementation UIImagePickerController (SimToolCamera)
    + (BOOL)simtool_isSourceTypeAvailable:(UIImagePickerControllerSourceType)sourceType {
      if (active() && sourceType == UIImagePickerControllerSourceTypeCamera) { return YES; }
      return [self simtool_isSourceTypeAvailable:sourceType];
    }
    + (NSArray<NSString *> *)simtool_availableMediaTypesForSourceType:(UIImagePickerControllerSourceType)sourceType {
      if (active() && sourceType == UIImagePickerControllerSourceTypeCamera) { return @[@"public.image"]; }
      return [self simtool_availableMediaTypesForSourceType:sourceType];
    }
    + (BOOL)simtool_isCameraDeviceAvailable:(UIImagePickerControllerCameraDevice)cameraDevice {
      return active() || [self simtool_isCameraDeviceAvailable:cameraDevice];
    }
    + (NSArray<NSNumber *> *)simtool_availableCaptureModesForCameraDevice:(UIImagePickerControllerCameraDevice)cameraDevice {
      if (active()) { return @[@(UIImagePickerControllerCameraCaptureModePhoto)]; }
      return [self simtool_availableCaptureModesForCameraDevice:cameraDevice];
    }
    @end

    // A camera picker is never shown: it answers its delegate at once with the
    // camera's picture, as if the person had taken it and tapped Use Photo.
    @implementation UIViewController (SimToolCamera)
    - (void)simtool_presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
      UIImagePickerController *picker = [controller isKindOfClass:[UIImagePickerController class]] ? (UIImagePickerController *)controller : nil;
      if (!picker || !active() || picker.sourceType != UIImagePickerControllerSourceTypeCamera) {
        [self simtool_presentViewController:controller animated:animated completion:completion];
        return;
      }
      UIImage *picture = currentPicture();
      dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) { completion(); }
        id<UIImagePickerControllerDelegate, UINavigationControllerDelegate> delegate = picker.delegate;
        if (picture && [delegate respondsToSelector:@selector(imagePickerController:didFinishPickingMediaWithInfo:)]) {
          [delegate imagePickerController:picker didFinishPickingMediaWithInfo:@{UIImagePickerControllerOriginalImage: picture, UIImagePickerControllerMediaType: @"public.image"}];
        } else if ([delegate respondsToSelector:@selector(imagePickerControllerDidCancel:)]) {
          [delegate imagePickerControllerDidCancel:picker];
        }
      });
    }
    @end

    #pragma mark - start

    __attribute__((constructor))
    static void SimToolCameraStart(void) {
      @autoreleasepool {
        NSString *dir = NSProcessInfo.processInfo.environment[@"SIMTOOL_CAMERA_DIR"];
        if (!dir.length) { return; }
        gDir = dir;
        gPresent = [NSProcessInfo.processInfo.environment[@"SIMTOOL_CAMERA_PRESENT"] isEqual:@"1"];
        gQueue = dispatch_queue_create("simtool.camera", DISPATCH_QUEUE_SERIAL);
        gPhotoQueue = dispatch_queue_create("simtool.camera.photo", DISPATCH_QUEUE_SERIAL);
        gSessions = [NSHashTable weakObjectsHashTable];
        gPreviewLayers = [NSHashTable weakObjectsHashTable];
        gBack = [STCameraDevice alloc];
        gBack.stPosition = AVCaptureDevicePositionBack;
        gFront = [STCameraDevice alloc];
        gFront.stPosition = AVCaptureDevicePositionFront;

        exchangeClass([AVCaptureDevice class], @selector(defaultDeviceWithMediaType:), @selector(simtool_defaultDeviceWithMediaType:));
        exchangeClass([AVCaptureDevice class], @selector(defaultDeviceWithDeviceType:mediaType:position:), @selector(simtool_defaultDeviceWithDeviceType:mediaType:position:));
        exchangeClass([AVCaptureDevice class], @selector(devices), @selector(simtool_devices));
        exchangeClass([AVCaptureDevice class], @selector(devicesWithMediaType:), @selector(simtool_devicesWithMediaType:));
        exchangeClass([AVCaptureDevice class], @selector(deviceWithUniqueID:), @selector(simtool_deviceWithUniqueID:));
        exchangeClass([AVCaptureDeviceDiscoverySession class], @selector(discoverySessionWithDeviceTypes:mediaType:position:), @selector(simtool_discoverySessionWithDeviceTypes:mediaType:position:));
        exchange([AVCaptureDeviceDiscoverySession class], @selector(devices), @selector(simtool_devices));
        exchangeClass([AVCaptureDeviceInput class], @selector(deviceInputWithDevice:error:), @selector(simtool_deviceInputWithDevice:error:));
        exchange([AVCaptureDeviceInput class], @selector(initWithDevice:error:), @selector(initSimToolWithDevice:error:));
        for (NSString *name in @[@"canAddInput:", @"addInput:", @"addInputWithNoConnections:", @"removeInput:", @"inputs", @"canAddOutput:", @"addOutput:",
                                 @"addOutputWithNoConnections:", @"removeOutput:", @"outputs", @"startRunning", @"stopRunning", @"isRunning"]) {
          exchange([AVCaptureSession class], NSSelectorFromString(name), NSSelectorFromString([@"simtool_" stringByAppendingString:name]));
        }
        exchange([AVCaptureOutput class], @selector(connectionWithMediaType:), @selector(simtool_connectionWithMediaType:));
        exchange([AVCaptureMetadataOutput class], @selector(availableMetadataObjectTypes), @selector(simtool_availableMetadataObjectTypes));
        exchange([AVCaptureMetadataOutput class], @selector(setMetadataObjectTypes:), @selector(simtool_setMetadataObjectTypes:));
        exchange([AVCaptureMetadataOutput class], @selector(metadataObjectTypes), @selector(simtool_metadataObjectTypes));
        exchange([AVCapturePhotoOutput class], @selector(capturePhotoWithSettings:delegate:), @selector(simtool_capturePhotoWithSettings:delegate:));
        exchange([AVCaptureVideoPreviewLayer class], @selector(setSession:), @selector(simtool_setSession:));
        exchange([AVCaptureVideoPreviewLayer class], @selector(setSessionWithNoConnection:), @selector(simtool_setSessionWithNoConnection:));
        exchange([AVCaptureVideoPreviewLayer class], @selector(initWithSession:), @selector(initSimToolWithSession:));
        exchange([AVCaptureVideoPreviewLayer class], @selector(initWithSessionWithNoConnection:), @selector(initSimToolWithSessionWithNoConnection:));
        exchangeClass([UIImagePickerController class], @selector(isSourceTypeAvailable:), @selector(simtool_isSourceTypeAvailable:));
        exchangeClass([UIImagePickerController class], @selector(availableMediaTypesForSourceType:), @selector(simtool_availableMediaTypesForSourceType:));
        exchangeClass([UIImagePickerController class], @selector(isCameraDeviceAvailable:), @selector(simtool_isCameraDeviceAvailable:));
        exchangeClass([UIImagePickerController class], @selector(availableCaptureModesForCameraDevice:), @selector(simtool_availableCaptureModesForCameraDevice:));
        exchange([UIViewController class], @selector(presentViewController:animated:completion:), @selector(simtool_presentViewController:animated:completion:));

        dispatch_sync(gQueue, ^{ readConfig(); heartbeat(); });
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(NSEC_PER_SEC / FramesPerSecond), NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{ tick(); });
        dispatch_resume(timer);
        static dispatch_source_t keep;
        keep = timer;
        NSLog(@"SimTool camera: ready (%@)", dir);
      }
    }
    """#
}
