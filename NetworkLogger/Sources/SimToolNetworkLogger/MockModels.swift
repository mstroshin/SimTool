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
