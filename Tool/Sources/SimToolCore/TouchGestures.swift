import Foundation

/// The simulator screen in points — the space accessibility frames and the
/// CLI/YAML coordinates use.
public struct SimulatorScreenSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var scale: Double

    public init(width: Double, height: Double, scale: Double = 1) {
        self.width = width
        self.height = height
        self.scale = scale
    }

    public func ratio(_ point: TouchPoint) -> TouchRatio {
        TouchRatio(x: point.x / width, y: point.y / height)
    }
}

/// A position in screen points.
public struct TouchPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: TouchPoint) -> Double {
        hypot(other.x - x, other.y - y)
    }
}

/// A finger position as a fraction of the screen, 0…1 from the top-left
/// corner — the unit the HID helper speaks.
public struct TouchRatio: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
    }

    var helperText: String { "\(Self.format(x)) \(Self.format(y))" }

    static func format(_ value: Double) -> String { String(format: "%.5f", value) }
}

public enum TouchPhase: String, Codable, Equatable, Sendable {
    case down, move, up
}

/// One live touch event, streamed to the helper as it happens and never
/// answered: a finger follows the pointer only when nothing waits on a reply.
/// `second` makes it a two-finger event (pinch, rotate, two-finger pan).
public struct LiveTouchEvent: Equatable, Sendable {
    public var phase: TouchPhase
    public var first: TouchRatio
    public var second: TouchRatio?

    public init(phase: TouchPhase, first: TouchRatio, second: TouchRatio? = nil) {
        self.phase = phase
        self.first = first
        self.second = second
    }

    var helperLine: String {
        guard let second else { return "\(phase.rawValue) \(first.helperText)" }
        return "\(phase.rawValue)2 \(first.helperText) \(second.helperText)"
    }
}

/// A finger's whole life — down, the positions it passes, up — each sample
/// stamped with its offset from the start. The helper replays it against
/// absolute deadlines, so the timing survives a busy host.
public struct TouchPath: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public var phase: TouchPhase
        /// Seconds from the start of the path.
        public var time: Double
        public var point: TouchRatio

        public init(phase: TouchPhase, time: Double, point: TouchRatio) {
            self.phase = phase
            self.time = time
            self.point = point
        }
    }

    public var samples: [Sample]

    public init(samples: [Sample]) {
        self.samples = samples
    }

    public var duration: Double { samples.last?.time ?? 0 }

    var helperLine: String {
        let tokens = samples.map { sample -> String in
            let phase = switch sample.phase {
            case .down: "d"
            case .move: "m"
            case .up: "u"
            }
            let milliseconds = Int((sample.time * 1000).rounded())
            return "\(phase),\(milliseconds),\(TouchRatio.format(sample.point.x)),\(TouchRatio.format(sample.point.y))"
        }
        return (["path"] + tokens).joined(separator: " ")
    }
}

/// The one gesture primitive every UI-automation stack converges on (XCUITest,
/// WebDriverAgent, idb): down → rest → move at a speed → rest → up.
///
/// The rests are what make a gesture mean something to UIKit. A finger resting
/// ≥ 0.5 s before it moves is a long press (and, moving on, a drag that lifts
/// the item); a finger that slows down and rests before lifting leaves a scroll
/// view without inertia, while lifting in motion flings it.
public struct TouchStroke: Equatable, Sendable {
    public var from: TouchPoint
    public var to: TouchPoint
    /// Seconds the finger rests at `from` before moving.
    public var press: Double
    /// Finger speed while moving, in points per second.
    public var velocity: Double
    /// Seconds the finger rests at `to` before lifting. Zero lifts in motion.
    public var hold: Double

    public init(from: TouchPoint, to: TouchPoint, press: Double = 0, velocity: Double = TouchStroke.scrollVelocity, hold: Double = 0) {
        self.from = from
        self.to = to
        self.press = max(0, press)
        self.velocity = velocity > 0 ? velocity : Self.scrollVelocity
        self.hold = max(0, hold)
    }

    // Presets: defaults from XCUITest/WDA/idb/Detox, checked against UIKit on
    // the simulator.
    public static let tapPress = 0.06
    public static let longPressDuration = 1.0
    /// UIKit's long-press recognizer fires after 0.5 s; shorter is a tap.
    public static let longPressMinimum = 0.6
    public static let dragPress = 0.8
    public static let dragVelocity = 300.0
    public static let dragHold = 0.5
    public static let scrollVelocity = 600.0
    public static let scrollHold = 0.25
    /// A scroll view's pan recognizer swallows about this much travel before
    /// the content starts to follow, so a scroll by N points moves the finger N + this.
    public static let panSlop = 10.0
    public static let flingVelocity = 1000.0
    public static let flingDistance = 200.0

