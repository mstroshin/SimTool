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
    /// Absolute path of the project's `test-sessions` directory. A run writes
    /// its evidence files straight into the session directory, and both sides
    /// are always on the same machine, so the path is the cheapest contract —
    /// no evidence upload endpoint, no absolute path baked into the artifact.
    public var testSessionsPath: String?
    /// Changes every time a server starts. A client that polls by cursor (logs,
    /// state) resets its cursors when it sees a new one: a restarted server
    /// numbers its entries from zero again, and an old cursor would skip them.
    public var instanceId: String?
    /// The simulator runtime identifier, e.g. `com.apple.CoreSimulator.SimRuntime.iOS-26-4`.
    public var runtime: String?
    /// The serving simtool's version.
    public var version: String?
    /// The device type, e.g. `com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`.
    public var deviceType: String?
    /// The device's screens — two on a foldable — as they read right now.
    public var displays: [ServerDisplayPayload]?
    /// The lit screen's id, the one the stream shows and touches land on.
    public var activeDisplay: String?
    /// How a foldable is folded, as the device reports it.
    public var fold: SimulatorFoldState?
    /// Whether the 3D preview (`/stream.avcc?view=3d`) can be shown, and why not.
    public var view3d: ServerView3DPayload?

    public init(
        device: String,
        udid: String,
        width: Int,
        height: Int,
        stream: StreamPaths,
        metrics: StreamMetricsPayload,
        logApp: String? = nil,
        testSessionsPath: String? = nil,
        instanceId: String? = nil,
        runtime: String? = nil,
        version: String? = nil,
        deviceType: String? = nil,
        displays: [ServerDisplayPayload]? = nil,
        activeDisplay: String? = nil,
        fold: SimulatorFoldState? = nil,
        view3d: ServerView3DPayload? = nil
    ) {
        self.device = device
        self.udid = udid
        self.width = width
        self.height = height
        self.stream = stream
        self.metrics = metrics
        self.logApp = logApp
        self.testSessionsPath = testSessionsPath
        self.instanceId = instanceId
        self.runtime = runtime
        self.version = version
        self.deviceType = deviceType
        self.displays = displays
        self.activeDisplay = activeDisplay
        self.fold = fold
        self.view3d = view3d
    }
}

/// The 3D preview of a foldable: available, or why not.
public struct ServerView3DPayload: Codable, Equatable, Sendable {
    public var available: Bool
    public var reason: String?

    public init(available: Bool, reason: String? = nil) {
        self.available = available
        self.reason = reason
    }
}

/// One screen of the device as `/config` and the `device` event describe it:
/// what it is, and how its picture reads right now.
public struct ServerDisplayPayload: Codable, Equatable, Sendable {
    /// simctl's name (`primary`, `primary-1`): what `?display=` takes.
    public var id: String
    /// `cover` or `inner` on a foldable.
    public var role: String?
    public var screenID: Int
    /// The framebuffer, in pixels: what the stream carries for this screen.
    public var width: Int
    public var height: Int
    public var scale: Double
    /// Degrees clockwise the picture is turned from the framebuffer.
    public var rotation: Int
    /// The screen in points as its picture reads — the space taps use.
    public var points: SimulatorScreenSize
    /// Corner radii in points, clockwise from the picture's top-left.
    public var cornerRadii: [Double]?
    public var active: Bool

    public init(display: SimulatorDisplay, rotation: Int, active: Bool) {
        id = display.id
        role = display.role
        screenID = display.screenID
        width = display.width
        height = display.height
        scale = display.scale
        self.rotation = rotation
        points = display.points(rotation: rotation)
        cornerRadii = display.cornerRadii(rotation: rotation)
        self.active = active
    }

    /// Every screen of `layout`, lit and turned as `state` says. A one-screen
    /// device's screen is always lit and never turned.
    public static func all(layout: SimulatorDisplayLayout, state: SimulatorDisplayState?) -> [ServerDisplayPayload] {
        layout.displays.map { display in
            let active = layout.isFoldable ? state?.active == display.id : true
            return ServerDisplayPayload(display: display, rotation: state?.rotation(of: display.id) ?? 0, active: active)
        }
    }
}

/// Where the mock-rule handshake stands: the server's current generation, and
/// the newest one an app has confirmed applying. A run that declares mocks waits
/// for the two to meet before its first step — otherwise the app can still
/// answer from the real backend while the test believes it is mocked.
public struct MockAcknowledgementPayload: Codable, Equatable, Sendable {
    public var generation: Int
    public var acknowledged: Int?
    public var lastPollAt: Date?

    public init(generation: Int, acknowledged: Int? = nil, lastPollAt: Date? = nil) {
        self.generation = generation
        self.acknowledged = acknowledged
        self.lastPollAt = lastPollAt
    }

    public var isApplied: Bool { (acknowledged ?? -1) >= generation }
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
    /// Finger speed in points per second (swipe, drag, fling).
    public var velocity: Double?
    /// Seconds the finger rests at the end before lifting (swipe, drag).
    public var hold: Double?
    /// Seconds the finger rests at the start before moving (drag).
    public var press: Double?
    /// The way the finger moves (scroll, fling): up, down, left or right.
    public var direction: String?
    /// How far a scroll moves the content, in points.
    public var distance: Double?
    public var name: String?
    public var coordinateSpace: String?
    public var sourceWidth: Double?
    public var sourceHeight: Double?
    /// On or off (hardware-keyboard).
    public var enabled: Bool?
    /// Shown or hidden (software-keyboard); absent, it toggles.
    public var visible: Bool?
    /// What the input is aimed at, in words — the element a test step names
    /// when it taps by coordinates. Only the activity feed reads it; it never
    /// decides where a touch lands.
    public var target: String?
    /// A hinge angle in degrees, 0…180 (pose, in place of a named `name`).
    public var angle: Double?

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
        velocity: Double? = nil,
        hold: Double? = nil,
        press: Double? = nil,
        direction: String? = nil,
        distance: Double? = nil,
        name: String? = nil,
        coordinateSpace: String? = nil,
        sourceWidth: Double? = nil,
        sourceHeight: Double? = nil,
        enabled: Bool? = nil,
        visible: Bool? = nil,
        target: String? = nil,
        angle: Double? = nil
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
        self.velocity = velocity
        self.hold = hold
        self.press = press
        self.direction = direction
        self.distance = distance
        self.name = name
        self.coordinateSpace = coordinateSpace
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.enabled = enabled
        self.visible = visible
        self.target = target
        self.angle = angle
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
