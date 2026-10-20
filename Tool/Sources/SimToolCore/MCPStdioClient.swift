import Darwin
import Foundation

/// What a `tools/call` returned: the tool's structured output when it declares
/// one, its text content otherwise, and whether the tool reported a failure.
public struct MCPToolResult: Equatable, Sendable {
    public var isError: Bool
    public var text: String
    public var structured: [String: JSONValue]?

    public init(isError: Bool = false, text: String = "", structured: [String: JSONValue]? = nil) {
        self.isError = isError
        self.text = text
        self.structured = structured
    }

    /// Reads a `tools/call` result. A tool that declares no output schema may
    /// still answer with a JSON object as its only text, so that is tried as
    /// structured output too.
    public init(result: JSONValue) {
        let object = result.objectValue ?? [:]
        let texts = (object["content"]?.arrayValue ?? []).compactMap { item -> String? in
            guard item.objectValue?["type"]?.stringValue == "text" else { return nil }
            return item.objectValue?["text"]?.stringValue
        }
        let text = texts.joined(separator: "\n")
        var structured = object["structuredContent"]?.objectValue
        if structured == nil, let data = text.data(using: .utf8) {
            structured = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
        }
        self.init(isError: object["isError"]?.boolValue ?? false, text: text, structured: structured)
    }
}

/// Anything that runs MCP tools — the stdio client below, or a stand-in in
/// tests.
public protocol MCPToolCalling: Sendable {
    func callTool(_ name: String, arguments: [String: JSONValue], timeoutSeconds: TimeInterval?) async throws -> MCPToolResult
}

/// A Model Context Protocol client speaking newline-delimited JSON-RPC 2.0
/// over a pair of pipes — in practice the stdio of a server it launched
/// (`launch`). Requests may overlap; each waits for the response with its id.
/// Requests the server sends back are answered (`ping`) or refused, and
/// `notifications/progress` messages go to `onProgress`.
public final class MCPStdioClient: MCPToolCalling, @unchecked Sendable {
    public struct Failure: Error, LocalizedError, Equatable {
        public var message: String
        public var code: Int?

        public init(_ message: String, code: Int? = nil) {
            self.message = message
            self.code = code
        }

        public var errorDescription: String? { message }
    }

    private let lock = NSLock()
    private let writeLock = NSLock()
    private let reading: FileHandle
    private let writing: FileHandle
    private var process: Process?
    private var stderrText = ""
    private var partialLine = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var closedReason: String?
    private var progressHandler: (@Sendable (String) -> Void)?

