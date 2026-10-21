import CryptoKit
import Foundation

/// A fold an iPhone Duo can be put in: a named pose or any hinge angle.
///
/// Closed (0°) lights the cover, book (130°) and open (180°) the inner panel.
/// SpringBoard folds with hysteresis — an angle reached in a jump can leave the
/// panel that was lit — so every fold is swept, as a hand would open it.
public struct SimulatorPose: Equatable, Sendable, CustomStringConvertible {
    public var hingeDegrees: Double
    /// `closed`, `book` or `open`; nil for an angle of its own.
    public var name: String?

    public static let closed = SimulatorPose(hingeDegrees: 0, name: "closed")
    public static let book = SimulatorPose(hingeDegrees: 130, name: "book")
    public static let open = SimulatorPose(hingeDegrees: 180, name: "open")
    public static let presets: [SimulatorPose] = [.closed, .book, .open]

    public init(hingeDegrees: Double, name: String? = nil) {
        self.hingeDegrees = hingeDegrees
        self.name = name
    }

    /// `closed` (or `cover`), `book`, `open` (or `flat`, `inner`), or an angle
    /// from 0 to 180 (`90`, `90°`).
    public init(parsing raw: String) throws {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch text {
        case "closed", "close", "cover": self = .closed
        case "book": self = .book
        case "open", "flat", "inner": self = .open
        default:
            let number = text.hasSuffix("°") ? String(text.dropLast()) : text
            guard let degrees = Double(number), degrees.isFinite, (0...180).contains(degrees) else {
                throw SimToolError("Unknown pose \(raw): use closed, book, open, or a hinge angle from 0 to 180")
            }
            self = SimulatorPose.presets.first { $0.hingeDegrees == degrees } ?? SimulatorPose(hingeDegrees: degrees)
        }
    }

    public var description: String { name ?? SimulatorFoldState.degrees(hingeDegrees) }

    /// The panel a sweep to this pose lights, when SpringBoard settles on one
    /// whichever way it came: the cover once closed, the inner panel from
    /// book on. Between, the panel that was lit may stay.
    var expectedPanel: String? {
        if hingeDegrees <= 3 { return "cover" }
        if hingeDegrees >= 120 { return "inner" }
        return nil
    }
}

/// How an iPhone Duo is folded, as the device itself reports it: the hinge
/// from the guest's motion service (locationd logs every angle it takes),
/// SpringBoard's posture and the panel it makes primary.
public struct SimulatorFoldState: Codable, Equatable, Sendable {
    /// The hinge, 0 (closed) to 180 (flat open).
    public var hingeDegrees: Double?
    /// SpringBoard's word for it: `fullyClosed`, `closed`, `partiallyOpen`,
    /// `openFlat`, with what it is doing (`+toOpen`, `+foldAvoidance`).
    /// SpringBoard says it only as a posture begins, so it is dropped once the
    /// hinge has moved on without a word (book → open says nothing).
    public var posture: String?
    /// The panel SpringBoard made primary: `cover` or `inner`.
    public var panel: String?
    /// The hinge the posture was said at.
    private var postureDegrees: Double?

    public init(hingeDegrees: Double? = nil, posture: String? = nil, panel: String? = nil) {
        self.hingeDegrees = hingeDegrees
        self.posture = posture
        self.panel = panel
        postureDegrees = posture == nil ? nil : hingeDegrees
    }

    /// The named pose the hinge rests at, if it does.
    public var pose: String? {
        guard let hinge = hingeDegrees else { return nil }
        if hinge <= 3 { return "closed" }
        if hinge >= 177 { return "open" }
        if abs(hinge - SimulatorPose.book.hingeDegrees) <= 6 { return "book" }
        return nil
    }

    public var summary: String {
        var parts: [String] = []
        if let hingeDegrees { parts.append((pose.map { $0 + " · " } ?? "") + Self.degrees(hingeDegrees)) }
        if let panel { parts.append(panel + " panel lit") }
        return parts.isEmpty ? "unknown fold" : parts.joined(separator: ", ")
    }

