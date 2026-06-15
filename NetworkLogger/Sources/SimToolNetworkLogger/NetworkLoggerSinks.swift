import Foundation

public protocol NetworkLoggerSink: Sendable {
    func record(_ events: [NetworkLoggerEvent]) async
}

public final class NetworkLoggerFileSink: NetworkLoggerSink, @unchecked Sendable {
    public static let directoryName = "SimToolNetworkLogger"
    public static let eventsFileName = "events.jsonl"
    public static let appContainerRelativePath = "Library/Caches/SimToolNetworkLogger/events.jsonl"

    public let directoryURL: URL
    public let maxFileBytes: Int

    private let queue = DispatchQueue(label: "simtool.network-logger.file-sink")
    private let fileManager: FileManager

    public init(
        directoryURL: URL? = nil,
        maxFileBytes: Int = 1_000_000,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let defaultDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            ?? fileManager.temporaryDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
        self.directoryURL = directoryURL ?? defaultDirectory
        self.maxFileBytes = maxFileBytes
    }

    public var fileURL: URL {
        directoryURL.appendingPathComponent(Self.eventsFileName, isDirectory: false)
    }

    public func record(_ events: [NetworkLoggerEvent]) async {
        guard !events.isEmpty else { return }
        queue.sync {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: fileURL.path) {
                    fileManager.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                for event in events {
                    let data = try NetworkLoggerJSON.data(event)
                    try handle.write(contentsOf: data)
                    try handle.write(contentsOf: Data("\n".utf8))
                }
                try enforceMaximumSize()
            } catch {
                // Logging must never affect the host app's original network operation.
            }
        }
    }

    private func enforceMaximumSize() throws {
        guard maxFileBytes > 0,
              let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > maxFileBytes else { return }

        let data = try Data(contentsOf: fileURL)
        var suffix = Data(data.suffix(maxFileBytes))
        if let newline = suffix.firstIndex(of: UInt8(ascii: "\n")), newline < suffix.endIndex - 1 {
            suffix.removeSubrange(suffix.startIndex...newline)
        }
        try suffix.write(to: fileURL, options: .atomic)
    }
}

public final class NetworkLoggerServerSink: NetworkLoggerSink, @unchecked Sendable {
    public let serverURL: URL
    public let timeout: TimeInterval

    private let session: URLSession

    public init(serverURL: URL, session: URLSession = .shared, timeout: TimeInterval = 2) {
        self.serverURL = serverURL
        self.session = session
        self.timeout = timeout
    }

    public func record(_ events: [NetworkLoggerEvent]) async {
        guard !events.isEmpty else { return }
        do {
            var request = URLRequest(url: endpointURL)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try NetworkLoggerJSON.data(NetworkLoggerBatchPayload(
                events: events,
                source: "ios-app",
                pid: Int(ProcessInfo.processInfo.processIdentifier)
            ))
            _ = try await session.data(for: request)
        } catch {
            // Live export is best-effort and must not affect app networking.
        }
    }

    private var endpointURL: URL {
        let path = serverURL.path
        if path.hasSuffix("/api/v1/network/events") { return serverURL }
        if path.hasSuffix("/api/v1") { return serverURL.appendingPathComponent("network/events") }
        return serverURL.appendingPathComponent("api/v1/network/events")
    }
}

public enum NetworkLoggerJSONL {
    public static func readEvents(from fileURL: URL, filter: NetworkLoggerEventFilter = NetworkLoggerEventFilter()) throws -> NetworkLoggerEventsPayload {
        let data = try Data(contentsOf: fileURL)
        let text = String(decoding: data, as: UTF8.self)
        let events = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> NetworkLoggerEvent? in
            try? NetworkLoggerJSON.decoder.decode(NetworkLoggerEvent.self, from: Data(line.utf8))
        }
        return NetworkLoggerEventsPayload(events: filter.apply(to: events))
    }
}

public final class NetworkLoggerEventStore: @unchecked Sendable {
    public let capacity: Int

    private let lock = NSLock()
    private var events: [NetworkLoggerEvent] = []

    public init(capacity: Int = 1_000) {
        self.capacity = max(0, capacity)
    }

    @discardableResult
    public func ingest(_ incomingEvents: [NetworkLoggerEvent]) -> NetworkLoggerIngestionResponse {
        lock.lock()
        defer { lock.unlock() }
        guard capacity > 0 else { return NetworkLoggerIngestionResponse(acceptedCount: 0) }
        events.append(contentsOf: incomingEvents.suffix(capacity))
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        return NetworkLoggerIngestionResponse(acceptedCount: incomingEvents.count)
    }

    public func query(filter: NetworkLoggerEventFilter = NetworkLoggerEventFilter()) -> NetworkLoggerEventsPayload {
        lock.lock()
        let snapshot = events
        lock.unlock()
        return NetworkLoggerEventsPayload(events: filter.apply(to: snapshot))
    }

    /// Removes every stored event attributed to `launchId`, returning how many were dropped.
    @discardableResult
    public func deleteEvents(launchId: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let before = events.count
        events.removeAll { $0.launchId == launchId }
        return before - events.count
    }
}
