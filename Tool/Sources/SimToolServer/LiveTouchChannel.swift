import Foundation
import SimToolCore

/// One viewer's live touch connection. It turns the viewer's messages into
/// helper events in arrival order and remembers whether a finger is down, so a
/// viewer that vanishes mid-gesture (closed tab, dropped socket) never leaves
/// the finger pressed on the device.
///
/// Messages are JSON objects, coordinates fractions of the screen:
/// `{"t": "down" | "move" | "up", "x": 0.5, "y": 0.7}`, plus `x2`/`y2` for a
/// second finger.
final class LiveTouchChannel: @unchecked Sendable {
    private struct Message: Decodable {
        var t: String
        var x: Double
        var y: Double
        var x2: Double?
        var y2: Double?
    }

    private let lock = NSLock()
    private let emit: @Sendable (LiveTouchEvent) -> Void
    private let onDown: @Sendable () -> Void
    private var lastDown: LiveTouchEvent?
    private var closed = false

    /// `emit` receives the events in order; `onDown` runs at the start of each
    /// gesture (a test session anchors its step there).
    init(emit: @escaping @Sendable (LiveTouchEvent) -> Void, onDown: @escaping @Sendable () -> Void = {}) {
        self.emit = emit
        self.onDown = onDown
    }

    var isTouching: Bool {
        lock.withLock { lastDown != nil }
    }

    /// Handles one text frame. Malformed frames are dropped: a live finger
    /// cannot wait for an error reply, and the next frame carries its position.
    func receive(_ text: String) {
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)),
              let phase = TouchPhase(rawValue: message.t),
              message.x.isFinite, message.y.isFinite else { return }
        let second: TouchRatio? = if let x2 = message.x2, let y2 = message.y2, x2.isFinite, y2.isFinite {
            TouchRatio(x: x2, y: y2)
        } else {
            nil
        }
        let event = LiveTouchEvent(phase: phase, first: TouchRatio(x: message.x, y: message.y), second: second)

        var started = false
        lock.withLock {
            guard !closed else { return }
            switch phase {
            case .down:
                started = true
                lastDown = event
            case .move:
                guard lastDown != nil else { return }
                lastDown = event
            case .up:
                guard lastDown != nil else { return }
                lastDown = nil
            }
            emit(event)
        }
        if started { onDown() }
    }

    /// The viewer is gone: lift any finger it left down, where it last was.
    func disconnect() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            if let last = lastDown {
                emit(LiveTouchEvent(phase: .up, first: last.first, second: last.second))
                lastDown = nil
            }
        }
    }
}
