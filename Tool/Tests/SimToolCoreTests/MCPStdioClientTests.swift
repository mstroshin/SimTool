import Foundation
import XCTest
@testable import SimToolCore

final class MCPStdioClientTests: XCTestCase {
    func testTalksJSONRPCOverPipesAndFailsWhatIsPendingWhenTheServerGoes() async throws {
        let toServer = Pipe()
        let toClient = Pipe()
        let server = FakeMCPServer(input: toServer.fileHandleForReading, output: toClient.fileHandleForWriting)
        let pingAnswered = expectation(description: "the client answers the server's ping")
        server.onPingAnswered = { pingAnswered.fulfill() }
        server.start()
        let client = MCPStdioClient(reading: toClient.fileHandleForReading, writing: toServer.fileHandleForWriting)
        let progress = ProgressBox()
        client.onProgress { progress.append($0) }

        let initialized = try await client.initialize(clientName: "simtool", clientVersion: "test")
        XCTAssertEqual(initialized.objectValue?["serverInfo"]?.objectValue?["name"], .string("fake"))
        // Both arrived before the response, on the same stream.
        XCTAssertEqual(progress.messages, ["Warming up"])
        await fulfillment(of: [pingAnswered], timeout: 5)
        XCTAssertTrue(server.sawInitializedNotification)

        // A JSON object in the text content counts as structured output.
        let echoed = try await client.callTool("Echo", arguments: [:], timeoutSeconds: 5)
        XCTAssertFalse(echoed.isError)
        XCTAssertEqual(echoed.structured?["answer"], .number(42))

        do {
            _ = try await client.callTool("Broken", arguments: [:], timeoutSeconds: 5)
            XCTFail("A JSON-RPC error must throw")
        } catch let failure as MCPStdioClient.Failure {
            XCTAssertEqual(failure, MCPStdioClient.Failure("bad arguments", code: -32602))
        }

        do {
            _ = try await client.callTool("Exit", arguments: [:], timeoutSeconds: 5)
            XCTFail("A server that goes away must fail the request waiting on it")
        } catch let failure as MCPStdioClient.Failure {
            XCTAssertTrue(failure.message.contains("closed"), failure.message)
        }
        client.close()
    }

    func testARequestTimesOut() async throws {
        let toServer = Pipe()
        let toClient = Pipe()
        let client = MCPStdioClient(reading: toClient.fileHandleForReading, writing: toServer.fileHandleForWriting)
        defer { client.close() }

        do {
            _ = try await client.request("tools/list", params: .object([:]), timeoutSeconds: 0.2)
            XCTFail("Nobody answers, so the request must time out")
        } catch let failure as MCPStdioClient.Failure {
            XCTAssertTrue(failure.message.contains("timed out"), failure.message)
        }
    }

    func testToolResultsReadStructuredContentTextAndErrors() {
        let structured = MCPToolResult(result: .object([
            "content": .array([.object(["type": .string("text"), "text": .string("summary")])]),
            "structuredContent": .object(["value": .number(1)]),
        ]))
        XCTAssertEqual(structured, MCPToolResult(isError: false, text: "summary", structured: ["value": .number(1)]))

        let failed = MCPToolResult(result: .object([
            "content": .array([.object(["type": .string("text"), "text": .string("not approved")])]),
            "isError": .bool(true),
        ]))
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.text, "not approved")
        XCTAssertNil(failed.structured)
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ message: String) {
        lock.lock()
        stored.append(message)
        lock.unlock()
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Plays an MCP server on the far end of two pipes: answers `initialize`
/// after a ping and a progress note, echoes `Echo`, fails `Broken` with a
/// JSON-RPC error, and hangs up on `Exit`.
private final class FakeMCPServer: @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let lock = NSLock()
    private var initializedNotification = false
    var onPingAnswered: (() -> Void)?

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    var sawInitializedNotification: Bool {
        lock.lock()
        defer { lock.unlock() }
        return initializedNotification
    }

    func start() {
        Thread.detachNewThread { [self] in
            var buffer = Data()
            while true {
                let data = input.availableData
                if data.isEmpty { return }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = Data(buffer[buffer.startIndex ..< newline])
                    buffer.removeSubrange(buffer.startIndex ... newline)
                    if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        handle(message)
                    }
                }
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        let id = message["id"]
        switch message["method"] as? String {
        case "initialize":
            send(["jsonrpc": "2.0", "id": "server-1", "method": "ping"])
            send(["jsonrpc": "2.0", "method": "notifications/progress", "params": ["progressToken": 1, "progress": 0, "message": "Warming up"]])
            send(["jsonrpc": "2.0", "id": id!, "result": ["serverInfo": ["name": "fake"]]])
        case "notifications/initialized":
            lock.lock()
            initializedNotification = true
            lock.unlock()
        case "tools/call":
            switch (message["params"] as? [String: Any])?["name"] as? String {
            case "Echo":
                send(["jsonrpc": "2.0", "id": id!, "result": ["content": [["type": "text", "text": #"{"answer":42}"#]]]])
            case "Broken":
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32602, "message": "bad arguments"]])
            default:
                try? output.close()
            }
        case nil where (id as? String) == "server-1" && message["result"] != nil:
            onPingAnswered?()
        default:
            break
        }
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(UInt8(ascii: "\n"))
        output.write(data)
    }
}
