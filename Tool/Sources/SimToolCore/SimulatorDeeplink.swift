import Foundation

public struct SimulatorDeeplinkOpenPayload: Codable, Equatable, Sendable {
    public var name: String
    public var url: String
    public var device: SimulatorDevice
    public var opened: Bool

    public init(name: String, url: String, device: SimulatorDevice, opened: Bool = true) {
        self.name = name
        self.url = url
        self.device = device
        self.opened = opened
    }
}

public enum SimulatorDeeplinkClient {
    /// Opens a deeplink URL on the given (booted) simulator via
    /// `xcrun simctl openurl`. Surfaces the underlying simctl failure verbatim.
    public static func open(
        name: String,
        url: String,
        device: SimulatorDevice,
        timeoutSeconds: TimeInterval? = 60
    ) async throws -> SimulatorDeeplinkOpenPayload {
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "openurl", device.udid, url],
            timeoutSeconds: timeoutSeconds
        )
        guard output.status == 0 else {
            let detail = output.stderrString.isEmpty ? output.stdoutString : output.stderrString
            throw SimToolError("simctl openurl failed for \(url): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return SimulatorDeeplinkOpenPayload(name: name, url: url, device: device)
    }
}
