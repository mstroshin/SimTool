import Foundation

public struct NetworkLoggerConfiguration: Equatable, Sendable {
    public var appBundleID: String?
    public var appDisplayName: String?
    public var fileSinkEnabled: Bool
    public var serverSinkURL: URL?
    public var maxStoredEvents: Int
    public var maxFileBytes: Int
    public var redaction: NetworkLoggerRedactionConfiguration
    public var captureBodyPreviews: Bool
    public var maxBodyPreviewBytes: Int
    public var batchSize: Int
    public var serverDeliveryTimeout: TimeInterval

    public init(
        appBundleID: String? = Bundle.main.bundleIdentifier,
        appDisplayName: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
        fileSinkEnabled: Bool = true,
        serverSinkURL: URL? = nil,
        maxStoredEvents: Int = 1_000,
        maxFileBytes: Int = 1_000_000,
        redaction: NetworkLoggerRedactionConfiguration = NetworkLoggerRedactionConfiguration(),
        captureBodyPreviews: Bool = false,
        maxBodyPreviewBytes: Int = 2_048,
        batchSize: Int = 25,
        serverDeliveryTimeout: TimeInterval = 2
    ) {
        self.appBundleID = appBundleID
        self.appDisplayName = appDisplayName
        self.fileSinkEnabled = fileSinkEnabled
        self.serverSinkURL = serverSinkURL
        self.maxStoredEvents = maxStoredEvents
        self.maxFileBytes = maxFileBytes
        self.redaction = redaction
        self.captureBodyPreviews = captureBodyPreviews
        self.maxBodyPreviewBytes = maxBodyPreviewBytes
        self.batchSize = batchSize
        self.serverDeliveryTimeout = serverDeliveryTimeout
    }
}

public extension NetworkLoggerConfiguration {
    /// Environment keys a host app sets to opt into capture and live delivery.
    enum EnvironmentKey {
        public static let enabled = "SIMTOOL_NETWORK_LOGGER"
        public static let serverURL = "SIMTOOL_SERVER_URL"
    }

    /// Builds a configuration from process environment, or `nil` when capture is not enabled.
    ///
    /// Capture is enabled only when `SIMTOOL_NETWORK_LOGGER` is truthy. Live delivery targets
    /// `SIMTOOL_SERVER_URL` when it is a valid absolute URL; otherwise the server sink is omitted.
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NetworkLoggerConfiguration? {
        guard isTruthy(environment[EnvironmentKey.enabled]) else { return nil }

        let serverSinkURL: URL? = {
            guard let raw = environment[EnvironmentKey.serverURL], !raw.isEmpty,
                  let url = URL(string: raw), url.scheme != nil else { return nil }
            return url
        }()

        return NetworkLoggerConfiguration(
            fileSinkEnabled: false,
            serverSinkURL: serverSinkURL,
            captureBodyPreviews: true
        )
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(value)
    }
}

public extension NetworkLoggerConfiguration {
    /// Local default SimTool server, used when self-activating without a persisted server URL.
    static let defaultServerURLString = "http://127.0.0.1:3200"

    /// Whether the host process is running in the iOS Simulator. Self-activation is gated on this so
    /// device/TestFlight/App Store builds are never auto-enabled.
    static var isRunningInSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Resolves a configuration from the environment and — **only in the simulator** — a persisted
    /// activation marker, so capture survives a cold relaunch that drops the `SIMTOOL_*`
    /// environment (icon tap, Xcode run).
    ///
    /// - A truthy `SIMTOOL_NETWORK_LOGGER` builds the environment configuration and, in the
    ///   simulator, persists a marker (including the resolved server URL) so later relaunches
    ///   self-activate.
    /// - An explicitly falsy `SIMTOOL_NETWORK_LOGGER` opts out and never self-activates,
    ///   regardless of any persisted marker.
    /// - With no `SIMTOOL_NETWORK_LOGGER`, the simulator path self-activates from a persisted
    ///   enabled marker, targeting its server URL or the local default when the URL is missing.
    ///   Non-simulator builds never read the marker and behave like `fromEnvironment`.
    static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isSimulator: Bool = NetworkLoggerConfiguration.isRunningInSimulator,
        activationStore: NetworkLoggerActivationStore? = nil,
        defaultServerURL: URL? = URL(string: defaultServerURLString)
    ) -> NetworkLoggerConfiguration? {
        let store: NetworkLoggerActivationStore? = isSimulator ? (activationStore ?? NetworkLoggerFileActivationStore()) : nil
        let rawEnabled = environment[EnvironmentKey.enabled]
        let hasExplicitEnv = (rawEnabled?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)

        // Explicit environment value present: it wins over any persisted marker.
        if hasExplicitEnv {
            guard let configuration = fromEnvironment(environment) else { return nil }  // falsy → opt out
            store?.save(NetworkLoggerActivation(enabled: true, serverURL: configuration.serverSinkURL?.absoluteString))
            return configuration
        }

        // No environment opt-in: only the simulator self-activates, and only from an enabled marker.
        guard let marker = store?.load(), marker.enabled else { return nil }
        let serverURL = marker.serverURL.flatMap { URL(string: $0) } ?? defaultServerURL
        return NetworkLoggerConfiguration(
            fileSinkEnabled: false,
            serverSinkURL: serverURL,
            captureBodyPreviews: true
        )
    }
}
