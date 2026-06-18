import Foundation

/// Periodically fetches mock rules from the SimTool server and applies them to a `MockStore`.
/// Best-effort: network failures are swallowed and the last known rules remain in effect.
public final class MockRulePoller: @unchecked Sendable {
    private let store: MockStore
    private let session: URLSession
    private let mocksURL: URL
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(serverURL: URL, store: MockStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
        self.mocksURL = Self.endpointURL(for: serverURL)
    }

    /// Performs one fetch and applies it. Safe to call repeatedly.
    public func refresh() async {
        let since = store.currentGeneration
        var components = URLComponents(url: mocksURL, resolvingAgainstBaseURL: false)
        if since >= 0 { components?.queryItems = [URLQueryItem(name: "since", value: String(since))] }
        guard let url = components?.url else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, _) = try await session.data(for: request)
            let payload = try NetworkLoggerJSON.decoder.decode(MockRuleListPayload.self, from: data)
            if !payload.unchanged {
                store.replace(rules: payload.rules, generation: payload.generation)
            }
        } catch {
            // Best-effort: keep last known rules.
        }
    }

    public func start(intervalSeconds: Double = 2) {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        task = nil
    }

    static func endpointURL(for serverURL: URL) -> URL {
        let path = serverURL.path
        if path.hasSuffix("/api/v1/mocks") { return serverURL }
        if path.hasSuffix("/api/v1") { return serverURL.appendingPathComponent("mocks") }
        return serverURL.appendingPathComponent("api/v1/mocks")
    }
}
