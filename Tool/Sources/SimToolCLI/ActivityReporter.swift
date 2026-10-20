import Foundation
import SimToolCore

/// Tells the servers watching a simulator what a CLI command does to it.
///
/// `simtool input …` acts on the device in its own process, so without this a
/// person watching the viewer sees the screen change and nothing to say who
/// changed it. Best effort by design: a server that is slow or gone costs the
/// command at most half a second and never its result, and with no server
/// watching the device nothing is sent at all.
struct ActivityReporter: Sendable {
    static let timeout: TimeInterval = 0.5

    /// The `/api/v1` URLs of the live servers streaming this device.
    let servers: [URL]
    let deviceUDID: String

    init(device: SimulatorDevice, sessions: [SessionInfo]? = nil, isAlive: (Int32) -> Bool = { isProcessAlive($0) }) {
        deviceUDID = device.udid
        servers = Self.servers(watching: device.udid, among: sessions ?? (try? SessionStore.shared.list()) ?? [], isAlive: isAlive)
    }

    /// Every running server on this device — whichever project started it, its
    /// viewer shows this device.
    static func servers(watching udid: String, among sessions: [SessionInfo], isAlive: (Int32) -> Bool) -> [URL] {
        var seen = Set<String>()
        return sessions
            .filter { $0.device.udid == udid && isAlive($0.pid) }
            .compactMap { session in seen.insert(session.api).inserted ? URL(string: session.api) : nil }
    }

    /// Runs a touch command: `stroke` works it out, `play` plays it. Where the
    /// finger goes is reported before it goes down, so the viewer can draw it
    /// while it moves.
    func touch(
        _ input: SimulatorInputPayload,
        stroke: () async throws -> TouchStroke,
        play: (TouchStroke) async throws -> ProcessOutput
    ) async throws -> ProcessOutput {
        let action = input.action ?? ""
        guard !servers.isEmpty else { return try await play(try await stroke()) }
        let planned: TouchStroke
        do {
            planned = try await stroke()
        } catch {
            let words = DeviceActivityWording.describe(input, action: action)
            await send(DeviceActivityReport(kind: words.kind, title: words.title, detail: words.detail, status: .failed, error: message(of: error)))
            throw error
        }
        let words = DeviceActivityWording.describe(input, action: action, stroke: planned)
        let screen = try? await SimulatorInputClient.screenSize(deviceUDID: deviceUDID)
        let started = await begin(DeviceActivityReport(
            kind: words.kind,
            title: words.title,
            detail: words.detail,
            gesture: DeviceActivityGesture(stroke: planned, screen: screen)
        ))
        return try await finishing(started) { try await play(planned) }
    }

    /// Runs any other device command as one reported activity.
    func command(_ input: SimulatorInputPayload, perform: () async throws -> ProcessOutput) async throws -> ProcessOutput {
        guard !servers.isEmpty else { return try await perform() }
        let words = DeviceActivityWording.describe(input, action: input.action ?? "")
        let started = await begin(DeviceActivityReport(kind: words.kind, title: words.title, detail: words.detail))
        return try await finishing(started, perform)
    }

    /// Reports something already done — an app launched, a deeplink opened.
    func done(kind: String, title: String, detail: String? = nil) async {
        guard !servers.isEmpty else { return }
        await send(DeviceActivityReport(kind: kind, title: title, detail: detail, status: .done))
    }

    private func finishing<T>(_ started: [(URL, Int)], _ body: () async throws -> T) async throws -> T {
        do {
            let result = try await body()
            await finish(started, error: nil)
            return result
        } catch {
            await finish(started, error: error)
            throw error
        }
    }

    /// The entry each server opened for the report, to finish it later.
    private func begin(_ report: DeviceActivityReport) async -> [(URL, Int)] {
        var started: [(URL, Int)] = []
        for server in servers {
            if let id = await post(report, to: server) { started.append((server, id)) }
        }
        return started
    }

    private func finish(_ started: [(URL, Int)], error: Error?) async {
        for (server, id) in started {
            _ = await post(DeviceActivityReport(id: id, status: error == nil ? .done : .failed, error: error.map(message(of:))), to: server)
        }
    }

    private func send(_ report: DeviceActivityReport) async {
        for server in servers { _ = await post(report, to: server) }
    }

    private func post(_ report: DeviceActivityReport, to server: URL) async -> Int? {
        var sent = report
        sent.actor = sent.actor ?? .agent
        sent.via = sent.via ?? "cli"
        var request = URLRequest(url: server.appendingPathComponent("activity"), timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSON.data(sent, pretty: false)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSON.decoder.decode(DeviceActivity.self, from: data))?.id
    }

    private func message(of error: Error) -> String {
        (error as? SimToolError)?.message ?? error.localizedDescription
    }
}
