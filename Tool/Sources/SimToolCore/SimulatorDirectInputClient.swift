import CryptoKit
import Foundation

/// Touches the simulator the way Simulator.app does: Indigo HID messages built
/// by SimulatorKit and sent through `SimDeviceLegacyHIDClient`, from one helper
/// process per device that stays up between touches. The same helper types as
/// a hardware keyboard, the way Device Hub does on Xcode 27 (see the helper's
/// keyboard section).
///
/// Two ways in. Answered commands — a tap, a timed `TouchPath`, a shortcut —
/// return once done. Live events (`stream`) are written and forgotten: a
/// finger that follows a pointer cannot wait for a reply per move, so the helper
/// coalesces moves itself and never drops a down or an up; keys ride along in
/// the same order.
public actor SimulatorDirectInputClient {
    public static let shared = SimulatorDirectInputClient()

    private static let helperVersion = "4"
    /// Part of the cached binary's name, so any change to the helper's source
    /// compiles a fresh one instead of reusing a stale build of the same version.
    private static let helperFingerprint = SHA256.hash(data: Data(SimulatorDirectInputHelperSource.source.utf8))
        .prefix(6)
        .map { String(format: "%02x", $0) }
        .joined()

    private var session: SimulatorDirectInputSession?
    private var starting: (udid: String, task: Task<SimulatorDirectInputSession, Error>)?
    private var screenSizes: [String: SimulatorScreenSize] = [:]
    /// Answered commands share the helper's stdout, so one runs at a time.
    private var answering = false
    private var answerQueue: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Starts the helper ahead of the first touch, so that touch lands without
    /// the compile-and-launch delay.
    public func prepare(deviceUDID: String) async throws {
        _ = try await session(for: deviceUDID)
    }

    public func tap(xRatio: Double, yRatio: Double, deviceUDID: String) async throws {
        try await answered(
            SimulatorDirectInputCommand.tap(x: xRatio, y: yRatio).line,
            deviceUDID: deviceUDID,
            timeoutSeconds: 2
        )
    }

    /// Plays a timed path and returns once the finger has lifted.
    public func perform(_ path: TouchPath, deviceUDID: String) async throws {
        try await answered(path.helperLine, deviceUDID: deviceUDID, timeoutSeconds: path.duration + 3)
    }

    /// Plays a stroke given in screen points.
    public func perform(_ stroke: TouchStroke, deviceUDID: String) async throws {
        let screen = try await screenSize(deviceUDID: deviceUDID)
        try await perform(stroke.path(on: screen), deviceUDID: deviceUDID)
    }

    /// Writes one live event and returns without waiting for the simulator.
    /// Events reach the helper in the order of these calls; a failure drops the
    /// helper, and the next event starts a fresh one.
    public func stream(_ event: LiveTouchEvent, deviceUDID: String) async {
        await stream(line: event.helperLine, deviceUDID: deviceUDID)
    }

    /// Writes one live key event, in order with the live touches.
    public func stream(_ event: LiveKeyEvent, deviceUDID: String) async {
        await stream(line: event.helperLine, deviceUDID: deviceUDID)
    }

    /// Presses `key` with `modifiers` held — a shortcut such as ⌘V.
    public func press(_ key: KeyboardKey, modifiers: [KeyboardKey] = [], deviceUDID: String) async throws {
        try await answered(SimulatorDirectInputCommand.press(key, modifiers: modifiers).line, deviceUDID: deviceUDID, timeoutSeconds: Self.keyboardTimeout)
    }

    /// Presses Eject, which toggles the software keyboard.
    public func toggleSoftwareKeyboard(deviceUDID: String) async throws {
        try await answered(SimulatorDirectInputCommand.ejectKey.line, deviceUDID: deviceUDID, timeoutSeconds: Self.keyboardTimeout)
    }

    public func setHardwareKeyboard(connected: Bool, deviceUDID: String) async throws {
        try await answered(SimulatorDirectInputCommand.hardwareKeyboard(connected: connected).line, deviceUDID: deviceUDID, timeoutSeconds: Self.keyboardTimeout)
    }

    /// Room for the helper's first key to connect to the guest's keyboard
    /// daemon, which may have to start first.
    private static let keyboardTimeout: TimeInterval = 7

    private func stream(line: String, deviceUDID: String) async {
        do {
            let current = try await session(for: deviceUDID)
            try current.write(line)
        } catch {
            DirectInputLog.write("stream failed command=\(line) error=\(error.localizedDescription)")
            dropSession()
        }
    }

    /// The screen in points, read once per device from its device type.
    public func screenSize(deviceUDID: String) async throws -> SimulatorScreenSize {
        if let cached = screenSizes[deviceUDID] { return cached }
        let answer = try await answered("size", deviceUDID: deviceUDID, timeoutSeconds: 2)
        guard let size = SimulatorDirectInputCommand.screenSize(fromAnswer: answer) else {
            throw SimToolError("Direct input helper reported no screen size: \(answer)")
        }
        screenSizes[deviceUDID] = size
        return size
    }

    public func close() {
        dropSession()
    }

    private func dropSession() {
        session?.stop()
        session = nil
    }

    /// Sends a command the helper answers, and returns the answer. A helper that
    /// died or went silent is replaced and the command sent once more; an
    /// explicit refusal (`err`) is not retried.
    @discardableResult
    private func answered(_ line: String, deviceUDID: String, timeoutSeconds: TimeInterval, retry: Bool = true) async throws -> String {
        await acquireAnswerSlot()
        defer { releaseAnswerSlot() }
        return try await exchange(line, deviceUDID: deviceUDID, timeoutSeconds: timeoutSeconds, retry: retry)
    }

    private func exchange(_ line: String, deviceUDID: String, timeoutSeconds: TimeInterval, retry: Bool) async throws -> String {
        DirectInputLog.write("send begin command=\(line.prefix(80)) udid=\(deviceUDID) retry=\(retry)")
        let current = try await session(for: deviceUDID)
        let response: String
        do {
            try current.write(line)
            guard let answer = try await current.readLine(timeoutSeconds: timeoutSeconds) else {
                DirectInputLog.write("response eof message=\(current.exitMessage())")
                throw SimToolError(current.exitMessage())
            }
            response = answer
        } catch {
            DirectInputLog.write("send failed error=\(error.localizedDescription)")
            current.stop()
            if session === current { session = nil }
            if retry {
                return try await exchange(line, deviceUDID: deviceUDID, timeoutSeconds: timeoutSeconds, retry: false)
            }
            throw error
        }
        DirectInputLog.write("response value=\(response)")
        guard response == "ok" || response.hasPrefix("ok ") else {
            let reason = response.hasPrefix("err ") ? String(response.dropFirst(4)) : response
            throw SimToolError("The simulator refused the input (\(reason)).")
        }
        return response
    }

    private func acquireAnswerSlot() async {
        guard answering else {
            answering = true
            return
        }
        await withCheckedContinuation { answerQueue.append($0) }
    }

    private func releaseAnswerSlot() {
        if answerQueue.isEmpty {
            answering = false
        } else {
            answerQueue.removeFirst().resume()
        }
    }

    private func session(for deviceUDID: String) async throws -> SimulatorDirectInputSession {
        if let session, session.deviceUDID == deviceUDID, session.isRunning {
            return session
        }
        // Concurrent callers share one launch instead of racing two helpers.
        if let starting, starting.udid == deviceUDID {
            return try await starting.task.value
        }
        dropSession()
        let task = Task { try await self.launchSession(deviceUDID: deviceUDID) }
        starting = (deviceUDID, task)
        do {
            let next = try await task.value
            starting = nil
            session = next
            return next
        } catch {
            starting = nil
            throw error
        }
    }

    private func launchSession(deviceUDID: String) async throws -> SimulatorDirectInputSession {
        let helperURL = try await helperExecutableURL()
        DirectInputLog.write("start helper path=\(helperURL.path) udid=\(deviceUDID)")
        let next = SimulatorDirectInputSession(helperURL: helperURL, deviceUDID: deviceUDID)
        try next.start()
        DirectInputLog.write("started helper pid=\(next.processIdentifier) udid=\(deviceUDID)")
        return next
    }

    private func helperExecutableURL() async throws -> URL {
        let directory = try helperDirectoryURL()
        let outputURL = directory.appendingPathComponent("simtool-direct-hid-\(Self.helperVersion)-\(Self.helperFingerprint)-\(simulatorArch)")
        if FileManager.default.isExecutableFile(atPath: outputURL.path) {
            DirectInputLog.write("using cached helper path=\(outputURL.path)")
            return outputURL
        }
        DirectInputLog.write("compile helper path=\(outputURL.path)")
        try await compileHelper(to: outputURL)
        return outputURL
    }

    /// Several simtool processes (a server per simulator, a CLI command) can
    /// compile the same helper at once, so each works on its own files and the
    /// result is renamed into place, which replaces atomically.
    private func compileHelper(to outputURL: URL) async throws {
        let unique = UUID().uuidString
        let sourceURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(outputURL.lastPathComponent).\(unique).m")
        let tempURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(outputURL.lastPathComponent).tmp.\(unique)")

        try SimulatorDirectInputHelperSource.source.write(to: sourceURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: tempURL)
        }

        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "clang",
                "-arch", simulatorArch,
                "-fobjc-arc",
                "-framework", "Foundation",
                "-framework", "CoreGraphics",
                "-o", tempURL.path,
                sourceURL.path,
            ],
            timeoutSeconds: 20
        )
        guard output.status == 0 else {
            throw SimToolError(output.stderrString.isEmpty ? "Failed to compile direct input helper" : output.stderrString)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
        guard rename(tempURL.path, outputURL.path) == 0 else {
            throw SimToolError("Failed to install the direct input helper: \(String(cString: strerror(errno)))")
        }
    }

    private func helperDirectoryURL() throws -> URL {
        guard let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw SimToolError("Failed to locate user caches directory")
        }
        let directory = cacheRoot
            .appendingPathComponent("SimTool", isDirectory: true)
            .appendingPathComponent("SimulatorHelpers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var simulatorArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}

/// The helper's line protocol, apart from what `LiveTouchEvent` and
/// `TouchPath` encode themselves.
struct SimulatorDirectInputCommand: Equatable {
    var line: String

    static func tap(x: Double, y: Double) -> Self {
        Self(line: "tap \(TouchRatio(x: x, y: y).helperText)")
    }

    /// The helper holds at most three modifiers; extra ones are dropped.
    static func press(_ key: KeyboardKey, modifiers: [KeyboardKey]) -> Self {
        Self(line: (["press", "\(key.usage)"] + modifiers.prefix(3).map { "\($0.usage)" }).joined(separator: " "))
    }

    /// Eject, on the Consumer page (12).
    static let ejectKey = Self(line: "button 12 184")

    static func hardwareKeyboard(connected: Bool) -> Self {
        Self(line: "hwkeyboard \(connected ? 1 : 0)")
    }

    /// Reads `ok W H SCALE`, the helper's answer to `size`.
    static func screenSize(fromAnswer answer: String) -> SimulatorScreenSize? {
        let parts = answer.split(separator: " ").dropFirst().compactMap { Double($0) }
        guard parts.count == 3, parts[0] > 0, parts[1] > 0, parts[2] > 0 else { return nil }
        return SimulatorScreenSize(width: parts[0], height: parts[1], scale: parts[2])
    }
}

private final class SimulatorDirectInputSession: @unchecked Sendable {
    let deviceUDID: String

    private let helperURL: URL
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()

    init(helperURL: URL, deviceUDID: String) {
        self.helperURL = helperURL
        self.deviceUDID = deviceUDID
    }

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    func start() throws {
        process.executableURL = helperURL
        process.arguments = [deviceUDID]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPath(env["PATH"])
        env["DEVELOPER_DIR"] = developerDir()
        process.environment = env
        try process.run()
        // A helper that died between two writes must fail the write, not
        // SIGPIPE the server.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func write(_ line: String) throws {
        guard isRunning else { throw SimToolError(exitMessage()) }
        try inputPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func readLine(timeoutSeconds: TimeInterval) async throws -> String? {
        let handle = outputPipe.fileHandleForReading
        return try await withCheckedThrowingContinuation { continuation in
            let state = DirectInputReadLineState(handle: handle, continuation: continuation)

            DirectInputLog.write("install read handler timeout=\(timeoutSeconds)")
            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                guard !data.isEmpty else {
                    state.finish(.success(nil))
                    return
                }
                if let line = state.append(data) {
                    state.finish(.success(line))
                }
            }

            state.setTimeoutTask(Task {
                try? await Task.sleep(for: .milliseconds(Int(timeoutSeconds * 1000)))
                guard !Task.isCancelled else { return }
                DirectInputLog.write("read timeout fired")
                state.finish(.failure(SimToolError("Direct input helper timed out")))
            })
        }
    }

    /// Asks the helper to lift any finger and exit, and terminates it if it
    /// has not within half a second.
    func stop() {
        guard isRunning else { return }
        try? inputPipe.fileHandleForWriting.write(contentsOf: Data("q\n".utf8))
        try? inputPipe.fileHandleForWriting.close()
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { process.terminate() }
        }
    }

    func exitMessage() -> String {
        if process.isRunning { return "Direct simulator input helper produced no response." }
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? "Direct simulator input helper exited." : message
    }

    private func developerDir() -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        task.arguments = ["-p"]
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "/Applications/Xcode.app/Contents/Developer"
    }

    private func augmentedPath(_ existing: String?) -> String {
        let extras = ["/opt/homebrew/bin", "/usr/local/bin"]
        var components = (existing ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        for extra in extras.reversed() where !components.contains(extra) {
            components.insert(extra, at: 0)
        }
        return components.joined(separator: ":")
    }
}

