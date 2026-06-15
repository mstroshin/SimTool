import Foundation

public actor SimulatorDirectInputClient {
    public static let shared = SimulatorDirectInputClient()

    private static let helperVersion = "1"

    private var session: SimulatorDirectInputSession?

    public init() {}

    public func tap(xRatio: Double, yRatio: Double, deviceUDID: String) async throws {
        try await send(SimulatorDirectInputCommand.tap(x: xRatio, y: yRatio).line, deviceUDID: deviceUDID, retry: true)
    }

    public func swipe(
        startXRatio: Double,
        startYRatio: Double,
        endXRatio: Double,
        endYRatio: Double,
        duration: Double?,
        deviceUDID: String
    ) async throws {
        try await send(SimulatorDirectInputCommand.swipe(
            startX: startXRatio,
            startY: startYRatio,
            endX: endXRatio,
            endY: endYRatio,
            durationMs: duration.map { Int($0 * 1000) }
        ).line, deviceUDID: deviceUDID, retry: true)
    }

    public func close() {
        session?.stop()
        session = nil
    }

    private func send(_ line: String, deviceUDID: String, retry: Bool) async throws {
        DirectInputLog.write("send begin command=\(line) udid=\(deviceUDID) retry=\(retry)")
        let current = try await session(for: deviceUDID)
        do {
            DirectInputLog.write("write command=\(line)")
            try current.write(line)
            DirectInputLog.write("read response command=\(line)")
            guard let response = try await current.readLine(timeoutSeconds: 2) else {
                DirectInputLog.write("response eof command=\(line) message=\(current.exitMessage())")
                throw SimToolError(current.exitMessage())
            }
            DirectInputLog.write("response command=\(line) value=\(response)")
            guard response == "ok" else { throw SimToolError(response) }
        } catch {
            DirectInputLog.write("send failed command=\(line) error=\(error.localizedDescription)")
            current.stop()
            if session === current { session = nil }
            if retry {
                try await send(line, deviceUDID: deviceUDID, retry: false)
                return
            }
            throw error
        }
    }

    private func session(for deviceUDID: String) async throws -> SimulatorDirectInputSession {
        if let session, session.deviceUDID == deviceUDID, session.isRunning {
            DirectInputLog.write("reuse helper pid=\(session.processIdentifier) udid=\(deviceUDID)")
            return session
        }
        session?.stop()
        let helperURL = try await helperExecutableURL()
        DirectInputLog.write("start helper path=\(helperURL.path) udid=\(deviceUDID)")
        let next = SimulatorDirectInputSession(helperURL: helperURL, deviceUDID: deviceUDID)
        try next.start()
        DirectInputLog.write("started helper pid=\(next.processIdentifier) udid=\(deviceUDID)")
        session = next
        return next
    }

    private func helperExecutableURL() async throws -> URL {
        let directory = try helperDirectoryURL()
        let outputURL = directory.appendingPathComponent("simtool-direct-hid-\(Self.helperVersion)-\(simulatorArch)")
        if FileManager.default.isExecutableFile(atPath: outputURL.path) {
            DirectInputLog.write("using cached helper path=\(outputURL.path)")
            return outputURL
        }
        DirectInputLog.write("compile helper path=\(outputURL.path)")
        try await compileHelper(to: outputURL)
        return outputURL
    }

    private func compileHelper(to outputURL: URL) async throws {
        let sourceURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(outputURL.lastPathComponent).m")
        let tempURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(outputURL.lastPathComponent).tmp.\(UUID().uuidString)")

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

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.moveItem(at: tempURL, to: outputURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outputURL.path)
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

private struct SimulatorDirectInputCommand: Equatable {
    var line: String

    static func tap(x: Double, y: Double) -> Self {
        Self(line: "tap \(formatRatio(x)) \(formatRatio(y))")
    }

    static func swipe(startX: Double, startY: Double, endX: Double, endY: Double, durationMs: Int?) -> Self {
        let duration = max(16, durationMs ?? 200)
        return Self(line: "swipe \(formatRatio(startX)) \(formatRatio(startY)) \(formatRatio(endX)) \(formatRatio(endY)) \(duration)")
    }

    private static func formatRatio(_ value: Double) -> String {
        String(format: "%.5f", value.clamped(to: 0...1))
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

    func stop() {
        if isRunning {
            try? inputPipe.fileHandleForWriting.write(contentsOf: Data("q\n".utf8))
            try? inputPipe.fileHandleForWriting.close()
            process.terminate()
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

private enum SimulatorDirectInputHelperSource {
    static let source = #"""
    #import <Foundation/Foundation.h>
    #import <CoreGraphics/CoreGraphics.h>
    #import <objc/message.h>
    #import <objc/runtime.h>
    #import <dispatch/dispatch.h>
    #import <dlfcn.h>
    #import <mach/mach_time.h>
    #import <string.h>

    #pragma pack(push, 4)
    typedef struct { unsigned int a,b,c,d,e; int f; } MachHeader;
    typedef struct { unsigned int a,b,c; double x,y,f,g,h; unsigned int i,j,k,l,m; double n,o,p,q,r; } IndigoTouch;
    typedef union { IndigoTouch touch; } IndigoEvent;
    typedef struct { unsigned int a; unsigned long long ts; unsigned int b; IndigoEvent event; } Payload;
    typedef struct { MachHeader header; unsigned int innerSize; unsigned char eventType; Payload payload; } Message;
    #pragma pack(pop)

    static const unsigned long long Booted = 3;

    static void say(const char *s) { fprintf(stderr, "%s\n", s ?: "error"); }

    static BOOL loadFrameworks(void) {
      NSBundle *cs = [NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreSimulator.framework"];
      if (![cs load]) { say("Failed to load CoreSimulator"); return NO; }
      NSString *dev = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
      if (dev.length == 0) { dev = @"/Applications/Xcode.app/Contents/Developer"; }
      NSString *skPath = [[dev stringByAppendingPathComponent:@"Library/PrivateFrameworks"] stringByAppendingPathComponent:@"SimulatorKit.framework"];
      if (![[NSBundle bundleWithPath:skPath] load]) { say("Failed to load SimulatorKit"); return NO; }
      return YES;
    }

    static id bootedDevice(NSString *udid, NSError **error) {
      NSString *dev = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
      if (dev.length == 0) { dev = @"/Applications/Xcode.app/Contents/Developer"; }
      Class cls = objc_getClass("SimServiceContext");
      id ctx = ((id (*)(Class, SEL, NSString *, NSError **))objc_msgSend)(cls, sel_registerName("sharedServiceContextForDeveloperDir:error:"), dev, error);
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

    static void *rawMouse(CGPoint *p, int type) {
      void *(*fn)(CGPoint *, CGPoint *, unsigned int, int, CGFloat, CGFloat, unsigned int) = (void *)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForMouseNSEvent");
      return fn ? fn(p, NULL, 0x32, type, 1.0, 1.0, 0) : NULL;
    }

    static void *touchMessage(double x, double y, int phase) {
      CGPoint p = CGPointMake(x, y);
      return rawMouse(&p, phase == 0 ? 1 : phase);
    }

    static BOOL sendTouch(id client, double x, double y, int phase) {
      if (x < 0 || x > 1 || y < 0 || y > 1) { say("ratio out of range"); return NO; }
      void *msg = touchMessage(x, y, phase);
      if (!msg) { say("touch message failed"); return NO; }
      SEL sel = sel_registerName("sendWithMessage:freeWhenDone:completionQueue:completion:");
      Method method = class_getInstanceMethod([client class], sel);
      if (!method) { free(msg); say("sendWithMessage not found"); return NO; }
      void (*send)(id, SEL, void *, BOOL, dispatch_queue_t, id) = (void *)method_getImplementation(method);
      send(client, sel, msg, YES, nil, nil);
      return YES;
    }

    static id openClient(NSString *udid) {
      NSError *err = nil;
      id device = bootedDevice(udid, &err);
      if (!device) { say(err.localizedDescription.UTF8String); return nil; }
      Class cls = hidClientClass();
      if (!cls) { say("SimDeviceLegacyHIDClient class not found"); return nil; }
      id alloc = ((id (*)(Class, SEL))objc_msgSend)(cls, sel_registerName("alloc"));
      id client = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(alloc, sel_registerName("initWithDevice:error:"), device, &err);
      if (!client) { say((err.localizedDescription ?: @"initWithDevice failed").UTF8String); }
      return client;
    }

    static BOOL swipe(id client, double x1, double y1, double x2, double y2, int ms) {
      int steps = MAX(8, ms / 16);
      BOOL ok = sendTouch(client, x1, y1, 1);
      for (int i = 1; ok && i < steps; i++) {
        double t = (double)i / (double)(steps - 1);
        ok = sendTouch(client, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, 0);
        usleep(MAX(1000, (ms * 1000) / steps));
      }
      return ok && sendTouch(client, x2, y2, 2);
    }

    int main(int argc, const char *argv[]) {
      @autoreleasepool {
        if (argc < 2) { say("usage: helper <udid>"); return 64; }
        if (!loadFrameworks()) { return 2; }
        id client = openClient([NSString stringWithUTF8String:argv[1]]);
        if (!client) { return 3; }
        char line[256];
        while (fgets(line, sizeof(line), stdin)) {
          char cmd[16] = {0};
          double a = 0, b = 0, c = 0, d = 0;
          int ms = 200;
          int n = sscanf(line, "%15s %lf %lf %lf %lf %d", cmd, &a, &b, &c, &d, &ms);
          BOOL ok = NO;
          if (strcmp(cmd, "tap") == 0 && n >= 3) {
            ok = sendTouch(client, a, b, 1); usleep(25000); ok = ok && sendTouch(client, a, b, 2);
          } else if (strcmp(cmd, "swipe") == 0 && n >= 5) {
            ok = swipe(client, a, b, c, d, ms);
          } else if (strcmp(cmd, "q") == 0 || strcmp(cmd, "quit") == 0) {
            break;
          } else {
            say("bad command");
          }
          printf(ok ? "ok\n" : "err\n");
          fflush(stdout);
        }
        return 0;
      }
    }
    """#
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