    public static func degrees(_ value: Double) -> String {
        (value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)) + "°"
    }

    enum CodingKeys: String, CodingKey { case hingeDegrees, posture, panel, pose }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hingeDegrees = try container.decodeIfPresent(Double.self, forKey: .hingeDegrees)
        posture = try container.decodeIfPresent(String.self, forKey: .posture)
        panel = try container.decodeIfPresent(String.self, forKey: .panel)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(hingeDegrees, forKey: .hingeDegrees)
        try container.encodeIfPresent(posture, forKey: .posture)
        try container.encodeIfPresent(panel, forKey: .panel)
        try container.encodeIfPresent(pose, forKey: .pose)
    }

    /// The guest's lines about the fold, from `log stream`/`log show --info
    /// --style compact` with `SimulatorFoldState.logPredicate`: locationd's
    /// hinge angles and SpringBoard's postures and primary panels.
    public static let logPredicate = """
        (process == "locationd" AND category == "DeviceState" AND eventMessage BEGINSWITH "Angle value set to:") \
        OR (process == "SpringBoard" AND ((category == "DevicePose" AND eventMessage CONTAINS "DCMPose:") \
        OR (category == "DisplayContentMode" AND eventMessage CONTAINS "COMPLETED:")))
        """

    /// The fold one line reports, merged over `self`: locationd's
    /// `Angle value set to: 133.800000` gives the hinge;
    /// `DCMPose: 100.0° (0.56 fold:1.00): partiallyOpen+foldAvoidance [device:unknown]`
    /// the hinge and posture; `COMPLETED: .cover:aux .inner:pri | 180.0° … : openFlat`
    /// the primary panel too. Nil for a line about something else.
    public func reading(_ line: String) -> SimulatorFoldState? {
        if let marker = line.range(of: "Angle value set to: ") {
            let number = line[marker.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "-" }
            guard let degrees = Double(number), (0...180).contains(degrees) else { return nil }
            var next = self
            next.hingeDegrees = (degrees * 10).rounded() / 10
            if let said = postureDegrees, abs(said - degrees) > 8 {
                next.posture = nil
                next.postureDegrees = nil
            }
            return next
        }
        // `log stream` opens by quoting the predicate, which names both markers.
        let completed = line.contains("COMPLETED:") && (line.contains(".cover:") || line.contains(".inner:"))
        guard completed || line.range(of: #"DCMPose: -?[0-9.]+°"#, options: .regularExpression) != nil else { return nil }
        var next = self
        // SpringBoard's own angle is its filtered estimate, a few degrees off
        // the hinge: locationd's, once heard, is the one kept.
        let angleMarker = completed ? "| " : "DCMPose: "
        if next.hingeDegrees == nil, let marker = line.range(of: angleMarker) {
            let number = line[marker.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "-" }
            if let degrees = Double(number), (0...180).contains(degrees) { next.hingeDegrees = degrees }
        }
        if let marker = line.range(of: "): ") {
            let word = line[marker.upperBound...].prefix { $0.isLetter || $0 == "+" }
            if !word.isEmpty {
                next.posture = String(word)
                next.postureDegrees = next.hingeDegrees
            }
        }
        if completed {
            if line.contains(".inner:pri") { next.panel = "inner" } else if line.contains(".cover:pri") { next.panel = "cover" }
        }
        return next
    }

    /// The latest fold in a stretch of SpringBoard's log, oldest line first.
    public static func latest(inLog text: String) -> SimulatorFoldState? {
        var state: SimulatorFoldState?
        for line in text.split(separator: "\n") {
            if let next = (state ?? SimulatorFoldState()).reading(String(line)) { state = next }
        }
        return state
    }

    /// The device's fold now, from SpringBoard's log of the last minutes. Nil
    /// when it has said nothing about it lately — a device never folded since
    /// it booted.
    public static func read(deviceUDID: String, last: String = "30m") async -> SimulatorFoldState? {
        guard let output = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "spawn", deviceUDID, "log", "show", "--last", last, "--info", "--style", "compact", "--predicate", logPredicate],
            timeoutSeconds: 20
        ), output.status == 0 else { return nil }
        return latest(inLog: output.stdoutString)
    }
}