private final class DirectInputReadLineState: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let continuation: CheckedContinuation<String?, Error>
    private var buffer = Data()
    private var completed = false
    private var timeoutTask: Task<Void, Never>?

    init(handle: FileHandle, continuation: CheckedContinuation<String?, Error>) {
        self.handle = handle
        self.continuation = continuation
    }

    func append(_ data: Data) -> String? {
        lock.withLock {
            guard !completed else { return nil }
            buffer.append(data)
            guard let newline = buffer.firstIndex(of: 10) else { return nil }
            let line = buffer[..<newline]
            return String(data: line, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard !completed else { return true }
            timeoutTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func finish(_ result: Result<String?, Error>) {
        let task = lock.withLock {
            guard !completed else { return nil as Task<Void, Never>? }
            completed = true
            return timeoutTask
        }
        handle.readabilityHandler = nil
        task?.cancel()
        continuation.resume(with: result)
    }

}

private enum DirectInputLog {
    static func write(_ message: String) {
        DebugLog.write("SimToolDirectInput", message)
    }
}

enum SimulatorDirectInputHelperSource {
    static let source = #"""
    #import <Foundation/Foundation.h>
    #import <CoreGraphics/CoreGraphics.h>
    #import <objc/message.h>
    #import <objc/runtime.h>
    #import <dispatch/dispatch.h>
    #import <dlfcn.h>
    #import <mach/mach_time.h>
    #import <pthread.h>
    #import <stdio.h>
    #import <stdlib.h>
    #import <string.h>
    #import <math.h>
    #import <time.h>
    #import <unistd.h>
    #import <xpc/xpc.h>

    // Touches one booted simulator through SimulatorKit's Indigo HID messages,
    // and types on it as a hardware keyboard. Commands arrive one per line on
    // stdin; coordinates are fractions of the screen (0…1 from the top-left
    // corner), keys USB HID usages on the keyboard page (4 is A, 225 left shift).
    //
    // Answered "ok" (or "err [reason]") once done:
    //   tap X Y [MS]            down, rest MS ms (default 60), up
    //   swipe X1 Y1 X2 Y2 MS    straight line, lifted in motion
    //   path P,MS,X,Y …         timed touch path: P is d, m or u, MS the offset
    //                           from the start; the finger is lifted even on error
    //   size                    "ok W H SCALE" — the screen in points
    //   press K [M …]           key K with up to three modifier keys M held
    //   button PAGE USAGE       presses one HID usage of another page; 12 184
    //                           (Eject) toggles the software keyboard
    //   hwkeyboard 1|0          connects or disconnects the hardware keyboard
    // Streamed, never answered (a live finger must not wait on a reply):
    //   down X Y | move X Y | up X Y
    //   down2 X1 Y1 X2 Y2 | move2 … | up2 …     two fingers
    //   key K 1|0               key K down (1) or up (0)
    // q (or end of input) lifts any finger, releases any key and exits.
    //
    // Everything that builds or sends a message runs on one worker thread: the
    // builder keeps global state (its last-message time, the second finger).
    // Moves waiting in the queue coalesce — the latest position wins — while down
    // and up are never dropped, and a move still pending is sent before the up.

    static const unsigned long long Booted = 3;
    enum { DownType = 1, UpType = 2, DragType = 6 };   // NSEventType values the builder takes
    // The builder returns NULL for a dragged event built within 16 ms of its
    // previous message; waiting this long keeps every move.
    static const uint64_t DragGapNs = 16500000ULL;

    static void say(const char *s) { fprintf(stderr, "%s\n", s ?: "error"); }

    static uint64_t nowNs(void) {
      static mach_timebase_info_data_t base;
      if (base.denom == 0) { mach_timebase_info(&base); }
      return mach_absolute_time() * base.numer / base.denom;
    }

    static struct timespec deadlineIn(uint64_t ns) {
      struct timespec t;
      clock_gettime(CLOCK_REALTIME, &t);
      uint64_t total = (uint64_t)t.tv_nsec + ns;
      t.tv_sec += (time_t)(total / 1000000000ULL);
      t.tv_nsec = (long)(total % 1000000000ULL);
      return t;
    }

    static void sleepUntil(uint64_t deadline) {
      uint64_t now = nowNs();
      if (deadline > now) { usleep((useconds_t)((deadline - now) / 1000)); }
    }

    // Loads the first framework bundle that exists among the candidate paths.
    // Xcode <= 26 keeps SimulatorKit under Developer/Library/PrivateFrameworks;
    // Xcode 27 moved it to Contents/SharedFrameworks (outside DEVELOPER_DIR).
    static BOOL loadFramework(NSArray<NSString *> *candidates) {
      for (NSString *path in candidates) {
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        if (bundle && [bundle load]) { return YES; }
      }
      return NO;
    }

    static NSString *developerDir(void) {
      NSString *dev = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
      return dev.length > 0 ? dev : @"/Applications/Xcode.app/Contents/Developer";
    }

    static BOOL loadFrameworks(void) {
      NSString *dev = developerDir();
      NSArray *coreSim = @[
        @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework",
        [dev stringByAppendingPathComponent:@"Library/PrivateFrameworks/CoreSimulator.framework"],
        [dev stringByAppendingPathComponent:@"../SharedFrameworks/CoreSimulator.framework"],
      ];
      if (!loadFramework(coreSim)) { say("Failed to load CoreSimulator"); return NO; }
      NSArray *simKit = @[
        [dev stringByAppendingPathComponent:@"Library/PrivateFrameworks/SimulatorKit.framework"],
        [dev stringByAppendingPathComponent:@"../SharedFrameworks/SimulatorKit.framework"],
        @"/Library/Developer/PrivateFrameworks/SimulatorKit.framework",
      ];
      if (!loadFramework(simKit)) { say("Failed to load SimulatorKit"); return NO; }
      return YES;
    }

    static id bootedDevice(NSString *udid, NSError **error) {
      Class cls = objc_getClass("SimServiceContext");
      id ctx = ((id (*)(Class, SEL, NSString *, NSError **))objc_msgSend)(cls, sel_registerName("sharedServiceContextForDeveloperDir:error:"), developerDir(), error);
      if (!ctx) { return nil; }
      id set = ((id (*)(id, SEL, NSError **))objc_msgSend)(ctx, sel_registerName("defaultDeviceSetWithError:"), error);
      if (!set) { return nil; }
      NSArray *devices = ((NSArray * (*)(id, SEL))objc_msgSend)(set, sel_registerName("devices"));
      for (id d in devices) {
        unsigned long long state = ((unsigned long long (*)(id, SEL))objc_msgSend)(d, sel_registerName("state"));
        if (state != Booted) { continue; }
        NSUUID *uuid = ((NSUUID * (*)(id, SEL))objc_msgSend)(d, sel_registerName("UDID"));
        if (udid.length == 0 || [uuid.UUIDString.lowercaseString isEqualToString:udid.lowercaseString]) { return d; }
      }
      if (error) { *error = [NSError errorWithDomain:@"SimToolHID" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No matching booted simulator"}]; }
      return nil;
    }

    static Class hidClientClass(void) {
      Class c = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
      if (!c) { c = NSClassFromString(@"SimDeviceLegacyHIDClient"); }
      return c ?: objc_lookUpClass("SimDeviceLegacyHIDClient");
    }

    static id device;
    static id client;
    static double pixelX = 0.001, pixelY = 0.001; // one device pixel, in screen fractions
    static void (*sendMessage)(id, SEL, void *, BOOL, dispatch_queue_t, id);
    static SEL sendSelector;
    static void *(*buildMouse)(CGPoint *, CGPoint *, unsigned int, int, CGFloat, CGFloat, unsigned int);
    static void *(*buildKey)(unsigned int usage, unsigned int op);
    static void *(*buildUsage)(unsigned int target, unsigned int page, unsigned int usage, unsigned int op);
    static BOOL keysOverDTUHID = NO;

    static BOOL openClient(NSString *udid) {
      NSError *err = nil;
      device = bootedDevice(udid, &err);
      if (!device) { say(err.localizedDescription.UTF8String); return NO; }
      Class cls = hidClientClass();
      if (!cls) { say("SimDeviceLegacyHIDClient class not found"); return NO; }
      id alloc = ((id (*)(Class, SEL))objc_msgSend)(cls, sel_registerName("alloc"));
      client = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(alloc, sel_registerName("initWithDevice:error:"), device, &err);
      if (!client) { say((err.localizedDescription ?: @"initWithDevice failed").UTF8String); return NO; }
      sendSelector = sel_registerName("sendWithMessage:freeWhenDone:completionQueue:completion:");
      Method method = class_getInstanceMethod([client class], sendSelector);
      if (!method) { say("sendWithMessage not found"); return NO; }
      sendMessage = (void *)method_getImplementation(method);
      buildMouse = (void *)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForMouseNSEvent");
      if (!buildMouse) { say("IndigoHIDMessageForMouseNSEvent not found"); return NO; }
      id type = ((id (*)(id, SEL))objc_msgSend)(device, sel_registerName("deviceType"));
      CGSize pixels = ((CGSize (*)(id, SEL))objc_msgSend)(type, sel_registerName("mainScreenSize"));
      if (pixels.width > 0 && pixels.height > 0) { pixelX = 1.0 / pixels.width; pixelY = 1.0 / pixels.height; }
      buildKey = (void *)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForKeyboardArbitrary");
      buildUsage = (void *)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForHIDArbitrary");
      NSString *coreSimulator = [NSBundle bundleForClass:[device class]].infoDictionary[@"CFBundleVersion"];
      keysOverDTUHID = coreSimulator && [coreSimulator compare:@"1155.4" options:NSNumericSearch] != NSOrderedAscending;
      return YES;
    }

    // MARK: - the keyboard (worker thread only)
    //
    // From CoreSimulator 1155.4 (Xcode 27) the guest drops legacy Indigo
    // keyboard and button input. There keys go the way Device Hub sends them:
    // as XPC messages to the guest's dtuhidd, over a connection built from the
    // simulator's Mach port. Older toolchains take them as Indigo messages.

    static const char *DigitizerService = "com.apple.coredevice.feature.remote.hid.digitizer";
    static xpc_connection_t dtuhid;
    static volatile int dtuhidBroken = 0;   // set by XPC when the connection dies
    static const char *dtuhidFailure;       // why the last attempt failed,
    static uint64_t dtuhidRetryNs = 0;      // repeated without retrying until then
    static unsigned char held[256];         // keys this helper holds down

    static xpc_object_t dtuhidMessage(const char *type, xpc_object_t payload, bool barrier) {
      xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
      xpc_dictionary_set_string(message, "messageType", type);
      xpc_dictionary_set_bool(message, "isBarrier", barrier);
      xpc_dictionary_set_string(message, "featureIdentifier", DigitizerService);
      xpc_dictionary_set_value(message, "payload", payload);
      return message;
    }

    // dtuhidd's HIDButtonState is 1 (down) or 2 (up), as is Indigo's op.
    static xpc_object_t keyPayload(unsigned usage, BOOL down) {
      xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
      xpc_dictionary_set_uint64(payload, "usageCode", usage);
      xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2);
      return payload;
    }

    // dtuhidd is launched on demand, and a port can be vended for one that
    // cannot run, so only an answered barrier proves a daemon is listening.
    static const char *dtuhidOpen(void) {
      if (dtuhid) { xpc_connection_cancel(dtuhid); dtuhid = nil; }
      dtuhidBroken = 0;
      xpc_object_t (*endpointFromPort)(mach_port_t, uint64_t, uint64_t) = dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
      void (*enableSim2Host)(xpc_connection_t) = dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
      if (!endpointFromPort || !enableSim2Host) { return "the XPC calls for dtuhidd are missing"; }
      NSError *err = nil;
      mach_port_t port = ((mach_port_t (*)(id, SEL, NSString *, NSError **))objc_msgSend)(device, sel_registerName("lookup:error:"), @(DigitizerService), &err);
      if (port == MACH_PORT_NULL) { return "the simulator vends no dtuhidd keyboard service"; }
      xpc_object_t endpoint = endpointFromPort(port, 0, 0);
      xpc_connection_t connection = endpoint ? xpc_connection_create_from_endpoint(endpoint) : nil;
      if (!connection) { return "cannot connect to dtuhidd"; }
      enableSim2Host(connection);   // without it dtuhidd sees the peer but never a message
      xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (event == XPC_ERROR_CONNECTION_INTERRUPTED || event == XPC_ERROR_CONNECTION_INVALID) { dtuhidBroken = 1; }
      });
      xpc_connection_resume(connection);
      dispatch_semaphore_t answered = dispatch_semaphore_create(0);
      __block BOOL alive = NO;
      // Usage 0 is "no event": the daemon answers, the guest sees nothing.
      xpc_connection_send_message_with_reply(connection, dtuhidMessage("IndigoKeyboardButtonEvent", keyPayload(0, NO), true),
                                             dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(xpc_object_t reply) {
        alive = xpc_get_type(reply) == XPC_TYPE_DICTIONARY;
        dispatch_semaphore_signal(answered);
      });
      if (dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) != 0 || !alive) {
        xpc_connection_cancel(connection);
        return "dtuhidd does not answer";
      }
      usleep(200000);   // it opens its keyboard just after answering
      dtuhid = connection;
      return NULL;
    }

    // Connects on first use and after XPC drops the connection. A failed
    // attempt is not repeated for two seconds, so keys typed meanwhile fail at
    // once instead of each waiting out the daemon.
    static const char *dtuhidConnect(void) {
      if (dtuhid && !dtuhidBroken) { return NULL; }
      if (dtuhidFailure && nowNs() < dtuhidRetryNs) { return dtuhidFailure; }
      dtuhidFailure = dtuhidOpen();
      if (dtuhidFailure) { dtuhidRetryNs = nowNs() + 2000000000ULL; }
      return dtuhidFailure;
    }

    // Returns NULL once sent, else why not.
    static const char *sendKey(unsigned usage, BOOL down) {
      if (keysOverDTUHID) {
        const char *failure = dtuhidConnect();
        if (failure) { return failure; }
        xpc_connection_send_message(dtuhid, dtuhidMessage("IndigoKeyboardButtonEvent", keyPayload(usage, down), false));
        return NULL;
      }
      if (!buildKey) { return "IndigoHIDMessageForKeyboardArbitrary not found"; }
      void *msg = buildKey(usage, down ? 1 : 2);
      if (!msg) { return "the keyboard message could not be built"; }
      sendMessage(client, sendSelector, msg, YES, nil, nil);
      return NULL;
    }

    static const char *keyEvent(unsigned usage, BOOL down) {
      if (usage == 0 || usage > 255) { return "no such key"; }
      const char *failure = sendKey(usage, down);
      if (!failure) { held[usage] = down; }
      return failure;
    }

    // A usage of another page (Consumer 12 holds Eject, which toggles the
    // software keyboard), pressed and released.
    static const char *pressUsage(unsigned page, unsigned usage) {
      for (int down = 1; down >= 0; down--) {
        if (keysOverDTUHID) {
          const char *failure = dtuhidConnect();
          if (failure) { return failure; }
          xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
          xpc_dictionary_set_uint64(payload, "usagePage", page);
          xpc_dictionary_set_uint64(payload, "usageCode", usage);
          xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2);
          xpc_connection_send_message(dtuhid, dtuhidMessage("IndigoButtonEvent", payload, false));
        } else {
          // Indigo addresses an arbitrary usage to the digitizer service.
          void *msg = buildUsage ? buildUsage(0x32, page, usage, down ? 1 : 2) : NULL;
          if (!msg) { return "IndigoHIDMessageForHIDArbitrary not available"; }
          sendMessage(client, sendSelector, msg, YES, nil, nil);
        }
        if (down) { usleep(40000); }
      }
      return NULL;
    }

    static void releaseKeys(void) {
      for (unsigned usage = 1; usage < 256; usage++) {
        if (held[usage]) { keyEvent(usage, NO); }
      }
    }

    // Waits until XPC has handed over everything sent so far.
    static void settleKeys(void) {
      if (!keysOverDTUHID || !dtuhid) { return; }
      dispatch_semaphore_t sent = dispatch_semaphore_create(0);
      xpc_connection_send_barrier(dtuhid, ^{ dispatch_semaphore_signal(sent); });
      dispatch_semaphore_wait(sent, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }

    // Simulator.app's Connect Hardware Keyboard: with it the guest hides the
    // software keyboard while a hardware one types.
    static const char *setHardwareKeyboard(BOOL connected) {
      SEL selector = sel_registerName("setHardwareKeyboardEnabled:keyboardType:error:");
      if (![device respondsToSelector:selector]) { return "this CoreSimulator cannot connect a hardware keyboard"; }
      NSError *err = nil;
      BOOL ok = ((BOOL (*)(id, SEL, BOOL, unsigned char, NSError **))objc_msgSend)(device, selector, connected, 0, &err);
      if (!ok) { return "the simulator refused the hardware keyboard"; }
      // Typing usually follows, and its first key should not wait for dtuhidd.
      if (connected && keysOverDTUHID) { return dtuhidConnect(); }
      return NULL;
    }

    // MARK: - the finger (worker thread only)

    typedef struct { double x, y, x2, y2; } Spot;
    static int fingers = 0;          // 0 when lifted, else 1 or 2
    static Spot last;
    static uint64_t lastBuildNs = 0;
    // A streamed finger the pointer stopped moving: UIKit never sees a sample
    // that repeats a position, and after a silent pause it still lifts with the
    // last move's speed about a third of the time, flinging a scroll the user
    // stopped. So a resting finger trembles by one pixel across its last
    // movement, as a real one does.
    static const uint64_t RestAfterNs = 60000000ULL;
    static BOOL streamed = NO;       // the finger is the viewer's, not a path's
    static uint64_t lastStreamNs = 0;
    static double moveX = 0, moveY = 1; // direction of the last movement
    static int tremor = 0;

    static BOOL inRange(double v) { return v >= 0 && v <= 1; }

    // Builds and sends one message. A dragged event waits out the builder's
    // throttle first and is retried while the builder still refuses it (it also
    // refuses moves for a moment after a two-finger down).
    static BOOL emit(int type, int count, Spot s) {
      if (!inRange(s.x) || !inRange(s.y) || (count == 2 && (!inRange(s.x2) || !inRange(s.y2)))) { return NO; }
      if (type == DragType) { sleepUntil(lastBuildNs + DragGapNs); }
      CGPoint p = CGPointMake(s.x, s.y), q = CGPointMake(s.x2, s.y2);
      void *msg = buildMouse(&p, count == 2 ? &q : NULL, 0x32, type, 1.0, 1.0, 0);
      for (int attempt = 0; !msg && type == DragType && attempt < 50; attempt++) {
        usleep(2000);
        msg = buildMouse(&p, count == 2 ? &q : NULL, 0x32, type, 1.0, 1.0, 0);
      }
      if (!msg) { return NO; }
      sendMessage(client, sendSelector, msg, YES, nil, nil);
      lastBuildNs = nowNs();
      return YES;
    }

    static BOOL fingerUp(Spot s) {
      if (fingers == 0) { return YES; }
      if (fingers == 2 && s.x2 < 0) { s.x2 = last.x2; s.y2 = last.y2; }
      BOOL ok = emit(UpType, fingers, s);
      if (!ok) { ok = emit(UpType, fingers, last); }   // out of range: lift where it was
      fingers = 0;
      return ok;
    }

    static BOOL fingerDown(int count, Spot s) {
      if (fingers != 0) { fingerUp(last); }   // never stack a press on a stuck finger
      if (!emit(DownType, count, s)) { return NO; }
      fingers = count;
      last = s;
      return YES;
    }

    static BOOL fingerMove(int count, Spot s) {
      if (fingers == 0 || count != fingers) { return NO; }
      if (!emit(DragType, fingers, s)) { return NO; }
      if (s.x != last.x || s.y != last.y) { moveX = s.x - last.x; moveY = s.y - last.y; }
      last = s;
      return YES;
    }

    static void rest(void) {
      Spot s = last;
      if (tremor++ % 2 == 0) {
        BOOL horizontal = fabs(moveX / pixelX) >= fabs(moveY / pixelY);
        double dx = horizontal ? 0 : pixelX, dy = horizontal ? pixelY : 0;
        s.x = s.x + dx <= 1 ? s.x + dx : s.x - dx;
        s.y = s.y + dy <= 1 ? s.y + dy : s.y - dy;
        if (fingers == 2) {
          s.x2 = s.x2 + dx <= 1 ? s.x2 + dx : s.x2 - dx;
          s.y2 = s.y2 + dy <= 1 ? s.y2 + dy : s.y2 - dy;
        }
      }
      emit(DragType, fingers, s);
    }

    // MARK: - commands

    typedef enum { CmdDown, CmdMove, CmdUp, CmdTap, CmdSwipe, CmdPath, CmdSize, CmdKey, CmdPress, CmdButton, CmdHardwareKeyboard, CmdQuit } Kind;
    typedef struct {
      Kind kind; int count; Spot spot; double x2, y2; int ms; char *text;
      unsigned usage, page, mods[3]; int modCount; BOOL on;   // keyboard commands
    } Command;

    static BOOL runPath(char *text) {
      uint64_t start = nowNs();
      BOOL ok = YES;
      char *save = NULL;
      for (char *token = strtok_r(text, " \t\r\n", &save); token && ok; token = strtok_r(NULL, " \t\r\n", &save)) {
        char phase = 0;
        double ms = 0;
        Spot s = { 0, 0, -1, -1 };
        if (sscanf(token, "%c,%lf,%lf,%lf", &phase, &ms, &s.x, &s.y) != 4) { ok = NO; break; }
        sleepUntil(start + (uint64_t)(ms * 1000000.0));
        switch (phase) {
          case 'd': ok = fingerDown(1, s); break;
          case 'm': ok = fingerMove(1, s); break;
          case 'u': ok = fingerUp(s); break;
          default: ok = NO;
        }
      }
      if (fingers != 0) { fingerUp(last); }
      return ok;
    }

    static BOOL runSwipe(Command *c) {
      int ms = MAX(17, c->ms);
      int steps = MAX(1, ms / 17);
      Spot from = c->spot, to = { c->x2, c->y2, -1, -1 };
      uint64_t start = nowNs();
      BOOL ok = fingerDown(1, from);
      for (int i = 1; ok && i <= steps; i++) {
        sleepUntil(start + (uint64_t)i * (uint64_t)ms * 1000000ULL / (uint64_t)steps);
        double t = (double)i / steps;
        Spot s = { from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t, -1, -1 };
        ok = fingerMove(1, s);
      }
      return fingerUp(to) && ok;
    }

    static void reply(BOOL ok) {
      printf(ok ? "ok\n" : "err\n");
      fflush(stdout);
    }

    static void replyFailure(const char *failure) {
      if (failure) { printf("err %s\n", failure); } else { printf("ok\n"); }
      fflush(stdout);
    }

    // Modifiers down in order, the key down and up, modifiers up in reverse.
    static const char *runPress(Command *c) {
      const char *failure = NULL;
      int down = 0;   // modifiers held so far
      while (down < c->modCount && !(failure = keyEvent(c->mods[down], YES))) { down++; }
      if (!failure) {
        failure = keyEvent(c->usage, YES);
        if (!failure) { usleep(30000); failure = keyEvent(c->usage, NO); }
      }
      while (down > 0) { keyEvent(c->mods[--down], NO); }
      settleKeys();
      return failure;
    }

    // Returns NO when the helper should exit.
    static BOOL perform(Command *c) {
      switch (c->kind) {
        case CmdDown:
          streamed = fingerDown(c->count, c->spot);
          lastStreamNs = nowNs();
          return YES;
        case CmdMove:
          fingerMove(c->count, c->spot);
          lastStreamNs = nowNs();
          return YES;
        case CmdUp: fingerUp(c->spot); return YES;
        case CmdTap: {
          streamed = NO;
          BOOL ok = fingerDown(1, c->spot);
          usleep((useconds_t)MAX(0, c->ms) * 1000);
          reply(fingerUp(c->spot) && ok);
          return YES;
        }
        case CmdSwipe: streamed = NO; reply(runSwipe(c)); return YES;
        case CmdPath: streamed = NO; reply(runPath(c->text)); free(c->text); return YES;
        case CmdSize: {
          id type = ((id (*)(id, SEL))objc_msgSend)(device, sel_registerName("deviceType"));
          CGSize size = ((CGSize (*)(id, SEL))objc_msgSend)(type, sel_registerName("mainScreenSize"));
          float scale = ((float (*)(id, SEL))objc_msgSend)(type, sel_registerName("mainScreenScale"));
          if (size.width <= 0 || size.height <= 0 || scale <= 0) { printf("err\n"); }
          else { printf("ok %.3f %.3f %.3f\n", size.width / scale, size.height / scale, scale); }
          fflush(stdout);
          return YES;
        }
        case CmdKey: {
          // stderr is read only once the helper exits: one line per kind of failure.
          static const char *reported;
          const char *failure = keyEvent(c->usage, c->on);
          if (failure && failure != reported) { say(failure); }
          reported = failure;
          return YES;
        }
        case CmdPress: replyFailure(runPress(c)); return YES;
        case CmdButton: {
          const char *failure = pressUsage(c->page, c->usage);
          settleKeys();
          replyFailure(failure);
          return YES;
        }
        case CmdHardwareKeyboard: replyFailure(setHardwareKeyboard(c->on)); return YES;
        case CmdQuit: fingerUp(last); releaseKeys(); settleKeys(); return NO;
      }
      return YES;
    }

    // MARK: - queue (reader thread → worker thread)

    enum { Capacity = 4096 };
    static Command queue[Capacity];
    static int queued = 0;
    static pthread_mutex_t queueLock = PTHREAD_MUTEX_INITIALIZER;
    static pthread_cond_t queueChanged = PTHREAD_COND_INITIALIZER;

    static void enqueue(Command c) {
      pthread_mutex_lock(&queueLock);
      // Latest position wins: a move replaces the move still waiting behind it.
      if (c.kind == CmdMove && queued > 0 && queue[queued - 1].kind == CmdMove && queue[queued - 1].count == c.count) {
        queue[queued - 1] = c;
      } else {
        while (queued == Capacity) { pthread_cond_wait(&queueChanged, &queueLock); }
        queue[queued++] = c;
      }
      pthread_cond_broadcast(&queueChanged);
      pthread_mutex_unlock(&queueLock);
    }

    static void *work(void *unused) {
      for (;;) {
        pthread_mutex_lock(&queueLock);
        while (queued == 0) {
          if (!(streamed && fingers != 0)) { pthread_cond_wait(&queueChanged, &queueLock); continue; }
          uint64_t due = MAX(lastStreamNs + RestAfterNs, lastBuildNs + DragGapNs);
          uint64_t now = nowNs();
          if (now < due) {
            struct timespec until = deadlineIn(due - now);
            pthread_cond_timedwait(&queueChanged, &queueLock, &until);
            continue;
          }
          pthread_mutex_unlock(&queueLock);
          rest();
          pthread_mutex_lock(&queueLock);
        }
        // A move waits out the builder's throttle in the queue, where newer
        // positions can still replace it.
        if (queue[0].kind == CmdMove) {
          uint64_t due = lastBuildNs + DragGapNs;
          if (due > nowNs()) {
            pthread_mutex_unlock(&queueLock);
            sleepUntil(due);
            continue;
          }
        }
        Command c = queue[0];
        memmove(queue, queue + 1, sizeof(Command) * (size_t)(queued - 1));
        queued -= 1;
        pthread_cond_broadcast(&queueChanged);
        pthread_mutex_unlock(&queueLock);
        @autoreleasepool {
          if (!perform(&c)) { exit(0); }
        }
      }
      return NULL;
    }

    static BOOL parse(char *line, Command *c) {
      char name[16] = {0};
      double v[4] = {0, 0, 0, 0};
      int ms = 0, consumed = 0;
      if (sscanf(line, "%15s%n", name, &consumed) != 1) { return NO; }
      char *rest = line + consumed;
      memset(c, 0, sizeof(*c));
      c->spot.x2 = -1;
      c->spot.y2 = -1;
      c->count = 1;
      int n = sscanf(rest, "%lf %lf %lf %lf %d", &v[0], &v[1], &v[2], &v[3], &ms);
      if (!strcmp(name, "path")) { c->kind = CmdPath; c->text = strdup(rest); return YES; }
      if (!strcmp(name, "size")) { c->kind = CmdSize; return YES; }
      if (!strcmp(name, "q") || !strcmp(name, "quit")) { c->kind = CmdQuit; return YES; }
      if (!strcmp(name, "tap") && n >= 2) {
        c->kind = CmdTap; c->spot.x = v[0]; c->spot.y = v[1]; c->ms = n >= 3 ? (int)v[2] : 60; return YES;
      }
      if (!strcmp(name, "swipe") && n >= 4) {
        c->kind = CmdSwipe; c->spot.x = v[0]; c->spot.y = v[1]; c->x2 = v[2]; c->y2 = v[3]; c->ms = n >= 5 ? ms : 200; return YES;
      }
      if (!strcmp(name, "key") && n >= 2) { c->kind = CmdKey; c->usage = (unsigned)v[0]; c->on = v[1] != 0; return YES; }
      if (!strcmp(name, "press") && n >= 1) {
        c->kind = CmdPress; c->usage = (unsigned)v[0]; c->modCount = MIN(n, 4) - 1;
        for (int i = 0; i < c->modCount; i++) { c->mods[i] = (unsigned)v[i + 1]; }
        return YES;
      }
      if (!strcmp(name, "button") && n >= 2) { c->kind = CmdButton; c->page = (unsigned)v[0]; c->usage = (unsigned)v[1]; return YES; }
      if (!strcmp(name, "hwkeyboard") && n >= 1) { c->kind = CmdHardwareKeyboard; c->on = v[0] != 0; return YES; }
      size_t len = strlen(name);
      BOOL two = len > 1 && name[len - 1] == '2';
      if (two) { name[len - 1] = 0; }
      if (n < (two ? 4 : 2)) { return NO; }
      c->count = two ? 2 : 1;
      c->spot.x = v[0]; c->spot.y = v[1];
      if (two) { c->spot.x2 = v[2]; c->spot.y2 = v[3]; }
      if (!strcmp(name, "down")) { c->kind = CmdDown; return YES; }
      if (!strcmp(name, "move")) { c->kind = CmdMove; return YES; }
      if (!strcmp(name, "up")) { c->kind = CmdUp; return YES; }
      return NO;
    }

    int main(int argc, const char *argv[]) {
      @autoreleasepool {
        if (argc < 2) { say("usage: helper <udid>"); return 64; }
        if (!loadFrameworks()) { return 2; }
        if (!openClient([NSString stringWithUTF8String:argv[1]])) { return 3; }
        pthread_t worker;
        pthread_create(&worker, NULL, work, NULL);
        char *line = NULL;
        size_t capacity = 0;
        while (getline(&line, &capacity, stdin) > 0) {
          Command c;
          if (parse(line, &c)) {
            enqueue(c);
            if (c.kind == CmdQuit) { break; }
          } else if (strncmp(line, "down", 4) && strncmp(line, "move", 4) && strncmp(line, "up", 2) && strncmp(line, "key ", 4)) {
            // Malformed acked commands still get their answer; streamed ones stay silent.
            printf("err\n");
            fflush(stdout);
          }
        }
        Command quit = { .kind = CmdQuit };
        enqueue(quit);
        pthread_join(worker, NULL);
        return 0;
      }
    }
    """#
}
