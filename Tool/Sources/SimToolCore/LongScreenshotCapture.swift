import Foundation

/// Photographs a screen taller than the display: screenshot, scroll, screenshot
/// again until the page stops moving, then splice the frames with
/// ``LongScreenshot``.
///
/// The screen is left where it was found. A crawler picks its next tap from an
/// accessibility snapshot taken before the picture, so a screen abandoned
/// halfway down its content would send every one of those taps to the wrong
/// place.
public enum LongScreenshotCapture {
    /// The drag that advances the page by roughly one screenful, in points.
    public struct Scroll: Sendable {
        public var x: Double
        public var from: Double
        public var to: Double
        /// Slow enough that the list arrives where the finger left it: a flick
        /// hands the distance over to inertia, and inertia is not repeatable.
        public var duration: Double

        public init(x: Double, from: Double, to: Double, duration: Double = 0.4) {
            self.x = x
            self.from = from
            self.to = to
            self.duration = duration
        }
    }

    public struct Capture: Sendable {
        public var png: Data
        public var frames: Int
        public var viewports: Double
        /// True when the frame budget ran out before the page did, so the
        /// picture ends mid-content rather than at the bottom.
        public var truncated: Bool
    }

    /// Captures the screen under the cursor of `scroll`.
    ///
    /// - Parameters:
    ///   - frameBudget: How many screenfuls to photograph at most. An infinite
    ///     feed has no bottom to reach, and every extra frame costs a scroll,
    ///     a settle and a scroll back.
    ///   - settle: How long a scroll is given to decelerate before the shutter
    ///     starts watching for the frame to hold still.
    ///   - viewportHeight: Pixel height one screenful takes in the result.
    public static func capture(
        deviceUDID: String,
        scroll: Scroll,
        frameBudget: Int = 4,
        settle: Duration = .milliseconds(700),
        viewportHeight: Int? = nil
    ) async throws -> Capture {
        var frames = [try await SimulatorScreenshotClient.png(deviceUDID: deviceUDID)]
        var scrolls = 0
        var reachedBottom = false
        while frames.count < max(1, frameBudget) {
            try await advance(deviceUDID: deviceUDID, scroll: scroll, reverse: false, settle: settle)
            scrolls += 1
            let next = try await steadyShot(deviceUDID: deviceUDID)
            // The page stopped moving under the same gesture: this is its end,
            // and the frame holds nothing the picture does not already have.
            if LongScreenshot.settled(frames[frames.count - 1], next) {
                reachedBottom = true
                break
            }
            frames.append(next)
        }
        // A screen that never moved has nothing to put back — and must not be
        // swiped the other way to find that out: a gesture a scroll view would
        // have eaten reaches whatever is behind it, and a sheet reads a
        // downward drag as "dismiss me".
        if frames.count > 1 {
            try await restore(deviceUDID: deviceUDID, scroll: scroll, to: frames[0], attempts: scrolls + 2)
        }
        let stitched = try LongScreenshot.stitch(frames: frames, viewportHeight: viewportHeight)
        return Capture(
            png: stitched.png,
            frames: stitched.frames,
            viewports: stitched.viewports,
            truncated: !reachedBottom
        )
    }

    /// Waits out what a scroll leaves behind before taking the frame. The
    /// deceleration is the short part; the scroll indicator lingers about a
    /// second after it, longer on a loaded machine, and a lazily built row
    /// arriving late is the same kind of straggler. Rather than guess a
    /// duration, watch until two frames in a row agree.
    private static func steadyShot(
        deviceUDID: String,
        pause: Duration = .milliseconds(350),
        patience: Int = 5
    ) async throws -> Data {
        var frame = try await SimulatorScreenshotClient.png(deviceUDID: deviceUDID)
        for _ in 0..<patience {
            try await Task.sleep(for: pause)
            let next = try await SimulatorScreenshotClient.png(deviceUDID: deviceUDID)
            if LongScreenshot.steady(frame, next) { return next }
            frame = next
        }
        return frame
    }

    /// Scrolls back until the screen looks the way it did before the picture,
    /// checking after every swipe rather than counting them: bouncing gives
    /// back less than the gesture asked for, and a blind extra swipe past the
    /// top is exactly the drag a sheet dismisses on.
    private static func restore(
        deviceUDID: String,
        scroll: Scroll,
        to opening: Data,
        attempts: Int
    ) async throws {
        for _ in 0..<attempts {
            let now = try await SimulatorScreenshotClient.png(deviceUDID: deviceUDID)
            if LongScreenshot.settled(now, opening) { return }
            try await advance(deviceUDID: deviceUDID, scroll: scroll, reverse: true, settle: .milliseconds(250))
        }
    }

    private static func advance(
        deviceUDID: String,
        scroll: Scroll,
        reverse: Bool,
        settle: Duration
    ) async throws {
        _ = try await SimulatorInputClient.swipe(
            deviceUDID: deviceUDID,
            startX: scroll.x,
            startY: reverse ? scroll.to : scroll.from,
            endX: scroll.x,
            endY: reverse ? scroll.from : scroll.to,
            duration: scroll.duration
        )
        try await Task.sleep(for: settle)
    }
}
