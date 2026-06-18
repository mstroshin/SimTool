# Network Response Mocking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an agent live-configure mocked gRPC/Connect responses (success, error, delay, conditional) through the SimTool server, have the app short-circuit matching calls, and mark mocked requests in the Web Network tab.

**Architecture:** All app-agnostic machinery — rule model, matching engine, server registry, delivery poller, event flag, web badge — lives in the SimTool repo (`SimToolNetworkLogger` package + `Tool/`). Only the typed JSON→protobuf short-circuit lives in the consumer app's interceptor (described in the Appendix, implemented in the app repo, gated `#if !RELEASE`).

**Tech Stack:** Swift, SwiftPM, XCTest, ArgumentParser, Swifter (server), vanilla JS embedded in `WebViewer.swift`.

## Global Constraints

- App-agnostic discipline: no real consumer identifiers in code, fixtures, or docs. Use placeholder method paths like `/example.v1.FooService/GetBar`. (See memory: SimTool is app-agnostic.)
- The `SimToolNetworkLogger` package (repo root) is a separate SwiftPM package from `Tool/`. Build the package with default `swift build`; build the CLI with `swift build --package-path Tool`. Run package tests with `swift test`; run Tool tests with `swift test --package-path Tool`.
- Logging/mock delivery is best-effort and must never throw into or block the host app's networking.
- All new public model types are `Codable, Equatable, Sendable`.
- JSON encode/decode in the package goes through `NetworkLoggerJSON`; in `Tool` through `JSON`.

---

### Task 1: Mock domain models

**Files:**
- Create: `NetworkLogger/Sources/SimToolNetworkLogger/MockModels.swift`
- Test: `NetworkLogger/Tests/SimToolNetworkLoggerTests/MockModelsTests.swift`

**Interfaces:**
- Produces: `MockResponseKind`, `MockResponse`, `MockMatch`, `MockRule`, `MockRuleDraft`, `MockDecision`, `MockRuleListPayload`, `MockRuleCreateResponse`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SimToolNetworkLogger

final class MockModelsTests: XCTestCase {
    func testMockRuleRoundTripsThroughJSON() throws {
        let rule = MockRule(
            id: "r1",
            match: MockMatch(method: "/example.v1.FooService/GetBar", headerMatch: ["x-env": "test"], bodyMatch: .object(["id": .string("42")]), skip: 1, times: 2),
            response: MockResponse(kind: .success, bodyJSON: "{\"ok\":true}"),
            delayMs: 150
        )
        let data = try NetworkLoggerJSON.data(rule)
        let decoded = try NetworkLoggerJSON.decoder.decode(MockRule.self, from: data)
        XCTAssertEqual(decoded, rule)
    }

    func testErrorResponseRoundTrips() throws {
        let response = MockResponse(kind: .error, grpcStatus: "unavailable", message: "down", trailers: ["retry": "no"])
        let data = try NetworkLoggerJSON.data(response)
        XCTAssertEqual(try NetworkLoggerJSON.decoder.decode(MockResponse.self, from: data), response)
    }

    func testListPayloadCarriesGenerationAndUnchangedFlag() throws {
        let payload = MockRuleListPayload(generation: 7, rules: [], unchanged: true)
        let data = try NetworkLoggerJSON.data(payload)
        XCTAssertEqual(try NetworkLoggerJSON.decoder.decode(MockRuleListPayload.self, from: data), payload)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MockModelsTests`
Expected: FAIL — `cannot find 'MockRule' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public enum MockResponseKind: String, Codable, Equatable, Sendable {
    case success
    case error
}

public struct MockResponse: Codable, Equatable, Sendable {
    public var kind: MockResponseKind
    /// JSON encoding of the typed protobuf response, used when `kind == .success`.
    public var bodyJSON: String?
    /// gRPC status name when `kind == .error`, e.g. "unavailable", "deadlineExceeded".
    public var grpcStatus: String?
    public var message: String?
    public var trailers: [String: String]?

    public init(
        kind: MockResponseKind,
        bodyJSON: String? = nil,
        grpcStatus: String? = nil,
        message: String? = nil,
        trailers: [String: String]? = nil
    ) {
        self.kind = kind
        self.bodyJSON = bodyJSON
        self.grpcStatus = grpcStatus
        self.message = message
        self.trailers = trailers
    }
}

public struct MockMatch: Codable, Equatable, Sendable {
    /// gRPC full-method (e.g. "/example.v1.FooService/GetBar") or HTTP path. Supports `*` globbing.
    public var method: String
    /// Optional header/metadata equality constraints; every pair must match.
    public var headerMatch: [String: String]?
    /// Optional partial (subset) match against the request JSON.
    public var bodyMatch: NetworkLoggerJSONValue?
    /// Skip the first N matches before the rule starts firing.
    public var skip: Int
    /// Maximum number of times the rule fires after `skip`; `nil` means unlimited.
    public var times: Int?

    public init(
        method: String,
        headerMatch: [String: String]? = nil,
        bodyMatch: NetworkLoggerJSONValue? = nil,
        skip: Int = 0,
        times: Int? = nil
    ) {
        self.method = method
        self.headerMatch = headerMatch
        self.bodyMatch = bodyMatch
        self.skip = skip
        self.times = times
    }
}

public struct MockRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var match: MockMatch
    public var response: MockResponse
    public var delayMs: Int

    public init(id: String, match: MockMatch, response: MockResponse, delayMs: Int = 0) {
        self.id = id
        self.match = match
        self.response = response
        self.delayMs = delayMs
    }
}

/// A rule submitted by a client; the server assigns the `id`.
public struct MockRuleDraft: Codable, Equatable, Sendable {
    public var match: MockMatch
    public var response: MockResponse
    public var delayMs: Int

    public init(match: MockMatch, response: MockResponse, delayMs: Int = 0) {
        self.match = match
        self.response = response
        self.delayMs = delayMs
    }
}

/// The outcome of matching a request against the store, handed to the interceptor.
public struct MockDecision: Equatable, Sendable {
    public var ruleId: String
    public var kind: MockResponseKind
    public var bodyJSON: String?
    public var grpcStatus: String?
    public var message: String?
    public var trailers: [String: String]
    public var delayMs: Int

