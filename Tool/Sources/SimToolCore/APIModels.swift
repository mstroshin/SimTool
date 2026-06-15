import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
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
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
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

    public var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .number(value): String(value)
        case let .bool(value): String(value)
        case .object, .array, .null: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .number(value): value
        case let .string(value): Double(value)
        case .bool, .object, .array, .null: nil
        }
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }
}

public struct StreamPaths: Codable, Equatable, Sendable {
    public var avcc: String

    public init(avcc: String = "/stream.avcc") {
        self.avcc = avcc
    }
}

public struct StreamMetricsPayload: Codable, Equatable, Sendable {
    public var capturedFrames: Int
    public var h264EncodedFrames: Int
    public var h264Keyframes: Int
    public var h264DeltaFrames: Int
    public var droppedH264Frames: Int
    public var sentAVCCEnvelopes: Int
    public var avccClients: Int
    public var totalClients: Int
    public var uptimeSeconds: Double

    public init(
        capturedFrames: Int = 0,
        h264EncodedFrames: Int = 0,
        h264Keyframes: Int = 0,
        h264DeltaFrames: Int = 0,
        droppedH264Frames: Int = 0,
        sentAVCCEnvelopes: Int = 0,
        avccClients: Int = 0,
        totalClients: Int = 0,
        uptimeSeconds: Double = 0
    ) {
        self.capturedFrames = capturedFrames
        self.h264EncodedFrames = h264EncodedFrames
        self.h264Keyframes = h264Keyframes
        self.h264DeltaFrames = h264DeltaFrames
        self.droppedH264Frames = droppedH264Frames
        self.sentAVCCEnvelopes = sentAVCCEnvelopes
        self.avccClients = avccClients
        self.totalClients = totalClients
        self.uptimeSeconds = uptimeSeconds
    }
}

public struct ServerConfigPayload: Codable, Equatable, Sendable {
    public var device: String
    public var udid: String
    public var width: Int
    public var height: Int
    public var stream: StreamPaths
    public var metrics: StreamMetricsPayload
    /// Default app bundle identifier for log capture, when the server was started with one.
    public var logApp: String?

    public init(device: String, udid: String, width: Int, height: Int, stream: StreamPaths, metrics: StreamMetricsPayload, logApp: String? = nil) {
        self.device = device
        self.udid = udid
        self.width = width
        self.height = height
        self.stream = stream
        self.metrics = metrics
        self.logApp = logApp
    }
}

public struct ServerStatusPayload: Codable, Equatable, Sendable {
    public var device: String
    public var udid: String
    public var width: Int
    public var height: Int
    public var healthy: Bool
    public var metrics: StreamMetricsPayload

    public init(device: String, udid: String, width: Int, height: Int, healthy: Bool, metrics: StreamMetricsPayload) {
        self.device = device
        self.udid = udid
        self.width = width
        self.height = height
        self.healthy = healthy
        self.metrics = metrics
    }
}

public struct AccessibilityFrame: Codable, Equatable, Sendable {
    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?

    public init(x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct AccessibilityNode: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var accessibilityIdentifier: String?
    public var label: String?
    public var value: String?
    public var title: String?
    public var role: String?
    public var roleDescription: String?
    public var type: String?
    public var enabled: Bool?
    public var pid: Int?
    public var frame: AccessibilityFrame?
    public var children: [AccessibilityNode]
    /// Raw AXe payload for this node. Each raw value embeds the node's entire
    /// subtree, so populating it on every node multiplies the tree size by its
    /// depth — it stays nil unless the caller opts in.
    public var raw: JSONValue?

    public init(
        id: String,
        accessibilityIdentifier: String? = nil,
        label: String? = nil,
        value: String? = nil,
        title: String? = nil,
        role: String? = nil,
        roleDescription: String? = nil,
        type: String? = nil,
        enabled: Bool? = nil,
        pid: Int? = nil,
        frame: AccessibilityFrame? = nil,
        children: [AccessibilityNode] = [],
        raw: JSONValue? = nil
    ) {
        self.id = id
        self.accessibilityIdentifier = accessibilityIdentifier
        self.label = label
        self.value = value
        self.title = title
        self.role = role
        self.roleDescription = roleDescription
        self.type = type
        self.enabled = enabled
        self.pid = pid
        self.frame = frame
        self.children = children
        self.raw = raw
    }
}

public struct AccessibilityTreePayload: Codable, Equatable, Sendable {
    public var roots: [AccessibilityNode]
    public var nodeCount: Int

