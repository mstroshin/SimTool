import Foundation
import SimToolCore

/// What a viewer's live input channel streams to the helper.
enum LiveInputEvent: Equatable, Sendable {
    case touch(LiveTouchEvent)
    case key(LiveKeyEvent)
}

/// One viewer's live input connection: its finger and, while it types on the
/// device, its keys. It turns the viewer's messages into helper events in
/// arrival order and remembers what is held, so a viewer that vanishes
/// (closed tab, dropped socket) never leaves a finger pressed or a key down on
/// the device.
///
/// Messages are JSON objects. Touches carry fractions of the screen:
/// `{"t": "down" | "move" | "up", "x": 0.5, "y": 0.7}`, plus `x2`/`y2` for a
/// second finger. Keys carry the browser's physical key name:
/// `{"t": "keydown" | "keyup", "code": "KeyA"}`.
final class LiveInputChannel: @unchecked Sendable {
    private struct Message: Decodable {
        var t: String
        var x: Double?
        var y: Double?
        var x2: Double?
        var y2: Double?
        var code: String?
    }

    private let lock = NSLock()
    private let emit: @Sendable (LiveInputEvent) -> Void
    private let onDown: @Sendable () -> Void
    private var lastDown: LiveTouchEvent?
    private var heldKeys: [KeyboardKey] = []
    private var closed = false

    /// `emit` receives the events in order; `onDown` runs at the start of each
    /// gesture and key press (a test session anchors its step there).
    init(emit: @escaping @Sendable (LiveInputEvent) -> Void, onDown: @escaping @Sendable () -> Void = {}) {
        self.emit = emit
        self.onDown = onDown
    }

    var isTouching: Bool {
        lock.withLock { lastDown != nil }
    }

    /// Handles one text frame. Malformed frames are dropped: live input cannot
    /// wait for an error reply, and the next frame carries the state on.
    func receive(_ text: String) {
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)) else { return }
        let started: Bool
        switch message.t {
        case "keydown", "keyup":
            guard let code = message.code, let key = KeyboardKey(webCode: code) else { return }
            started = receiveKey(key, isDown: message.t == "keydown")
        default:
            guard let phase = TouchPhase(rawValue: message.t),
                  let x = message.x, let y = message.y, x.isFinite, y.isFinite else { return }
            let second: TouchRatio? = if let x2 = message.x2, let y2 = message.y2, x2.isFinite, y2.isFinite {
                TouchRatio(x: x2, y: y2)
            } else {
                nil
            }
            started = receiveTouch(LiveTouchEvent(phase: phase, first: TouchRatio(x: x, y: y), second: second))
        }
        if started { onDown() }
    }

    /// The viewer is gone: lift any finger it left down, where it last was,
    /// and release its keys, the last pressed first.
    func disconnect() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            if let last = lastDown {
                emit(.touch(LiveTouchEvent(phase: .up, first: last.first, second: last.second)))
                lastDown = nil
            }
            for key in heldKeys.reversed() {
                emit(.key(LiveKeyEvent(key: key, isDown: false)))
            }
            heldKeys.removeAll()
        }
    }

    private func receiveTouch(_ event: LiveTouchEvent) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            switch event.phase {
            case .down:
                lastDown = event
            case .move:
                guard lastDown != nil else { return false }
                lastDown = event
            case .up:
                guard lastDown != nil else { return false }
                lastDown = nil
            }
            emit(.touch(event))
            return event.phase == .down
        }
    }

    /// A key goes down once and up once: a repeated down or an up for a key
    /// this viewer never pressed is dropped.
    private func receiveKey(_ key: KeyboardKey, isDown: Bool) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            if isDown {
                guard !heldKeys.contains(key) else { return false }
                heldKeys.append(key)
            } else {
                guard let index = heldKeys.firstIndex(of: key) else { return false }
                heldKeys.remove(at: index)
            }
            emit(.key(LiveKeyEvent(key: key, isDown: isDown)))
            return isDown
        }
    }
}