    /// SimulatorKit's message builder drops dragged events built less than
    /// 16 ms apart; one sample per 17 ms keeps every one of them.
    public static let sampleInterval = 0.017
    /// A finger that rests before lifting first slows down over this long.
    public static let easeOut = 0.15

    public static func tap(at point: TouchPoint, press: Double = tapPress) -> TouchStroke {
        TouchStroke(from: point, to: point, press: press)
    }

    public static func longPress(at point: TouchPoint, duration: Double = longPressDuration) -> TouchStroke {
        TouchStroke(from: point, to: point, press: duration)
    }

    /// Press until the item lifts, carry it, and rest before dropping it.
    public static func drag(
        from: TouchPoint,
        to: TouchPoint,
        press: Double = dragPress,
        velocity: Double = dragVelocity,
        hold: Double = dragHold
    ) -> TouchStroke {
        TouchStroke(from: from, to: to, press: press, velocity: velocity, hold: hold)
    }

    /// Moves content by the finger's travel and leaves it there.
    public static func scroll(from: TouchPoint, to: TouchPoint, velocity: Double = scrollVelocity, hold: Double = scrollHold) -> TouchStroke {
        TouchStroke(from: from, to: to, velocity: velocity, hold: hold)
    }

    /// Lifts in motion, so the content keeps going.
    public static func fling(from: TouchPoint, to: TouchPoint, velocity: Double = flingVelocity) -> TouchStroke {
        TouchStroke(from: from, to: to, velocity: velocity)
    }

    public var isStationary: Bool { from.distance(to: to) < 0.5 }

    /// Samples the stroke on a 17 ms grid.
    ///
    /// A rest before lifting is what keeps a scroll view from coasting, and
    /// UIKit has to see it: a sample repeating the same position never reaches
    /// the app, and after a silent pause UIKit still lifts with the speed of the
    /// last move about a third of the time. So the finger slows to a stop, then
    /// trembles by one pixel across the movement, the way a real finger rests.
    public func path(on screen: SimulatorScreenSize) -> TouchPath {
        let step = Self.sampleInterval
        var samples = [TouchPath.Sample(phase: .down, time: 0, point: screen.ratio(from))]
        var time = press

        if !isStationary {
            let distance = from.distance(to: to)
            // Slowing linearly to zero over `ease` seconds covers velocity·ease/2.
            let ease = hold > 0 ? min(Self.easeOut, 2 * distance / velocity) : 0
            let easeDistance = velocity * ease / 2
            let cruise = (distance - easeDistance) / velocity
            let travel = cruise + ease
            // Whole steps of at least 17 ms: never faster than the builder takes.
            let count = max(1, Int(travel / step))
            let interval = max(step, travel / Double(count))
            for index in 1...count {
                let t = travel * Double(index) / Double(count)
                let covered: Double
                if ease == 0 || t <= cruise {
                    covered = velocity * t
                } else {
                    let u = (t - cruise) / ease
                    covered = (distance - easeDistance) + easeDistance * (2 * u - u * u)
                }
                samples.append(TouchPath.Sample(
                    phase: .move,
                    time: time + interval * Double(index),
                    point: screen.ratio(point(at: covered / distance))
                ))
            }
            time += interval * Double(count)
        }

        if hold > 0 {
            let pixel = 1 / max(1, screen.scale)
            let across = abs(to.x - from.x) >= abs(to.y - from.y)
                ? TouchPoint(x: to.x, y: to.y + pixel)
                : TouchPoint(x: to.x + pixel, y: to.y)
            var index = 1
            while Double(index) * step < hold - 0.001 {
                let resting = index.isMultiple(of: 2) ? to : across
                samples.append(TouchPath.Sample(phase: .move, time: time + Double(index) * step, point: screen.ratio(resting)))
                index += 1
            }
            time += hold
        }
        samples.append(TouchPath.Sample(phase: .up, time: time, point: screen.ratio(to)))
        return TouchPath(samples: samples)
    }

    private func point(at fraction: Double) -> TouchPoint {
        TouchPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
    }
}