    public init(roots: [AccessibilityNode]) {
        self.roots = roots
        self.nodeCount = roots.reduce(0) { $0 + $1.recursiveCount }
    }
}

/// One row of the flat tree: just what an agent needs to recognize an element
/// and tap it. Nil fields are omitted from the encoded payload.
public struct AccessibilityFlatNode: Codable, Equatable, Sendable {
    /// Accessibility identifier — matches `input tap --id`.
    public var id: String?
    public var label: String?
    public var value: String?
    public var title: String?
    public var type: String?
    public var depth: Int
    /// [x, y, width, height] in points, rounded.
    public var frame: [Int]?
    /// Present only when false.
    public var enabled: Bool?

    public init(
        id: String? = nil,
        label: String? = nil,
        value: String? = nil,
        title: String? = nil,
        type: String? = nil,
        depth: Int,
        frame: [Int]? = nil,
        enabled: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.title = title
        self.type = type
        self.depth = depth
        self.frame = frame
        self.enabled = enabled
    }
}

public struct AccessibilityFlatTreePayload: Codable, Equatable, Sendable {
    /// Node count of the full tree, before any `labeledOnly` filtering.
    public var nodeCount: Int
    public var nodes: [AccessibilityFlatNode]

    public init(nodeCount: Int, nodes: [AccessibilityFlatNode]) {
        self.nodeCount = nodeCount
        self.nodes = nodes
    }
}

public struct AccessibilityMatch: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var path: [Int]
    public var node: AccessibilityNode

    public init(id: String, path: [Int], node: AccessibilityNode) {
        self.id = id
        self.path = path
        self.node = node
    }
}

public struct AccessibilityFindPayload: Codable, Equatable, Sendable {
    public var query: String
    public var matches: [AccessibilityMatch]

    public init(query: String, matches: [AccessibilityMatch]) {
        self.query = query
        self.matches = matches
    }
}

public struct SimulatorInputPayload: Codable, Equatable, Sendable {
    public var action: String?
    public var type: String?
    public var x: Double?
    public var y: Double?
    public var id: String?
    public var label: String?
    public var text: String?
    public var startX: Double?
    public var startY: Double?
    public var endX: Double?
    public var endY: Double?
    public var duration: Double?
    public var name: String?
    public var coordinateSpace: String?
    public var sourceWidth: Double?
    public var sourceHeight: Double?

    public init(
        action: String? = nil,
        type: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        id: String? = nil,
        label: String? = nil,
        text: String? = nil,
        startX: Double? = nil,
        startY: Double? = nil,
        endX: Double? = nil,
        endY: Double? = nil,
        duration: Double? = nil,
        name: String? = nil,
        coordinateSpace: String? = nil,
        sourceWidth: Double? = nil,
        sourceHeight: Double? = nil
    ) {
        self.action = action
        self.type = type
        self.x = x
        self.y = y
        self.id = id
        self.label = label
        self.text = text
        self.startX = startX
        self.startY = startY
        self.endX = endX
        self.endY = endY
        self.duration = duration
        self.name = name
        self.coordinateSpace = coordinateSpace
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
    }
}

public struct NetworkEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var timestamp: String?
    public var process: String?
    public var processID: Int?
    public var subsystem: String?
    public var category: String?
    public var messageType: String?
    public var eventMessage: String?
    public var raw: JSONValue

    public init(
        id: String,
        timestamp: String? = nil,
        process: String? = nil,
        processID: Int? = nil,
        subsystem: String? = nil,
        category: String? = nil,
        messageType: String? = nil,
        eventMessage: String? = nil,
        raw: JSONValue = .null
    ) {
        self.id = id
        self.timestamp = timestamp
        self.process = process
        self.processID = processID
        self.subsystem = subsystem
        self.category = category
        self.messageType = messageType
        self.eventMessage = eventMessage
        self.raw = raw
    }
}

public struct NetworkSnapshotPayload: Codable, Equatable, Sendable {
    public var supported: Bool
    public var deviceUDID: String
    public var collectedSeconds: Double
    public var eventCount: Int
    public var events: [NetworkEvent]
    public var warnings: [String]

    public init(
        supported: Bool,
        deviceUDID: String,
        collectedSeconds: Double,
        events: [NetworkEvent],
        warnings: [String] = []
    ) {
        self.supported = supported
        self.deviceUDID = deviceUDID
        self.collectedSeconds = collectedSeconds
        self.eventCount = events.count
        self.events = events
        self.warnings = warnings
    }
}

public extension AccessibilityNode {
    var recursiveCount: Int {
        1 + children.reduce(0) { $0 + $1.recursiveCount }
    }
}