/// Folds an iPhone Duo the way Device Hub's hinge slider does: a helper inside
/// the simulator posts the hinge angle as the vendor HID event CoreDevice's
/// virtual hinge sends, swept over 800 ms with an ease-out. Then it waits for
/// the device to say it got there — a fold the device did not take is an
/// error, never an "ok".
public actor SimulatorFoldClient {
    public static let shared = SimulatorFoldClient()

    static let sweepMilliseconds = 800
    private static let helperVersion = "1"
    private static let helperFingerprint = SHA256.hash(data: Data(SimulatorFoldHelperSource.source.utf8))
        .prefix(6).map { String(format: "%02x", $0) }.joined()

    private var sessions: [String: SimulatorFoldSession] = [:]

    public init() {}

    /// What the fold reads now: the lit panel (from CoreDevice) and the hinge
    /// (from SpringBoard). The server answers from what it watches; a command
    /// reads the device.
    public typealias Readback = @Sendable () async -> (active: String?, fold: SimulatorFoldState?)

    /// Sweeps the hinge from `from` — where it is, if known — to `pose`, and
    /// returns the fold the device reports once it settles. Throws when the
    /// device is not a foldable, the helper cannot post the hinge, or the
    /// device never lights the panel the pose calls for.
    public func fold(
        to pose: SimulatorPose,
        from: Double?,
        layout: SimulatorDisplayLayout?,
        deviceUDID: String,
        readback: Readback
    ) async throws -> SimulatorFoldState {
        guard let layout, layout.isFoldable else {
            throw SimToolError("This simulator does not fold: only a device with a cover and an inner screen (iPhone Duo) takes a pose")
        }
        var start = from
        if start == nil {
            let now = await readback()
            start = now.fold?.hingeDegrees ?? (now.active.flatMap(layout.display(named:))?.role == "cover" ? 0 : 180)
        }
        let line = SimulatorFoldCommand.sweep(from: start ?? 0, to: pose.hingeDegrees, milliseconds: Self.sweepMilliseconds).line
        try await send(line, deviceUDID: deviceUDID, timeout: 5)
        return try await Self.settle(at: pose, layout: layout, readback: readback)
    }

    /// Waits up to four seconds for the device to show the pose: the panel it
    /// calls for lit, the hinge near the angle.
    static func settle(at pose: SimulatorPose, layout: SimulatorDisplayLayout, timeout: TimeInterval = 4, readback: Readback) async throws -> SimulatorFoldState {
        let deadline = Date().addingTimeInterval(timeout)
        var last: (active: String?, fold: SimulatorFoldState?) = (nil, nil)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            last = await readback()
            let panel = last.active.flatMap(layout.display(named:))?.role
            let hingeReached = last.fold?.hingeDegrees.map { abs($0 - pose.hingeDegrees) <= 8 } ?? false
            let panelReached = pose.expectedPanel.map { $0 == panel } ?? true
            if hingeReached && panelReached {
                var state = last.fold ?? SimulatorFoldState()
                state.panel = panel ?? state.panel
                return state
            }
        }
        let panel = last.active.flatMap(layout.display(named:))?.role
        let seen = [last.fold?.hingeDegrees.map(SimulatorFoldState.degrees), panel.map { "the \($0) panel lit" }].compactMap { $0 }
        throw SimToolError("The simulator did not fold to \(pose): it reports \(seen.isEmpty ? "nothing" : seen.joined(separator: ", ")) after \(Int(timeout)) s")
    }

    private func send(_ line: String, deviceUDID: String, timeout: TimeInterval) async throws {
        var lastError: Error?
        for _ in 0..<2 {
            do {
                let session = try await session(for: deviceUDID)
                let answer = try await session.exchange(line, timeout: timeout)
                guard answer == "ok" else {
                    throw SimToolError("The simulator refused the fold (\(answer.hasPrefix("err ") ? String(answer.dropFirst(4)) : answer))")
                }
                return
            } catch let error as SimToolError where error.message.hasPrefix("The simulator refused") {
                throw error
            } catch {
                // A helper that died or went silent is replaced once.
                lastError = error
                sessions[deviceUDID]?.stop()
                sessions[deviceUDID] = nil
            }
        }
        throw lastError ?? SimToolError("The fold helper did not answer")
    }

    private func session(for deviceUDID: String) async throws -> SimulatorFoldSession {
        if let session = sessions[deviceUDID], session.isRunning { return session }
        let session = SimulatorFoldSession(helperURL: try await helperURL(), deviceUDID: deviceUDID)
        try session.start()
        sessions[deviceUDID] = session
        return session
    }

    public func close() {
        for session in sessions.values { session.stop() }
        sessions.removeAll()
    }

    /// Built for the simulator once per helper source, ad-hoc signed — `simctl
    /// spawn` runs nothing unsigned — and cached next to the HID helper.
    private func helperURL() async throws -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw SimToolError("Failed to locate user caches directory")
        }
        let directory = caches.appendingPathComponent("SimTool/SimulatorHelpers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let output = directory.appendingPathComponent("simtool-fold-\(Self.helperVersion)-\(Self.helperFingerprint)-\(arch)")
        if FileManager.default.isExecutableFile(atPath: output.path) { return output }
        let unique = UUID().uuidString
        let source = directory.appendingPathComponent("\(output.lastPathComponent).\(unique).m")
        let temporary = directory.appendingPathComponent("\(output.lastPathComponent).tmp.\(unique)")
        try SimulatorFoldHelperSource.source.write(to: source, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: temporary)
        }
        let built = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--sdk", "iphonesimulator", "clang", "-arch", arch, "-mios-simulator-version-min=15.0", "-fobjc-arc",
                        "-framework", "Foundation", "-Wl,-adhoc_codesign", "-o", temporary.path, source.path],
            timeoutSeconds: 60
        )
        guard built.status == 0 else {
            throw SimToolError(built.stderrString.isEmpty ? "Failed to build the fold helper" : built.stderrString)
        }
        guard rename(temporary.path, output.path) == 0 else {
            throw SimToolError("Failed to install the fold helper: \(String(cString: strerror(errno)))")
        }
        return output
    }
}

