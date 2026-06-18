import Foundation

public enum NetworkLoggerJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: NetworkLoggerJSONValue])
    case array([NetworkLoggerJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: NetworkLoggerJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([NetworkLoggerJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum NetworkLoggerProtocol: String, Codable, CaseIterable, Equatable, Sendable {
    case http
    case grpc
}

public struct NetworkLoggerRequest: Codable, Equatable, Sendable {
    public var method: String?
    public var url: String?
    public var host: String?
    public var path: String?
    public var headers: [String: String]
    public var bodyByteCount: Int?
    public var bodyPreview: String?
    public var grpcService: String?
    public var grpcMethod: String?
    public var grpcAuthority: String?
    public var metadata: [String: String]
    public var messageByteCount: Int?

    public init(
        method: String? = nil,
        url: String? = nil,
        host: String? = nil,
        path: String? = nil,
        headers: [String: String] = [:],
        bodyByteCount: Int? = nil,
        bodyPreview: String? = nil,
        grpcService: String? = nil,
        grpcMethod: String? = nil,
        grpcAuthority: String? = nil,
        metadata: [String: String] = [:],
        messageByteCount: Int? = nil
    ) {
        self.method = method
        self.url = url
        self.host = host
        self.path = path
        self.headers = headers
        self.bodyByteCount = bodyByteCount
        self.bodyPreview = bodyPreview
        self.grpcService = grpcService
        self.grpcMethod = grpcMethod
        self.grpcAuthority = grpcAuthority
        self.metadata = metadata
        self.messageByteCount = messageByteCount
    }
}

public struct NetworkLoggerResponse: Codable, Equatable, Sendable {
    public var statusCode: Int?
    public var headers: [String: String]
    public var bodyByteCount: Int?
    public var bodyPreview: String?
    public var grpcStatusCode: String?
    public var grpcStatusMessage: String?
    public var metadata: [String: String]
    public var messageByteCount: Int?

    public init(
        statusCode: Int? = nil,
        headers: [String: String] = [:],
        bodyByteCount: Int? = nil,
        bodyPreview: String? = nil,
        grpcStatusCode: String? = nil,
        grpcStatusMessage: String? = nil,
        metadata: [String: String] = [:],
        messageByteCount: Int? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.bodyByteCount = bodyByteCount
        self.bodyPreview = bodyPreview
        self.grpcStatusCode = grpcStatusCode
        self.grpcStatusMessage = grpcStatusMessage
        self.metadata = metadata
        self.messageByteCount = messageByteCount
    }
}

public struct NetworkLoggerError: Codable, Equatable, Sendable {
    public var domain: String?
    public var code: Int?
    public var message: String

    public init(domain: String? = nil, code: Int? = nil, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }

    public init(_ error: Error) {
        let nsError = error as NSError
        self.domain = nsError.domain
        self.code = nsError.code
        self.message = nsError.localizedDescription
    }
}

public struct NetworkLoggerEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var timestamp: String
    public var appBundleID: String?
    public var appDisplayName: String?
    public var networkProtocol: NetworkLoggerProtocol
    public var durationMilliseconds: Double
    public var request: NetworkLoggerRequest
    public var response: NetworkLoggerResponse?
    public var error: NetworkLoggerError?
    public var rawMetadata: [String: NetworkLoggerJSONValue]
    /// Emitting process identifier, when known. Lets a SimTool server attribute the event to an
    /// app launch. Optional so existing payloads keep round-tripping.
    public var pid: Int?
    /// App launch this event belongs to, assigned by the SimTool server on ingestion. Apps leave
    /// this `nil`; only the server populates it.
    public var launchId: Int?
    /// True when this event's response was produced by a SimTool mock rule rather than the backend.
    public var mocked: Bool
    /// Identifier of the mock rule that produced the response, when `mocked` is true.
    public var mockRuleId: String?

    public init(
        id: String = UUID().uuidString,
        timestamp: String = NetworkLoggerTimestamp.now(),
        appBundleID: String? = nil,
        appDisplayName: String? = nil,
        networkProtocol: NetworkLoggerProtocol,
        durationMilliseconds: Double,
        request: NetworkLoggerRequest,
        response: NetworkLoggerResponse? = nil,
        error: NetworkLoggerError? = nil,
        rawMetadata: [String: NetworkLoggerJSONValue] = [:],
        pid: Int? = nil,
        launchId: Int? = nil,
        mocked: Bool = false,
        mockRuleId: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appBundleID = appBundleID
        self.appDisplayName = appDisplayName
        self.networkProtocol = networkProtocol
        self.durationMilliseconds = durationMilliseconds
        self.request = request
        self.response = response
        self.error = error
        self.rawMetadata = rawMetadata
        self.pid = pid
        self.launchId = launchId
        self.mocked = mocked
        self.mockRuleId = mockRuleId
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case appBundleID
        case appDisplayName
        case networkProtocol = "protocol"
        case durationMilliseconds
        case request
        case response
        case error
        case rawMetadata
        case pid
        case launchId
        case mocked
        case mockRuleId
    }

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
}

public struct NetworkLoggerBatchPayload: Codable, Equatable, Sendable {
    public var source: String?
    public var events: [NetworkLoggerEvent]
    /// Emitting process identifier shared by every event in the batch, used by a SimTool server to
    /// attribute the batch to an app launch. Optional so existing payloads keep round-tripping.
    public var pid: Int?

    public init(events: [NetworkLoggerEvent], source: String? = nil, pid: Int? = nil) {
        self.source = source
        self.events = events
        self.pid = pid
    }
}

public struct NetworkLoggerEventsPayload: Codable, Equatable, Sendable {
    public var eventCount: Int
    public var events: [NetworkLoggerEvent]
    public var warnings: [String]

    public init(events: [NetworkLoggerEvent], warnings: [String] = []) {
        self.eventCount = events.count
        self.events = events
        self.warnings = warnings
    }
}

public struct NetworkLoggerIngestionResponse: Codable, Equatable, Sendable {
    public var acceptedCount: Int

    public init(acceptedCount: Int) {
        self.acceptedCount = acceptedCount
    }
}

public struct NetworkLoggerEventFilter: Codable, Equatable, Sendable {
    public var app: String?
    public var networkProtocol: NetworkLoggerProtocol?
    public var since: String?
    public var limit: Int?

    public init(
        app: String? = nil,
        networkProtocol: NetworkLoggerProtocol? = nil,
        since: String? = nil,
        limit: Int? = nil
    ) {
        self.app = app
        self.networkProtocol = networkProtocol
        self.since = since
        self.limit = limit
    }

    public func apply(to events: [NetworkLoggerEvent]) -> [NetworkLoggerEvent] {
        let sinceDate = since.flatMap(NetworkLoggerTimestamp.date(from:))
        var filtered = events.filter { event in
            if let app, event.appBundleID != app { return false }
            if let networkProtocol, event.networkProtocol != networkProtocol { return false }
            if let since {
                if let sinceDate, let eventDate = NetworkLoggerTimestamp.date(from: event.timestamp) {
                    return eventDate >= sinceDate
                }
                if event.timestamp < since { return false }
            }
            return true
        }
        if let limit {
            filtered = Array(filtered.suffix(max(0, limit)))
        }
        return filtered
    }
}
