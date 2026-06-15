import Foundation

/// Small persisted marker that lets the logger re-activate in the simulator after a cold relaunch
/// that drops the `SIMTOOL_*` environment (icon tap, Xcode run). Written when the logger is armed
/// from the environment and read back on later launches.
public struct NetworkLoggerActivation: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var serverURL: String?

    public init(enabled: Bool, serverURL: String? = nil) {
        self.enabled = enabled
        self.serverURL = serverURL
    }
}

/// Reads and writes the persisted activation marker. Injectable so tests can drive self-activation
/// without touching the real app container.
public protocol NetworkLoggerActivationStore: Sendable {
    func load() -> NetworkLoggerActivation?
    func save(_ activation: NetworkLoggerActivation)
}

/// Default activation store, persisting under the same namespaced app-container location as the
/// file sink (`Library/Caches/SimToolNetworkLogger/activation.json`).
public final class NetworkLoggerFileActivationStore: NetworkLoggerActivationStore, @unchecked Sendable {
    public static let fileName = "activation.json"

    public let directoryURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "simtool.network-logger.activation-store")

    public init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let defaultDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(NetworkLoggerFileSink.directoryName, isDirectory: true)
            ?? fileManager.temporaryDirectory.appendingPathComponent(NetworkLoggerFileSink.directoryName, isDirectory: true)
        self.directoryURL = directoryURL ?? defaultDirectory
    }

    public var fileURL: URL {
        directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    public func load() -> NetworkLoggerActivation? {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? NetworkLoggerJSON.decoder.decode(NetworkLoggerActivation.self, from: data)
        }
    }

    public func save(_ activation: NetworkLoggerActivation) {
        queue.sync {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let data = try NetworkLoggerJSON.data(activation)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                // Persistence is best-effort and must never affect the host app.
            }
        }
    }
}
