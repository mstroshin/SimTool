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
