import Foundation
import SimToolStream

final class ClientManager: @unchecked Sendable {
    private let queue = DispatchQueue(label: "simtool.clients")
    private let stateLock = NSLock()

    private var cachedDescription: Data?
    private var avccClients: [ObjectIdentifier: StreamClient] = [:]
    private var avccClientCount = 0
    private var nextID = 0

    var onAvccClientConnect: (() -> Void)?

    func addAvccClient() -> StreamClient {
        let client = StreamClient(id: nextClientID())
        let key = ObjectIdentifier(client)
        stateLock.lock(); avccClientCount += 1; stateLock.unlock()
        queue.async { self.avccClients[key] = client }
        return client
    }

    func removeAvccClient(_ client: StreamClient) {
        let key = ObjectIdentifier(client)
        stateLock.lock(); avccClientCount = max(0, avccClientCount - 1); stateLock.unlock()
        queue.async { self.avccClients.removeValue(forKey: key) }
    }

    func hasAvccClients() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return avccClientCount > 0
    }

    func clientCounts() -> StreamClientCounts {
        queue.sync {
            StreamClientCounts(avcc: avccClients.count)
        }
    }

    func sendInitialAvcc(to client: StreamClient) {
        queue.async {
            if let description = self.cachedDescription { client.send(description) }
        }
        onAvccClientConnect?()
    }

    func broadcastAvcc(_ envelope: Data, isDescription: Bool = false, onSent: ((Int) -> Void)? = nil) {
        queue.async {
            if isDescription { self.cachedDescription = envelope }
            var sent = 0
            for client in self.avccClients.values {
                if client.send(envelope) { sent += 1 }
            }
            onSent?(sent)
        }
    }

    func closeAll() {
        queue.sync {
            for client in avccClients.values { client.close() }
            avccClients.removeAll()
        }
        stateLock.lock(); avccClientCount = 0; stateLock.unlock()
    }

    private func nextClientID() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }
}

final class StreamClient: @unchecked Sendable {
    let id: Int
    private var writer: ((Data) -> Bool)?
    private var closed = false

    init(id: Int) { self.id = id }

    func setWriter(_ writer: @escaping (Data) -> Bool) {
        self.writer = writer
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        guard !closed, let writer else { return false }
        let didSend = writer(data)
        if !didSend { closed = true }
        return didSend
    }

    func close() {
        closed = true
        writer = nil
    }
}