    /// `reading` carries the server's messages, `writing` takes ours.
    public init(reading: FileHandle, writing: FileHandle) {
        self.reading = reading
        self.writing = writing
        reading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                // A server that exits explains why on stderr, which may still
                // be arriving; give it a moment before failing what is pending.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    self.finish(reason: "The MCP server closed its output")
                }
            } else {
                self.receive(data)
            }
        }
    }

    /// Starts `executable` and talks MCP to it over its stdin and stdout. Its
    /// stderr is kept for the error that reports it exiting.
    public static func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> MCPStdioClient {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let client = MCPStdioClient(reading: output.fileHandleForReading, writing: input.fileHandleForWriting)
        errors.fileHandleForReading.readabilityHandler = { [weak client] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                client?.appendStderr(data)
            }
        }
        client.process = process
        do {
            try process.run()
        } catch {
            throw SimToolError("Unable to start \(executable.path) \(arguments.joined(separator: " ")): \(error.localizedDescription)")
        }
        return client
    }

    deinit {
        reading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
    }

    /// Receives the `message` of each `notifications/progress` the server sends.
    public func onProgress(_ handler: (@Sendable (String) -> Void)?) {
        lock.lock()
        progressHandler = handler
        lock.unlock()
    }

    /// The MCP handshake: `initialize`, then `notifications/initialized`.
    /// Returns the server's `initialize` result.
    @discardableResult
    public func initialize(
        clientName: String,
        clientVersion: String,
        timeoutSeconds: TimeInterval? = 60
    ) async throws -> JSONValue {
        let result = try await request("initialize", params: .object([
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion),
            ]),
        ]), timeoutSeconds: timeoutSeconds)
        try send(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized"),
        ]))
        return result
    }

    /// The names `tools/list` reports.
    public func toolNames(timeoutSeconds: TimeInterval? = 60) async throws -> Set<String> {
        let result = try await request("tools/list", params: .object([:]), timeoutSeconds: timeoutSeconds)
        let tools = result.objectValue?["tools"]?.arrayValue ?? []
        return Set(tools.compactMap { $0.objectValue?["name"]?.stringValue })
    }

    public func callTool(
        _ name: String,
        arguments: [String: JSONValue],
        timeoutSeconds: TimeInterval?
    ) async throws -> MCPToolResult {
        let result = try await request("tools/call", params: .object([
            "name": .string(name),
            "arguments": .object(arguments),
        ]), timeoutSeconds: timeoutSeconds)
        return MCPToolResult(result: result)
    }

    /// Sends one request and waits for its response's `result`; a JSON-RPC
    /// `error` throws `Failure` with the server's message.
    public func request(
        _ method: String,
        params: JSONValue,
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> JSONValue {
        let id = reserveID()
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let closedReason {
                lock.unlock()
                continuation.resume(throwing: Failure(closedReason))
                return
            }
            pending[id] = continuation
            lock.unlock()
            do {
                try send(message)
            } catch {
                resume(id, with: .failure(error))
                return
            }
            if let timeoutSeconds {
                Task.detached { [weak self] in
                    try? await Task.sleep(for: .milliseconds(Int(timeoutSeconds * 1000)))
                    self?.resume(id, with: .failure(Failure("\(method) timed out after \(Int(timeoutSeconds)) seconds")))
                }
            }
        }
    }

    /// Stops the server: closes its stdin, then terminates it if it is still
    /// running. Pending requests fail.
    public func close() {
        try? writing.close()
        lock.lock()
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
        finish(reason: "The MCP client closed the connection")
    }

    private func reserveID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    private func send(_ message: JSONValue) throws {
        var data = try JSON.compactEncoder.encode(message)
        data.append(UInt8(ascii: "\n"))
        // A reply to the server's ping can race a request; lines must not interleave.
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try writing.write(contentsOf: data)
        } catch {
            throw Failure("Unable to write to the MCP server: \(error.localizedDescription)")
        }
    }

    private func appendStderr(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        stderrText += text
        if stderrText.count > 8_000 { stderrText = String(stderrText.suffix(8_000)) }
        lock.unlock()
    }

    private func receive(_ data: Data) {
        lock.lock()
        partialLine.append(data)
        var lines: [Data] = []
        while let newline = partialLine.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(partialLine[partialLine.startIndex ..< newline])
            partialLine.removeSubrange(partialLine.startIndex ... newline)
        }
        lock.unlock()
        for line in lines where !line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) {
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line)).objectValue else {
                DebugLog.write("mcp", "unparseable line: \(String(decoding: line, as: UTF8.self))")
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: [String: JSONValue]) {
        let method = message["method"]?.stringValue
        let id = message["id"]
        switch (method, id) {
        case let (nil, id?):
            guard let number = id.doubleValue else { return }
            if let error = message["error"]?.objectValue {
                let text = error["message"]?.stringValue ?? "MCP request failed"
                resume(Int(number), with: .failure(Failure(text, code: error["code"]?.doubleValue.map { Int($0) })))
            } else {
                resume(Int(number), with: .success(message["result"] ?? .null))
            }
        case let ("ping"?, id?):
            try? send(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object([:])]))
        case let (method?, id?):
            try? send(.object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object([
                    "code": .number(-32601),
                    "message": .string("simtool does not handle \(method)"),
                ]),
            ]))
        case ("notifications/progress"?, nil):
            guard let text = message["params"]?.objectValue?["message"]?.stringValue, !text.isEmpty else { return }
            lock.lock()
            let handler = progressHandler
            lock.unlock()
            handler?(text)
        default:
            break
        }
    }

    private func resume(_ id: Int, with result: Result<JSONValue, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func finish(reason: String) {
        lock.lock()
        if closedReason == nil {
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            closedReason = detail.isEmpty ? reason : "\(reason): \(detail)"
        }
        let failure = Failure(closedReason!)
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for continuation in waiting.values {
            continuation.resume(throwing: failure)
        }
    }
}