/// The fold helper's line protocol.
struct SimulatorFoldCommand: Equatable {
    var line: String

    static func angle(_ degrees: Double) -> Self {
        Self(line: "angle \(String(format: "%.2f", degrees))")
    }

    static func sweep(from: Double, to: Double, milliseconds: Int) -> Self {
        Self(line: "sweep \(String(format: "%.2f", from)) \(String(format: "%.2f", to)) \(milliseconds)")
    }
}

/// One fold helper running inside one booted simulator (`simctl spawn`),
/// answering a line per command.
private final class SimulatorFoldSession: @unchecked Sendable {
    let deviceUDID: String
    private let helperURL: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    init(helperURL: URL, deviceUDID: String) {
        self.helperURL = helperURL
        self.deviceUDID = deviceUDID
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", deviceUDID, helperURL.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// Writes a command and waits for its one-line answer. A helper that does
    /// not answer in time is stopped by the caller, which ends the read.
    func exchange(_ line: String, timeout: TimeInterval) async throws -> String {
        guard process.isRunning else { throw SimToolError(exitMessage()) }
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.readLine() }
            group.addTask {
                try await Task.sleep(for: .milliseconds(Int(timeout * 1000)))
                throw SimToolError("The fold helper did not answer within \(Int(timeout)) s")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func readLine() async throws -> String {
        let handle = output.fileHandleForReading
        while true {
            if let answer = takeLine() { return answer }
            let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                DispatchQueue.global().async { continuation.resume(returning: handle.availableData) }
            }
            if data.isEmpty { throw SimToolError(exitMessage()) }
            lock.withLock { buffer.append(data) }
        }
    }

    private func takeLine() -> String? {
        lock.withLock {
            guard let newline = buffer.firstIndex(of: 10) else { return nil }
            let line = String(decoding: buffer[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...newline)
            return line
        }
    }

    func stop() {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.close()
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { if process.isRunning { process.terminate() } }
    }

    private func exitMessage() -> String {
        if process.isRunning { return "The fold helper gave no answer." }
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? "The fold helper exited." : "The fold helper failed: \(said)"
    }
}

enum SimulatorFoldHelperSource {
    /// Adapted from serve-sim's `SimDuoHID/main.m` (https://github.com/EvanBacon/serve-sim,
    /// Apache-2.0, commit a30d70a); see THIRD_PARTY_NOTICES.md. Changes: hinge
    /// commands only, SimTool's answers (`ok` / `err reason`), range checks.
    static let source = #"""
    #import <Foundation/Foundation.h>
    #import <dlfcn.h>
    #import <mach/mach_time.h>
    #import <objc/message.h>
    #import <objc/runtime.h>
    #import <math.h>
    #import <stdio.h>
    #import <unistd.h>

    // Runs inside the simulator (simctl spawn) and folds an iPhone Duo the way
    // Device Hub's hinge slider does: a virtual HID service posting the vendor
    // event (page 0xff61, usage 0x5b) CoreDevice's hinge sends, whose payload is
    // an OSSerialize-binary dictionary {provider, source: hinge-slider-control,
    // type: range, value: degrees}. One command per line, answered "ok" or
    // "err [reason]":
    //   angle D            the hinge at D degrees (0 closed … 180 flat)
    //   sweep F T MS       from F to T degrees over MS ms (≤ 1500), easing out
    // End of input exits.

    @interface SimToolFoldDelegate : NSObject
    @property NSDictionary *properties;
    @end
    @implementation SimToolFoldDelegate
    - (id)propertyForKey:(NSString *)key forService:(id)service { return self.properties[key]; }
    - (BOOL)setProperty:(id)value forKey:(NSString *)key forService:(id)service { return YES; }
    - (id)copyEventMatching:(id)matching forService:(id)service { return nil; }
    - (BOOL)setOutputEvent:(id)event forService:(id)service { return YES; }
    - (void)notification:(uint32_t)type withProperty:(id)property forService:(id)service {}
    @end

    static void header(NSMutableData *data, uint32_t count, uint8_t type) {
      uint8_t bytes[] = { count & 255, (count >> 8) & 255, (count >> 16) & 255, type };
      [data appendBytes:bytes length:4];
    }

    static void string(NSMutableData *data, const char *text, BOOL key, BOOL last) {
      size_t length = strlen(text) + (key ? 1 : 0);
      header(data, (uint32_t)length, (key ? 8 : 9) | (last ? 0x80 : 0));
      [data appendBytes:text length:length];
      while (data.length % 4) { uint8_t zero = 0; [data appendBytes:&zero length:1]; }
    }

    static NSData *hingePayload(double degrees) {
      NSMutableData *data = [NSMutableData data];
      header(data, 0xd3, 0);
      header(data, 4, 0x81);
      string(data, "provider", YES, NO); string(data, "com.apple.Virtualization.VirtualMachines", NO, NO);
      string(data, "source", YES, NO); string(data, "hinge-slider-control", NO, NO);
      string(data, "type", YES, NO); string(data, "range", NO, NO);
      string(data, "value", YES, NO); header(data, 0x3f, 0x84);
      [data appendBytes:&degrees length:sizeof(degrees)];
      return data;
    }

    static id hingeService(void) {
      Class cls = NSClassFromString(@"HIDVirtualEventService");
      if (!cls) { return nil; }
      id service = [[cls alloc] init];
      SimToolFoldDelegate *delegate = [SimToolFoldDelegate new];
      delegate.properties = @{
        @"PrimaryUsagePage": @0xff61, @"PrimaryUsage": @0x5b,
        @"DeviceUsagePairs": @[@{ @"DeviceUsagePage": @0xff61, @"DeviceUsage": @0x5b }],
        @"Transport": @"CoreDevice", @"Product": @"SimTool fold",
        @"Built-In": @NO, @"VendorID": @0, @"ProductID": @0, @"VersionNumber": @0, @"ReportInterval": @8000,
      };
      objc_setAssociatedObject(service, @selector(properties), delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      ((void (*)(id, SEL, id))objc_msgSend)(service, sel_registerName("setDelegate:"), delegate);
      ((void (*)(id, SEL, id))objc_msgSend)(service, sel_registerName("setDispatchQueue:"), dispatch_queue_create("simtool.fold", DISPATCH_QUEUE_SERIAL));
      ((void (*)(id, SEL))objc_msgSend)(service, sel_registerName("activate"));
      return ((uint64_t (*)(id, SEL))objc_msgSend)(service, sel_registerName("serviceID")) ? service : nil;
    }

    static CFTypeRef (*vendorEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, const void *, CFIndex, uint32_t);
    static id hinge;

    static BOOL post(double degrees) {
      NSData *payload = hingePayload(degrees);
      CFTypeRef event = vendorEvent(NULL, mach_absolute_time(), 0xff61, 0x5b, 0, payload.bytes, payload.length, 0);
      if (!event) { return NO; }
      BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(hinge, sel_registerName("dispatchEvent:"), (__bridge id)event);
      CFRelease(event);
      return ok;
    }

    static BOOL inRange(double degrees) { return isfinite(degrees) && degrees >= 0 && degrees <= 180; }

    int main(void) {
      @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/HID.framework/HID", RTLD_NOW);
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        vendorEvent = iokit ? dlsym(iokit, "IOHIDEventCreateVendorDefinedEvent") : NULL;
        hinge = vendorEvent ? hingeService() : nil;
        if (!hinge) { fprintf(stderr, "this runtime has no virtual HID hinge service\n"); return 1; }
        usleep(300000);   // backboardd enumerates the new service
        char *line = NULL;
        size_t capacity = 0;
        while (getline(&line, &capacity, stdin) > 0) {
          @autoreleasepool {
            double from = 0, to = 0, ms = 0;
            char extra;
            const char *failure = "malformed command";
            if (sscanf(line, "angle %lf %c", &to, &extra) == 1) {
              failure = !inRange(to) ? "the angle is outside 0…180" : post(to) ? NULL : "the hinge event was refused";
            } else if (sscanf(line, "sweep %lf %lf %lf %c", &from, &to, &ms, &extra) == 3) {
              if (!inRange(from) || !inRange(to) || !isfinite(ms) || ms < 0 || ms > 1500) {
                failure = "the sweep is outside 0…180 or 1500 ms";
              } else {
                failure = NULL;
                int frames = MAX(1, (int)ceil(ms / 16.667));
                for (int i = 1; i <= frames && !failure; i++) {
                  double progress = (double)i / frames, eased = 1 - pow(1 - progress, 3);
                  if (!post(from + (to - from) * eased)) { failure = "the hinge event was refused"; }
                  if (i < frames) { usleep((useconds_t)(ms * 1000 / frames)); }
                }
              }
            }
            if (failure) { printf("err %s\n", failure); } else { printf("ok\n"); }
            fflush(stdout);
          }
        }
        free(line);
        ((void (*)(id, SEL))objc_msgSend)(hinge, sel_registerName("cancel"));
      }
      return 0;
    }
    """#
}
