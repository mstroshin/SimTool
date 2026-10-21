import Foundation
import SimToolCore
import SimToolStream

/// The 3D preview of a foldable: `simtool duo-render` running while a viewer
/// watches it, its frames relayed to every viewer that asked for the 3D view
/// (`/stream.avcc?view=3d`). It renders from the device model in the user's
/// Xcode; without one, or when the renderer fails, the viewer is told why and
/// keeps the flat screen.
final class Duo3DStream: @unchecked Sendable {
    /// One viewer's connection: `write` returns false once it is gone.
    final class Client: @unchecked Sendable {
        let write: (Data) -> Bool
        let ended = DispatchSemaphore(value: 0)

        init(write: @escaping (Data) -> Bool) {
            self.write = write
        }
    }

    struct Look: Equatable {
        var dark: Bool
        var background: String
    }

    private let deviceUDID: String
    private let executable: URL
    private let lock = NSLock()
    private var clients: [ObjectIdentifier: Client] = [:]
    private var process: Process?
    private var input: FileHandle?
    private var reader = AVCCEnvelopeReader()
    private var description: Data?
    private var projection: Data?
    private var errors = Data()
    private var failure: (reason: String, at: Date)?
    private var stopTimer: DispatchWorkItem?
    private var state: (panel: String, hinge: Double, look: Look)?

    init(deviceUDID: String, executable: URL) {
        self.deviceUDID = deviceUDID
        self.executable = executable
    }

    /// Why the last renderer failed, for a while after it did.
    var recentFailure: String? {
        lock.withLock {
            guard let failure, Date().timeIntervalSince(failure.at) < 30 else { return nil }
            return failure.reason
        }
    }

    /// Joins a viewer, starting the renderer for the first one. Throws when
    /// the renderer cannot start.
    func attach(_ client: Client, model: URL, layout: SimulatorDisplayLayout, panel: String, hinge: Double, look: Look) throws {
        let cached: [Data] = try lock.withLock {
            stopTimer?.cancel()
            stopTimer = nil
            clients[ObjectIdentifier(client)] = client
            if process?.isRunning != true { try startLocked(model: model, layout: layout) }
            state = nil
            return [description, projection].compactMap { $0 }
        }
        for data in cached { _ = client.write(data) }
        update(panel: panel, hinge: hinge, look: look, keyframe: true)
    }

    func detach(_ client: Client) {
        lock.withLock {
            clients[ObjectIdentifier(client)] = nil
            guard clients.isEmpty, stopTimer == nil else { return }
            // A viewer that reloads comes back within seconds: keep the model loaded.
            let timer = DispatchWorkItem { [weak self] in self?.stop() }
            stopTimer = timer
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timer)
        }
    }

    /// Tells the renderer what changed: the lit panel, the hinge, the viewer's look.
    func update(panel: String, hinge: Double, look: Look? = nil, keyframe: Bool = false) {
        lock.withLock {
            guard let input, process?.isRunning == true else { return }
            let next = (panel: panel, hinge: hinge, look: look ?? state?.look ?? Look(dark: true, background: "#000000"))
            guard keyframe || state.map({ $0.panel != next.panel || $0.hinge != next.hinge || $0.look != next.look }) ?? true else { return }
            state = next
            var message: [String: Any] = ["panel": panel, "hinge": hinge, "dark": next.look.dark, "background": next.look.background]
            if keyframe { message["keyframe"] = true }
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
            try? input.write(contentsOf: data + Data("\n".utf8))
        }
    }

    func stop() {
        let (running, ended) = lock.withLock { () -> (Process?, [Client]) in
            defer {
                process = nil
                input = nil
                clients.removeAll()
                stopTimer = nil
            }
            return (process, Array(clients.values))
        }
        if let running, running.isRunning { running.terminate() }
        for client in ended { client.ended.signal() }
    }

    /// Caller holds `lock`.
    private func startLocked(model: URL, layout: SimulatorDisplayLayout) throws {
        guard let cover = layout.display(named: "cover"), let inner = layout.display(named: "inner") else {
            throw SimToolError("only a foldable device has a 3D preview")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "duo-render", "--device", deviceUDID, "--model", model.path,
            "--cover", "\(cover.width)x\(cover.height)", "--inner", "\(inner.width)x\(inner.height)",
        ]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        reader = AVCCEnvelopeReader()
        description = nil
        projection = nil
        errors = Data()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.relay(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { handle.readabilityHandler = nil; return }
            self.lock.withLock { if self.errors.count < 4096 { self.errors.append(data) } }
        }
        process.terminationHandler = { [weak self] ended in self?.ended(ended) }
        try process.run()
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        self.process = process
        input = stdin.fileHandleForWriting
    }

    private func relay(_ data: Data) {
        let (envelopes, targets): ([AVCCEnvelopeReader.Envelope], [Client]) = lock.withLock {
            let envelopes = reader.push(data)
            for envelope in envelopes {
                if envelope.tag == AVCCEnvelope.descriptionTag { description = envelope.bytes }
                if envelope.tag == AVCCEnvelope.projectionTag { projection = envelope.bytes }
            }
            return (envelopes, Array(clients.values))
        }
        guard !envelopes.isEmpty else { return }
        let bytes = envelopes.reduce(into: Data()) { $0.append($1.bytes) }
        for client in targets where !client.write(bytes) {
            lock.withLock { clients[ObjectIdentifier(client)] = nil }
            client.ended.signal()
        }
    }

    /// The renderer ended: by `stop`, or by itself — then its viewers are
    /// told why by the next connection they make.
    private func ended(_ process: Process) {
        let watchers: [Client] = lock.withLock {
            guard self.process === process else { return [] }
            self.process = nil
            input = nil
            let said = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = said.split(separator: "\n").last.map(String.init) ?? "the 3D renderer exited (\(process.terminationStatus))"
            failure = (reason, Date())
            DebugLog.write("duo3d", "renderer ended: \(reason)")
            defer { clients.removeAll() }
            return Array(clients.values)
        }
        for client in watchers { client.ended.signal() }
    }
}
