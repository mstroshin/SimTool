import Foundation
import XCTest
@testable import SimToolClient
import SimToolCore

/// What happens before the recorder starts. The phases write their name into one
/// journal file — a `setup:` command is a shell command, so a file is the only
/// thing it and the Swift side can both append to.
final class TestRunPhaseOrderTests: XCTestCase {
    private var journal = URL(fileURLWithPath: "/dev/null")

    override func setUp() {
        super.setUp()
        journal = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phase-order-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: journal.path, contents: Data())
        PhaseMockProtocol.journalPath = journal.path
    }

    override func tearDown() {
        PhaseMockProtocol.journalPath = nil
        try? FileManager.default.removeItem(at: journal)
        super.tearDown()
    }

    // The recorder starts when the session starts, so everything before that is
    // off camera. A `setup:` that rebuilds the app used to be filmed in full —
    // minutes of an Xcode build inside a video meant to show a test.
    func testTheAppIsBuiltAndTheScenarioStagedBeforeAnythingIsRecorded() async {
        let path = journal.path
        let executor = makeExecutor(prepareApp: { Self.append("prepare", to: path) })

        _ = await executor.run(definition(setup: ["echo setup >> \(path)"]))

        XCTAssertEqual(phases().prefix(3).map { $0 }, ["prepare", "setup", "session-start"], phases().description)
    }

    // A build that fails is not a failing claim — there is no build to judge —
    // so the run is infra, and nothing was recorded to review.
    func testAFailedBuildEndsTheRunAsInfraWithoutASession() async {
        let executor = makeExecutor(prepareApp: { throw SimToolError("xcodebuild: the scheme does not exist") })

        let result = await executor.run(definition(setup: []))

        XCTAssertEqual(result.verdict, .infra)
        XCTAssertTrue(result.infraReason?.contains("does not exist") == true, result.infraReason ?? "")
        XCTAssertFalse(phases().contains("session-start"), phases().description)
    }

    // MARK: - fixtures

    private func phases() -> [String] {
        (try? String(contentsOf: journal, encoding: .utf8))?
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
    }

    static func append(_ phase: String, to path: String) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data("\(phase)\n".utf8))
        try? handle.close()
    }

    private func definition(setup: [String]) -> TestDefinition {
        TestDefinition(
            name: "phase order",
            app: "com.example.app",
            setup: setup,
            steps: [TestStep(action: .pause(0))]
        )
    }

    private func makeExecutor(prepareApp: @escaping @Sendable () async throws -> Void) -> TestRunExecutor {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhaseMockProtocol.self]
        let client = SimToolClient(
            baseURL: URL(string: "http://127.0.0.1:3200")!,
            session: URLSession(configuration: configuration)
        )
        return TestRunExecutor(
            client: client,
            options: TestRunOptions(
                testFile: URL(fileURLWithPath: "/repo/.simtool/tests/phase-order.yml"),
                recordSession: true,
                evidence: .none,
                defaultApp: "com.example.app",
                prepareApp: prepareApp
            )
        )
    }
}

/// Answers the handful of endpoints a run touches, and notes in the journal when
/// the session — and with it the recorder — starts.
private final class PhaseMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var journalPath: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/tests/start"), let journal = Self.journalPath {
            TestRunPhaseOrderTests.append("session-start", to: journal)
        }
        let (data, status) = Self.payload(for: path)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func payload(for path: String) -> (Data, Int) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if path.hasSuffix("/config") {
            let payload = ServerConfigPayload(
                device: "iPhone",
                udid: "UDID",
                width: 390,
                height: 844,
                stream: StreamPaths(),
                metrics: StreamMetricsPayload()
            )
            return ((try? encoder.encode(payload)) ?? Data("{}".utf8), 200)
        }
        if path.hasSuffix("/tests/start") {
            let session = TestSession(
                id: "2026-07-30-1200-abcdef",
                title: "phase order",
                deviceUdid: "UDID",
                deviceName: "iPhone",
                startedAt: Date(),
                status: .running
            )
            return ((try? encoder.encode(session)) ?? Data("{}".utf8), 200)
        }
        return (Data("{}".utf8), 200)
    }
}