    public init(
        ruleId: String,
        kind: MockResponseKind,
        bodyJSON: String? = nil,
        grpcStatus: String? = nil,
        message: String? = nil,
        trailers: [String: String] = [:],
        delayMs: Int = 0
    ) {
        self.ruleId = ruleId
        self.kind = kind
        self.bodyJSON = bodyJSON
        self.grpcStatus = grpcStatus
        self.message = message
        self.trailers = trailers
        self.delayMs = delayMs
    }
}

public struct MockRuleListPayload: Codable, Equatable, Sendable {
    public var generation: Int
    public var rules: [MockRule]
    /// True when the caller's `since` already equals `generation`; `rules` is then empty.
    public var unchanged: Bool

    public init(generation: Int, rules: [MockRule], unchanged: Bool = false) {
        self.generation = generation
        self.rules = rules
        self.unchanged = unchanged
    }
}

public struct MockRuleCreateResponse: Codable, Equatable, Sendable {
    public var id: String
    public var generation: Int

    public init(id: String, generation: Int) {
        self.id = id
        self.generation = generation
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MockModelsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add NetworkLogger/Sources/SimToolNetworkLogger/MockModels.swift NetworkLogger/Tests/SimToolNetworkLoggerTests/MockModelsTests.swift
git commit -m "feat(mock): network mock domain models"
```

---

### Task 2: MockStore matching engine

**Files:**
- Create: `NetworkLogger/Sources/SimToolNetworkLogger/MockStore.swift`
- Test: `NetworkLogger/Tests/SimToolNetworkLoggerTests/MockStoreTests.swift`

**Interfaces:**
- Consumes: `MockRule`, `MockMatch`, `MockDecision`, `NetworkLoggerJSONValue` (Task 1).
- Produces: `MockStore` with `replace(rules:generation:)`, `currentGeneration -> Int`, and `decision(fullMethod:headers:requestJSON:) -> MockDecision?`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SimToolNetworkLogger

final class MockStoreTests: XCTestCase {
    private func rule(_ id: String, method: String, headerMatch: [String: String]? = nil, bodyMatch: NetworkLoggerJSONValue? = nil, skip: Int = 0, times: Int? = nil) -> MockRule {
        MockRule(id: id, match: MockMatch(method: method, headerMatch: headerMatch, bodyMatch: bodyMatch, skip: skip, times: times), response: MockResponse(kind: .success, bodyJSON: "{\"r\":\"\(id)\"}"))
    }

    func testExactMethodMatchReturnsDecision() {
        let store = MockStore()
        store.replace(rules: [rule("a", method: "/example.v1.FooService/GetBar")], generation: 1)
        let decision = store.decision(fullMethod: "/example.v1.FooService/GetBar", headers: [:], requestJSON: nil)
        XCTAssertEqual(decision?.ruleId, "a")
    }

    func testGlobMethodMatch() {
        let store = MockStore()
        store.replace(rules: [rule("a", method: "/example.v1.FooService/*")], generation: 1)
        XCTAssertEqual(store.decision(fullMethod: "/example.v1.FooService/GetBar", headers: [:], requestJSON: nil)?.ruleId, "a")
        XCTAssertNil(store.decision(fullMethod: "/example.v1.OtherService/GetBar", headers: [:], requestJSON: nil))
    }

    func testHeaderMatchRequiresAllPairs() {
        let store = MockStore()
        store.replace(rules: [rule("a", method: "/m", headerMatch: ["x-env": "test"])], generation: 1)
        XCTAssertNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil))
        XCTAssertEqual(store.decision(fullMethod: "/m", headers: ["x-env": "test", "other": "y"], requestJSON: nil)?.ruleId, "a")
    }

    func testBodySubsetMatch() {
        let store = MockStore()
        store.replace(rules: [rule("a", method: "/m", bodyMatch: .object(["id": .string("42")]))], generation: 1)
        let matching: NetworkLoggerJSONValue = .object(["id": .string("42"), "extra": .bool(true)])
        let nonMatching: NetworkLoggerJSONValue = .object(["id": .string("99")])
        XCTAssertEqual(store.decision(fullMethod: "/m", headers: [:], requestJSON: matching)?.ruleId, "a")
        XCTAssertNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nonMatching))
    }

    func testFirstActiveRuleWins() {
        let store = MockStore()
        store.replace(rules: [rule("a", method: "/m"), rule("b", method: "/m")], generation: 1)
        XCTAssertEqual(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil)?.ruleId, "a")
    }

    func testSkipThenTimesGovernsFiring() {
        let store = MockStore()
        // Skip first 2 matches, then fire once.
        store.replace(rules: [rule("a", method: "/m", skip: 2, times: 1)], generation: 1)
        XCTAssertNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil)) // 1st: skipped
        XCTAssertNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil)) // 2nd: skipped
        XCTAssertEqual(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil)?.ruleId, "a") // 3rd: fires
        XCTAssertNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil)) // 4th: exhausted
    }

    func testReplaceResetsCounters() {
        let store = MockStore()
        store.replace(rules: [rule("a", method: "/m", times: 1)], generation: 1)
        XCTAssertNotNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil))
        XCTAssertNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil))
        store.replace(rules: [rule("a", method: "/m", times: 1)], generation: 2)
        XCTAssertNotNil(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MockStoreTests`
Expected: FAIL — `cannot find 'MockStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// App-side, thread-safe matching engine. Holds the rule set fetched from the SimTool server and
/// answers per-call mock decisions, tracking per-rule hit counts for `skip`/`times` semantics.
public final class MockStore: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [MockRule] = []
    private var generation: Int = -1
    /// Number of times each rule's match conditions have been satisfied so far.
    private var matchCounts: [String: Int] = [:]

    public init() {}

    public var currentGeneration: Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    /// Replaces the rule set and resets all per-rule counters.
    public func replace(rules: [MockRule], generation: Int) {
        lock.lock(); defer { lock.unlock() }
        self.rules = rules
        self.generation = generation
        self.matchCounts = [:]
    }

    public func decision(
        fullMethod: String,
        headers: [String: String],
        requestJSON: NetworkLoggerJSONValue?
    ) -> MockDecision? {
        lock.lock(); defer { lock.unlock() }
        for rule in rules {
            guard Self.methodMatches(pattern: rule.match.method, value: fullMethod) else { continue }
            guard Self.headersMatch(rule.match.headerMatch, in: headers) else { continue }
            guard Self.bodyMatches(rule.match.bodyMatch, in: requestJSON) else { continue }

            let count = (matchCounts[rule.id] ?? 0) + 1
            matchCounts[rule.id] = count
            let afterSkip = count > rule.match.skip
            let withinTimes = rule.match.times.map { count <= rule.match.skip + $0 } ?? true
            guard afterSkip, withinTimes else { continue }

            return MockDecision(
                ruleId: rule.id,
                kind: rule.response.kind,
                bodyJSON: rule.response.bodyJSON,
                grpcStatus: rule.response.grpcStatus,
                message: rule.response.message,
                trailers: rule.response.trailers ?? [:],
                delayMs: rule.delayMs
            )
        }
        return nil
    }

    /// `*` matches any run of characters; everything else is literal.
    static func methodMatches(pattern: String, value: String) -> Bool {
        guard pattern.contains("*") else { return pattern == value }
        let segments = pattern.components(separatedBy: "*")
        var index = value.startIndex
        for (offset, segment) in segments.enumerated() where !segment.isEmpty {
            guard let range = value.range(of: segment, range: index..<value.endIndex) else { return false }
            if offset == 0, pattern.first != "*", range.lowerBound != value.startIndex { return false }
            index = range.upperBound
        }
        if let last = segments.last, !last.isEmpty, pattern.last != "*" {
            return value.hasSuffix(last)
        }
        return true
    }

    static func headersMatch(_ required: [String: String]?, in headers: [String: String]) -> Bool {
        guard let required else { return true }
        for (key, value) in required where headers[key] != value { return false }
        return true
    }

    /// True when every key in `subset` is present in `value` with an equal (recursively, for objects) value.
    static func bodyMatches(_ subset: NetworkLoggerJSONValue?, in value: NetworkLoggerJSONValue?) -> Bool {
        guard let subset else { return true }
        guard let value else { return false }
        return jsonContains(subset: subset, in: value)
    }

    private static func jsonContains(subset: NetworkLoggerJSONValue, in value: NetworkLoggerJSONValue) -> Bool {
        switch (subset, value) {
        case let (.object(subFields), .object(valueFields)):
            for (key, subField) in subFields {
                guard let valueField = valueFields[key], jsonContains(subset: subField, in: valueField) else { return false }
            }
            return true
        default:
            return subset == value
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MockStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add NetworkLogger/Sources/SimToolNetworkLogger/MockStore.swift NetworkLogger/Tests/SimToolNetworkLoggerTests/MockStoreTests.swift
git commit -m "feat(mock): MockStore matching engine"
```

---

### Task 3: MockRuleRegistry (server-side store with generation)

**Files:**
- Create: `NetworkLogger/Sources/SimToolNetworkLogger/MockRuleRegistry.swift`
- Test: `NetworkLogger/Tests/SimToolNetworkLoggerTests/MockRuleRegistryTests.swift`

**Interfaces:**
- Consumes: `MockRule`, `MockRuleDraft`, `MockRuleListPayload`, `MockRuleCreateResponse` (Task 1).
- Produces: `MockRuleRegistry` with `add(_:) -> MockRuleCreateResponse`, `list(since:) -> MockRuleListPayload`, `remove(id:) -> Bool`, `clear() -> Int`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SimToolNetworkLogger

final class MockRuleRegistryTests: XCTestCase {
    private let draft = MockRuleDraft(match: MockMatch(method: "/m"), response: MockResponse(kind: .success, bodyJSON: "{}"))

    func testAddAssignsIdAndBumpsGeneration() {
        let registry = MockRuleRegistry()
        let first = registry.add(draft)
        let second = registry.add(draft)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.generation, first.generation + 1)
        XCTAssertEqual(registry.list(since: nil).rules.count, 2)
    }

    func testListSinceReturnsUnchangedWhenGenerationMatches() {
        let registry = MockRuleRegistry()
        let created = registry.add(draft)
        let payload = registry.list(since: created.generation)
        XCTAssertTrue(payload.unchanged)
        XCTAssertEqual(payload.rules.count, 0)
        XCTAssertEqual(payload.generation, created.generation)
    }

    func testRemoveBumpsGenerationAndDropsRule() {
        let registry = MockRuleRegistry()
        let created = registry.add(draft)
        XCTAssertTrue(registry.remove(id: created.id))
        XCTAssertFalse(registry.remove(id: created.id))
        let payload = registry.list(since: nil)
        XCTAssertEqual(payload.rules.count, 0)
        XCTAssertEqual(payload.generation, created.generation + 1)
    }

    func testClearRemovesAllAndBumpsGeneration() {
        let registry = MockRuleRegistry()
        _ = registry.add(draft)
        _ = registry.add(draft)
        let removed = registry.clear()
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(registry.list(since: nil).rules.count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MockRuleRegistryTests`
Expected: FAIL — `cannot find 'MockRuleRegistry' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Server-side, thread-safe registry of mock rule definitions. Stores only definitions; matching and
/// counting happen app-side in `MockStore`. Every mutation increments `generation` so apps can poll
/// cheaply with `?since=`.
public final class MockRuleRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [MockRule] = []
    private var generation: Int = 0
    private var nextID: Int = 1

    public init() {}

    @discardableResult
    public func add(_ draft: MockRuleDraft) -> MockRuleCreateResponse {
        lock.lock(); defer { lock.unlock() }
        let id = "mock-\(nextID)"
        nextID += 1
        rules.append(MockRule(id: id, match: draft.match, response: draft.response, delayMs: draft.delayMs))
        generation += 1
        return MockRuleCreateResponse(id: id, generation: generation)
    }

    public func list(since: Int?) -> MockRuleListPayload {
        lock.lock(); defer { lock.unlock() }
        if let since, since == generation {
            return MockRuleListPayload(generation: generation, rules: [], unchanged: true)
        }
        return MockRuleListPayload(generation: generation, rules: rules, unchanged: false)
    }

    @discardableResult
    public func remove(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let before = rules.count
        rules.removeAll { $0.id == id }
        guard rules.count != before else { return false }
        generation += 1
        return true
    }

    @discardableResult
    public func clear() -> Int {
        lock.lock(); defer { lock.unlock() }
        let removed = rules.count
        rules.removeAll()
        if removed > 0 { generation += 1 }
        return removed
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MockRuleRegistryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add NetworkLogger/Sources/SimToolNetworkLogger/MockRuleRegistry.swift NetworkLogger/Tests/SimToolNetworkLoggerTests/MockRuleRegistryTests.swift
git commit -m "feat(mock): server-side mock rule registry"
```

---

### Task 4: Server mock routes

**Files:**
- Modify: `Tool/Sources/SimToolServer/StreamServer.swift` (add registry property near `networkLoggerEvents` at line 48; add routes after the network events routes around line 218; add handler near `handleNetworkLoggerIngestion` at line 440)
- Test: `Tool/Tests/SimToolServerTests/MockRouteTests.swift`

**Interfaces:**
- Consumes: `MockRuleRegistry`, `MockRuleDraft`, `MockRuleListPayload`, `MockRuleCreateResponse` (Tasks 1, 3).
- Produces: HTTP routes `POST /api/v1/mocks`, `GET /api/v1/mocks?since=`, `DELETE /api/v1/mocks/:id`, `DELETE /api/v1/mocks`.

- [ ] **Step 1: Write the failing test**

```swift
import Darwin
import Foundation
import XCTest
import SimToolCore
import SimToolNetworkLogger
import SimToolServer

final class MockRouteTests: XCTestCase {
    func testCreateListRemoveLifecycle() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }

        let draft = MockRuleDraft(match: MockMatch(method: "/example.v1.FooService/GetBar"), response: MockResponse(kind: .success, bodyJSON: "{\"ok\":true}"))
        let created = try await postJSON(MockRuleCreateResponse.self, url: baseURL.appendingPathComponent("api/v1/mocks"), body: try JSON.encoder.encode(draft))
        XCTAssertEqual(created.id, "mock-1")

        let list = try await getJSON(MockRuleListPayload.self, url: baseURL.appendingPathComponent("api/v1/mocks"), query: "")
        XCTAssertEqual(list.rules.count, 1)

        let unchanged = try await getJSON(MockRuleListPayload.self, url: baseURL.appendingPathComponent("api/v1/mocks"), query: "since=\(created.generation)")
        XCTAssertTrue(unchanged.unchanged)

        try await delete(url: baseURL.appendingPathComponent("api/v1/mocks/\(created.id)"))
        let afterDelete = try await getJSON(MockRuleListPayload.self, url: baseURL.appendingPathComponent("api/v1/mocks"), query: "")
        XCTAssertEqual(afterDelete.rules.count, 0)
    }

    // --- helpers (mirror LogCaptureRouteTests) ---
    private func startServer() throws -> (StreamServer, URL) {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        return (server, URL(string: "http://127.0.0.1:\(port)")!)
    }
    private func getJSON<T: Decodable>(_ type: T.Type, url: URL, query: String) async throws -> T {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.query = query
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSON.decoder.decode(T.self, from: data)
    }
    private func postJSON<T: Decodable>(_ type: T.Type, url: URL, body: Data) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSON.decoder.decode(T.self, from: data)
    }
    private func delete(url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: request)
    }
    private func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Tool --filter MockRouteTests`
Expected: FAIL — 404 / decode error because routes do not exist yet.

- [ ] **Step 3: Add the registry property**

In `Tool/Sources/SimToolServer/StreamServer.swift`, next to line 48 (`private let networkLoggerEvents = NetworkLoggerEventStore(capacity: 1_000)`), add:

```swift
    private let mockRules = MockRuleRegistry()
```

- [ ] **Step 4: Add the routes**

After the network events routes (around line 227, before the `DELETE .../network/launches/:launchId` route), insert:

```swift
        server.POST["/api/v1/mocks"] = { request in
            do {
                let draft = try self.decodeJSON(MockRuleDraft.self, from: request)
                return try self.jsonEncodedResponse(self.mockRules.add(draft))
            } catch {
                return self.errorResponse(error, statusCode: 400, reason: "Bad Request")
            }
        }

        server.GET["/api/v1/mocks"] = { request in
            do {
                return try self.jsonEncodedResponse(self.mockRules.list(since: request.queryInt("since")))
            } catch {
                return self.errorResponse(error)
            }
        }

        server.DELETE["/api/v1/mocks/:id"] = { request in
            guard let id = request.params[":id"], !id.isEmpty else {
                return self.errorResponse(SimToolError("Missing mock id"), statusCode: 400, reason: "Bad Request")
            }
            let removed = self.mockRules.remove(id: id)
            return self.jsonResponse(["ok": true, "removed": removed ? 1 : 0])
        }

        server.DELETE["/api/v1/mocks"] = { _ in
            let removed = self.mockRules.clear()
            return self.jsonResponse(["ok": true, "removed": removed])
        }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path Tool --filter MockRouteTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Tool/Sources/SimToolServer/StreamServer.swift Tool/Tests/SimToolServerTests/MockRouteTests.swift
git commit -m "feat(mock): server routes for mock rules"
```

---

### Task 5: SimToolClient mock methods

**Files:**
- Modify: `Tool/Sources/SimToolClient/SimToolClient.swift` (add methods after `ingestNetworkLoggerEvents` around line 154; use existing `getJSON`, `sendJSON`, `makeRequest`, `apiBaseURL` helpers)
- Test: `Tool/Tests/SimToolServerTests/MockRouteTests.swift` (add a round-trip test using `SimToolClient` against the live server)

**Interfaces:**
- Consumes: server routes (Task 4); `MockRuleDraft`, `MockRuleListPayload`, `MockRuleCreateResponse` (Task 1).
- Produces: `SimToolClient.setMock(_:)`, `.mocks(since:)`, `.removeMock(id:)`, `.clearMocks()`.

- [ ] **Step 1: Write the failing test**

Add to `MockRouteTests`:

```swift
    func testClientRoundTrip() async throws {
        let (server, baseURL) = try startServer()
        defer { server.stop() }
        let client = SimToolClient(baseURL: baseURL)
        let created = try await client.setMock(MockRuleDraft(match: MockMatch(method: "/m"), response: MockResponse(kind: .error, grpcStatus: "unavailable")))
        XCTAssertEqual(created.id, "mock-1")
        XCTAssertEqual(try await client.mocks(since: nil).rules.count, 1)
        XCTAssertTrue(try await client.removeMock(id: created.id))
        XCTAssertEqual(try await client.mocks(since: nil).rules.count, 0)
    }
```

Add `import SimToolClient` to the test file's imports.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Tool --filter MockRouteTests/testClientRoundTrip`
Expected: FAIL — `value of type 'SimToolClient' has no member 'setMock'`.

- [ ] **Step 3: Write minimal implementation**

In `SimToolClient.swift`, after `ingestNetworkLoggerEvents` (line 154), referencing the existing private helpers, add:

```swift
    public func setMock(_ draft: MockRuleDraft) async throws -> MockRuleCreateResponse {
        try await sendJSON(MockRuleCreateResponse.self, path: "mocks", method: "POST", body: draft)
    }

    public func mocks(since: Int? = nil) async throws -> MockRuleListPayload {
        var path = "mocks"
        if let since { path += "?since=\(since)" }
        return try await getJSON(MockRuleListPayload.self, path: path)
    }

    @discardableResult
    public func removeMock(id: String) async throws -> Bool {
        let url = apiBaseURL.appendingPathComponent("mocks/\(id)")
        let request = makeRequest(url: url, method: "DELETE")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return true
    }

    @discardableResult
    public func clearMocks() async throws -> Bool {
        let url = apiBaseURL.appendingPathComponent("mocks")
        let request = makeRequest(url: url, method: "DELETE")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return true
    }
```

Note: confirm the exact spelling of the private base-URL property (`apiBaseURL`) and the `sendJSON`/`getJSON` signatures shown at `SimToolClient.swift:178-216` before writing; match them exactly. If `sendJSON` takes a `path:` that must not contain a query, build the `?since=` URL via `apiBaseURL` like `removeMock` does instead.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Tool --filter MockRouteTests/testClientRoundTrip`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Tool/Sources/SimToolClient/SimToolClient.swift Tool/Tests/SimToolServerTests/MockRouteTests.swift
git commit -m "feat(mock): SimToolClient mock rule methods"
```

---

### Task 6: MockRulePoller (delivery refresh)

**Files:**
- Create: `NetworkLogger/Sources/SimToolNetworkLogger/MockRulePoller.swift`
- Test: `Tool/Tests/SimToolServerTests/MockPollerTests.swift`

**Interfaces:**
- Consumes: `MockStore` (Task 2), `MockRuleListPayload` (Task 1), live server routes (Task 4).
- Produces: `MockRulePoller(serverURL:store:session:)` with `refresh() async` (one fetch + apply) and `start(intervalSeconds:)` / `stop()` (best-effort loop).

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import XCTest
import SimToolCore
import SimToolNetworkLogger
import SimToolServer
import Darwin

final class MockPollerTests: XCTestCase {
    func testRefreshPullsRulesIntoStore() async throws {
        let port = try availablePort()
        let device = SimulatorDevice(udid: "TEST-UDID", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let server = StreamServer(config: StreamServerConfig(host: "127.0.0.1", port: port, device: device, captureEnabled: false))
        try server.start()
        defer { server.stop() }
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!

        // Seed a rule via the client.
        let client = SimToolClient(baseURL: baseURL)
        _ = try await client.setMock(MockRuleDraft(match: MockMatch(method: "/m"), response: MockResponse(kind: .success, bodyJSON: "{}")))

        let store = MockStore()
        let poller = MockRulePoller(serverURL: baseURL, store: store)
        await poller.refresh()

        XCTAssertEqual(store.decision(fullMethod: "/m", headers: [:], requestJSON: nil)?.ruleId, "mock-1")
    }

    private func availablePort() throws -> UInt16 { /* same helper as MockRouteTests */ 0 }
}
```

Copy the real `availablePort()` body from `MockRouteTests` (Task 4) and add `import SimToolClient`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Tool --filter MockPollerTests`
Expected: FAIL — `cannot find 'MockRulePoller' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Tool --filter MockPollerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add NetworkLogger/Sources/SimToolNetworkLogger/MockRulePoller.swift Tool/Tests/SimToolServerTests/MockPollerTests.swift
git commit -m "feat(mock): mock rule delivery poller"
```

---

### Task 7: `simtool mock` CLI subcommands

**Files:**
- Modify: `Tool/Sources/SimToolCLI/SimTool.swift` (register `Mock.self` in the root `subcommands:` array at line 21; add the `Mock` command struct near `Network` at line 343)
- Test: `Tool/Tests/SimToolCLITests/MockCommandTests.swift`

**Interfaces:**
- Consumes: `SimToolClient` mock methods (Task 5); `MockRuleDraft`, `MockMatch`, `MockResponse` (Task 1).
- Produces: `simtool mock set|list|remove|clear`.

- [ ] **Step 1: Write the failing test (argument parsing + draft building)**

```swift
import Foundation
import XCTest
@testable import SimToolCLI
import SimToolNetworkLogger

final class MockCommandTests: XCTestCase {
    func testSetBuildsSuccessDraft() throws {
        let set = try Mock.Set.parse(["--method", "/example.v1.FooService/GetBar", "--body", "{\"ok\":true}", "--delay", "100", "--match-header", "x-env=test"])
        let draft = try set.makeDraft()
        XCTAssertEqual(draft.match.method, "/example.v1.FooService/GetBar")
        XCTAssertEqual(draft.match.headerMatch, ["x-env": "test"])
        XCTAssertEqual(draft.delayMs, 100)
        XCTAssertEqual(draft.response.kind, .success)
        XCTAssertEqual(draft.response.bodyJSON, "{\"ok\":true}")
    }

    func testSetBuildsErrorDraft() throws {
        let set = try Mock.Set.parse(["--method", "/m", "--error", "unavailable", "--message", "down"])
        let draft = try set.makeDraft()
        XCTAssertEqual(draft.response.kind, .error)
        XCTAssertEqual(draft.response.grpcStatus, "unavailable")
        XCTAssertEqual(draft.response.message, "down")
    }

    func testSetRejectsMissingBodyAndError() {
        let set = try? Mock.Set.parse(["--method", "/m"])
        XCTAssertThrowsError(try set?.makeDraft())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Tool --filter MockCommandTests`
Expected: FAIL — `cannot find 'Mock' in scope`.

- [ ] **Step 3: Register the subcommand**

In the root `SimTool` command's `subcommands:` array (line 21), add `Mock.self`.

- [ ] **Step 4: Write minimal implementation**

Add near the `Network` command (line 343). Reuse the `serverBaseURL()` resolution pattern from `Network.Events` (lines 441-453) by copying it into a shared helper or per-command; here each subcommand resolves `--server/--host/--port`:

```swift
struct Mock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mock",
        abstract: "Configure mocked backend responses served to the app.",
        subcommands: [Set.self, List.self, Remove.self, Clear.self]
    )

    struct ServerOptions: ParsableArguments {
        @Option(help: "SimTool server URL, for example http://127.0.0.1:3200.") var server: String?
        @Option(help: "SimTool server host.") var host: String?
        @Option(help: "SimTool server port.") var port: UInt16?

        func baseURL() throws -> URL {
            if let server, !server.isEmpty {
                guard let url = URL(string: server) else { throw SimToolError("Invalid server URL: \(server)") }
                return url
            }
            let host = host ?? "127.0.0.1"
            let port = port ?? 3200
            guard let url = URL(string: "http://\(host):\(port)") else {
                throw SimToolError("Invalid server host or port: \(host):\(port)")
            }
            return url
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Add a mock rule.")

        @Option(help: "gRPC full-method or HTTP path to match. Supports * globbing.") var method: String
        @Option(name: .customLong("match-header"), help: "Header/metadata equality constraint key=value (repeatable).") var matchHeader: [String] = []
        @Option(name: .customLong("match-body"), help: "JSON subset the request must contain.") var matchBody: String?
        @Option(help: "Success response body as JSON (mutually exclusive with --error).") var body: String?
        @Option(help: "gRPC error status name, e.g. unavailable (mutually exclusive with --body).") var error: String?
        @Option(help: "Error status message.") var message: String?
        @Option(help: "Artificial delay before responding, milliseconds.") var delay: Int = 0
        @Option(help: "Skip the first N matches before firing.") var skip: Int = 0
        @Option(help: "Fire at most M times after skip.") var times: Int?
        @OptionGroup var server: ServerOptions
        @OptionGroup var common: CommonJSON

        func makeDraft() throws -> MockRuleDraft {
            var headerMatch: [String: String] = [:]
            for pair in matchHeader {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { throw SimToolError("Invalid --match-header '\(pair)'; expected key=value.") }
                headerMatch[parts[0]] = parts[1]
            }
            let bodyMatch = try matchBody.map { try NetworkLoggerJSON.decoder.decode(NetworkLoggerJSONValue.self, from: Data($0.utf8)) }
            let response: MockResponse
            switch (body, error) {
            case let (body?, nil):
                response = MockResponse(kind: .success, bodyJSON: body)
            case let (nil, error?):
                response = MockResponse(kind: .error, grpcStatus: error, message: message)
            default:
                throw SimToolError("Provide exactly one of --body or --error.")
            }
            return MockRuleDraft(
                match: MockMatch(method: method, headerMatch: headerMatch.isEmpty ? nil : headerMatch, bodyMatch: bodyMatch, skip: skip, times: times),
                response: response,
                delayMs: delay
            )
        }

        func run() async throws {
            let client = SimToolClient(baseURL: try server.baseURL())
            let created = try await client.setMock(try makeDraft())
            if common.json { try printJSON(created) } else { makeNoora().info("Added mock \(created.id) (generation \(created.generation)).") }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List active mock rules.")
        @OptionGroup var server: ServerOptions
        @OptionGroup var common: CommonJSON
        func run() async throws {
            let client = SimToolClient(baseURL: try server.baseURL())
            let payload = try await client.mocks(since: nil)
            if common.json { try printJSON(payload) }
            else if payload.rules.isEmpty { makeNoora().info("No mock rules configured.") }
            else {
                makeNoora().table(
                    headers: ["ID", "Method", "Kind", "Status/Body", "Delay"],
                    rows: payload.rules.map { rule in
                        [rule.id, rule.match.method, rule.response.kind.rawValue,
                         rule.response.kind == .error ? (rule.response.grpcStatus ?? "") : (rule.response.bodyJSON ?? ""),
                         "\(rule.delayMs)ms"]
                    }
                )
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a mock rule by id.")
        @Argument(help: "Mock rule id, e.g. mock-1.") var id: String
        @OptionGroup var server: ServerOptions
        func run() async throws {
            _ = try await SimToolClient(baseURL: try server.baseURL()).removeMock(id: id)
            makeNoora().info("Removed mock \(id).")
        }
    }

    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "clear", abstract: "Remove all mock rules.")
        @OptionGroup var server: ServerOptions
        func run() async throws {
            _ = try await SimToolClient(baseURL: try server.baseURL()).clearMocks()
            makeNoora().info("Cleared all mock rules.")
        }
    }
}
```

Note: `CommonJSON`, `printJSON`, `makeNoora()`, and `SimToolError` already exist in `SimToolCLI` (used by `Network.Events`). Confirm `CommonJSON`'s property is `json` as used at line 411 before relying on it. The `--from-event` ergonomic from the spec is deferred (see "Deferred" below) to keep this task focused.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path Tool --filter MockCommandTests`
Expected: PASS.

- [ ] **Step 6: Verify the CLI builds and the command is wired**

Run: `swift build --package-path Tool && swift run --package-path Tool simtool mock --help`
Expected: help text lists `set`, `list`, `remove`, `clear`.

- [ ] **Step 7: Commit**

```bash
git add Tool/Sources/SimToolCLI/SimTool.swift Tool/Tests/SimToolCLITests/MockCommandTests.swift
git commit -m "feat(mock): simtool mock CLI subcommands"
```

---

### Task 8: `mocked` flag on events + logger plumbing

**Files:**
- Modify: `NetworkLogger/Sources/SimToolNetworkLogger/NetworkLoggerModels.swift` (add fields + CodingKeys + tolerant decode to `NetworkLoggerEvent`, lines 141-201)
- Modify: `NetworkLogger/Sources/SimToolNetworkLogger/SimToolNetworkLogger.swift` (add `mocked`/`mockRuleId` params to `recordGRPC` at line 167 and `recordHTTP`/`makeHTTPEvent` at lines 82/104)
- Test: `NetworkLogger/Tests/SimToolNetworkLoggerTests/MockedEventTests.swift`

**Interfaces:**
- Consumes: existing `NetworkLoggerEvent`, `recordGRPC`, `recordHTTP`.
- Produces: `NetworkLoggerEvent.mocked: Bool`, `NetworkLoggerEvent.mockRuleId: String?`; `recordGRPC(..., mocked:mockRuleId:)`, `recordHTTP(..., mocked:mockRuleId:)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SimToolNetworkLogger

final class MockedEventTests: XCTestCase {
    func testDefaultsToNotMocked() {
        let event = NetworkLoggerEvent(networkProtocol: .grpc, durationMilliseconds: 1, request: NetworkLoggerRequest())
        XCTAssertFalse(event.mocked)
        XCTAssertNil(event.mockRuleId)
    }

    func testDecodingLegacyJSONWithoutMockedFieldDefaultsFalse() throws {
        let legacy = """
        {"id":"x","timestamp":"t","protocol":"grpc","durationMilliseconds":1,"request":{"headers":{},"metadata":{}},"rawMetadata":{}}
        """
        let event = try NetworkLoggerJSON.decoder.decode(NetworkLoggerEvent.self, from: Data(legacy.utf8))
        XCTAssertFalse(event.mocked)
    }

    func testRecordGRPCStampsMockedFlag() async {
        let logger = SimToolNetworkLogger(configuration: NetworkLoggerConfiguration(fileSinkEnabled: false), sinks: [])
        let event = await logger.recordGRPC(fullMethod: "/m", durationMilliseconds: 1, mocked: true, mockRuleId: "mock-1")
        XCTAssertTrue(event.mocked)
        XCTAssertEqual(event.mockRuleId, "mock-1")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MockedEventTests`
Expected: FAIL — `value of type 'NetworkLoggerEvent' has no member 'mocked'`.

- [ ] **Step 3: Add fields, init params, CodingKeys, and tolerant decode**

In `NetworkLoggerModels.swift`, in `NetworkLoggerEvent`:

Add stored properties after `launchId` (line 157):

```swift
    /// True when this event's response was produced by a SimTool mock rule rather than the backend.
    public var mocked: Bool
    /// Identifier of the mock rule that produced the response, when `mocked` is true.
    public var mockRuleId: String?
```

Add to the `init` (after `launchId: Int? = nil`, line 171) — parameters and assignments:

```swift
        mocked: Bool = false,
        mockRuleId: String? = nil
```
```swift
        self.mocked = mocked
        self.mockRuleId = mockRuleId
```

Add to `CodingKeys` (after `case launchId`, line 199):

```swift
        case mocked
        case mockRuleId
```

Add a custom decoder so legacy events (no `mocked` key) keep decoding. Append this initializer inside `NetworkLoggerEvent` (synthesized `encode(to:)` remains and will include the new keys):

```swift
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        appBundleID = try container.decodeIfPresent(String.self, forKey: .appBundleID)
        appDisplayName = try container.decodeIfPresent(String.self, forKey: .appDisplayName)
        networkProtocol = try container.decode(NetworkLoggerProtocol.self, forKey: .networkProtocol)
        durationMilliseconds = try container.decode(Double.self, forKey: .durationMilliseconds)
        request = try container.decode(NetworkLoggerRequest.self, forKey: .request)
        response = try container.decodeIfPresent(NetworkLoggerResponse.self, forKey: .response)
        error = try container.decodeIfPresent(NetworkLoggerError.self, forKey: .error)
        rawMetadata = try container.decodeIfPresent([String: NetworkLoggerJSONValue].self, forKey: .rawMetadata) ?? [:]
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        launchId = try container.decodeIfPresent(Int.self, forKey: .launchId)
        mocked = try container.decodeIfPresent(Bool.self, forKey: .mocked) ?? false
        mockRuleId = try container.decodeIfPresent(String.self, forKey: .mockRuleId)
    }
```

- [ ] **Step 4: Thread the flag through the logger**

In `SimToolNetworkLogger.swift`, `recordGRPC` (line 167): add parameters `mocked: Bool = false, mockRuleId: String? = nil` (place after `rawMetadata`), and pass them into the `NetworkLoggerEvent(...)` constructor (line 200) as `mocked: mocked, mockRuleId: mockRuleId`.

In `recordHTTP` (line 82) and `makeHTTPEvent` (line 104): add the same two parameters and pass them into the `NetworkLoggerEvent(...)` constructor at line 131.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter MockedEventTests`
Expected: PASS.

- [ ] **Step 6: Run the full package suite to confirm no Codable regressions**

Run: `swift test`
Expected: PASS (existing `NetworkLoggerEvent` round-trip tests still green).

- [ ] **Step 7: Commit**

```bash
git add NetworkLogger/Sources/SimToolNetworkLogger/NetworkLoggerModels.swift NetworkLogger/Sources/SimToolNetworkLogger/SimToolNetworkLogger.swift NetworkLogger/Tests/SimToolNetworkLoggerTests/MockedEventTests.swift
git commit -m "feat(mock): mark mocked responses on network events"
```

---

### Task 9: Web Network tab mocked badge

**Files:**
- Modify: `Tool/Sources/SimToolWeb/WebViewer.swift` (CSS near line 279-285; `renderNetworkList` row construction near line 1029-1044; request detail rendering)
- Test: `Tool/Tests/SimToolWebTests/` (add `WebViewerMockBadgeTests.swift`)

**Interfaces:**
- Consumes: `event.mocked`, `event.mockRuleId` JSON fields (Task 8).
- Produces: a `mocked` row class, a 🎭 badge, and CSS in the generated HTML.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SimToolWeb

final class WebViewerMockBadgeTests: XCTestCase {
    func testHTMLContainsMockedStylingAndBadgeLogic() {
        let html = WebViewer.html()
        XCTAssertTrue(html.contains(".network-row.mocked"), "missing mocked row CSS")
        XCTAssertTrue(html.contains("event.mocked"), "missing mocked badge logic")
        XCTAssertTrue(html.contains("🎭"), "missing mocked badge glyph")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Tool --filter WebViewerMockBadgeTests`
Expected: FAIL — assertions not satisfied.

- [ ] **Step 3: Add CSS**

After line 285 (`.network-row .dur { ... }`) add:

```swift
    .network-row.mocked { border-left: 3px solid #a78bfa; }
    .network-row .mock-badge { color: #a78bfa; margin-left: 4px; }
```

- [ ] **Step 4: Add the badge to the row**

In `renderNetworkList()` (around line 1030-1044), set the row class to include `mocked` and append a badge span to the request element. Adjust the existing class assignment and request cell:

```javascript
      row.className = "network-row"
        + (event.id === networkSelectedId ? " selected" : "")
        + (event.mocked ? " mocked" : "");
```

After the request element (`req`) is built and before `row.append(...)`, add:

```javascript
      if (event.mocked) {
        const badge = document.createElement("span");
        badge.className = "mock-badge";
        badge.textContent = "🎭";
        badge.title = event.mockRuleId ? ("Mocked by " + event.mockRuleId) : "Mocked response";
        req.appendChild(badge);
      }
```

- [ ] **Step 5: Add a detail line (where request detail is rendered)**

In the network detail renderer, add a line shown when mocked. Locate the detail builder (search for where `networkSelectedId`'s event detail fields like status/headers are rendered) and add:

```javascript
      if (event.mocked) {
        detail += '<div class="detail-row"><span class="k">Mocked</span><span class="v">' + (event.mockRuleId || "yes") + '</span></div>';
      }
```

Match the surrounding detail-row markup/helper actually used in that function; the snippet above mirrors a `k`/`v` row — adjust to the real structure found there.

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --package-path Tool --filter WebViewerMockBadgeTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Tool/Sources/SimToolWeb/WebViewer.swift Tool/Tests/SimToolWebTests/WebViewerMockBadgeTests.swift
git commit -m "feat(mock): mark mocked requests in web Network tab"
```

---

### Task 10: Full build + suite gate

**Files:** none (verification only)

- [ ] **Step 1: Build both packages**

Run: `swift build && swift build --package-path Tool`
Expected: both succeed.

- [ ] **Step 2: Run both test suites**

Run: `swift test && swift test --package-path Tool`
Expected: all green.

- [ ] **Step 3: Smoke-test the live path manually**

Run (in one shell): `swift run --package-path Tool simtool serve --port 3200` (or the project's normal serve invocation).
Run (in another): 
```bash
swift run --package-path Tool simtool mock set --method "/example.v1.FooService/GetBar" --error unavailable --message "down" --server http://127.0.0.1:3200
swift run --package-path Tool simtool mock list --server http://127.0.0.1:3200
```
Expected: `set` prints `Added mock mock-1`; `list` shows the rule.

- [ ] **Step 4: Commit any doc updates if introduced (otherwise skip).**

---

## Appendix: App-side interceptor integration (consumer app repo — not SimTool CI)

This is implemented in the consumer app repository (the gRPC/Connect app), not in SimTool, because it needs the app's typed `Request`/`Response` and the gRPC/Connect interceptor APIs. It is gated `#if !RELEASE`. It is **not** covered by SimTool's test suites; the app repo owns its tests.

**Wiring (once, where the logger is resolved):**
- Where the app builds `SimToolNetworkLogger.resolved()`, also create a shared `MockStore` and a `MockRulePoller(serverURL:store:)`, and call `poller.start()` — only when the logger is active and a `mocksEnabled` gate is on (e.g. an env var / launch arg the app already parses).

**In the gRPC interceptor (`SimToolNetworkInterceptor`, `ClientInterceptor<Request, Response>`):**
- On send, derive the full method, request headers (metadata), and a request-JSON via `try? requestMessage.jsonUTF8Data()` decoded into `NetworkLoggerJSONValue`.
- Call `store.decision(fullMethod:headers:requestJSON:)`.
- If a decision exists:
  - `await Task.sleep` for `delayMs`.
  - `.success`: `let response = try Response(jsonUTF8Data: Data(decision.bodyJSON!.utf8))` and emit `.metadata([:]) → .message(response, metadata) → .end(.ok, trailers)` **upstream**, without forwarding to the transport. On decode failure: do **not** apply the mock — forward the real call and record the event with a `mockError` note (so the agent sees the malformed mock); never crash.
  - `.error`: emit `.end(GRPCStatus(code: <mapped from decision.grpcStatus>, message: decision.message), trailers)` upstream.
  - In both applied cases, call `logger.recordGRPC(..., mocked: true, mockRuleId: decision.ruleId)`.
- If no decision: behave exactly as today (observe + forward).

**Connect variant:** mirror the above using the Connect interceptor API and `ProtocolClient` short-circuit; same `MockStore`, same `recordGRPC(..., mocked:)` call.

**Status → code mapping:** map `decision.grpcStatus` names (`ok`, `cancelled`, `unknown`, `invalidArgument`, `deadlineExceeded`, `notFound`, `alreadyExists`, `permissionDenied`, `resourceExhausted`, `failedPrecondition`, `aborted`, `outOfRange`, `unimplemented`, `internal`, `unavailable`, `dataLoss`, `unauthenticated`) to the gRPC/Connect status enum; default to `unknown` for unrecognized names.

---

## Deferred (post-MVP, tracked, not built here)

- `simtool mock set --from-event <eventId>` — seed a mock body from a previously logged real response. Add once a "get one event by id" server lookup exists.
- Streaming RPC mocking (fixed message sequences).
- Plain-HTTP / `URLProtocol` response substitution reusing `MockStore` + registry.
- Push delivery (piggyback `mockGeneration` on the ingestion response) to replace polling.
