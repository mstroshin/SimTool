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
        /// Slow enough that the list arrives roughly where the finger left it:
        /// a flick hands the distance over to inertia, and a heavy list carries
        /// it past a whole screenful — leaving two frames with nothing in
        /// common and a picture that ends at its first page.
        public var duration: Double

        public init(x: Double, from: Double, to: Double, duration: Double = 0.7) {
            self.x = x
            self.from = from
            self.to = to
            self.duration = duration
        }
    }

    /// Pixels a scroll must move the content to count as a scroll at all.
    /// Below this the page is at its end and only its rendering is twitching.
    static let minimumAdvance = 8
    /// How much longer the opening frame may be waited on after the arrival
    /// floor, for the screen to hold still.
    static let arrivalDeadline = Duration.seconds(5)
    /// How long a frame after a scroll may be waited on. Short, because by then
    /// the screen has arrived and only the scroll itself is being waited out —
    /// deceleration and the indicator fading. Paying the arrival deadline once
    /// per frame would cost a minute on a screen that never holds still.
    static let scrollDeadline = Duration.seconds(3)

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
    ///   - screenfuls: How tall the picture may grow. A cap, not a cost: a page
    ///     that ends sooner stops sooner, and only a page that really is this
    ///     deep pays for it.
    ///
    ///     Something has to bound this. A feed that fetches its next page as
    ///     the bottom comes into view has no bottom to reach, and the capture
    ///     would scroll until it ran out of memory; every scroll also has to be
    ///     walked back afterwards, and the picture is composed at full
    ///     resolution before it is scaled. The limit is counted in screenfuls
    ///     rather than in frames because that is what those costs follow — how
    ///     far one swipe happens to travel differs from screen to screen, so a
    ///     frame count cuts different pages at different depths.
    ///   - frameLimit: A backstop on the number of frames, for a page that
    ///     inches forward a few pixels at a time without ever quite stopping.
    ///   - arrival: How long to wait before the opening frame no matter how
    ///     still the screen looks. Stillness alone cannot say a screen has
    ///     arrived — a skeleton holds perfectly still while its content is in
    ///     flight, and a frame of skeleton is one the scrolled frames have
    ///     never seen, which ends the picture at its first page. The default
    ///     covers what any screen takes to load and any animation that plays
    ///     once; a caller that has already waited for the screen itself (the
    ///     crawl settles the accessibility tree before it records anything)
    ///     should pass a short one and keep its time.
    ///   - settle: How long a scroll is given to decelerate before the shutter
    ///     starts watching for the frame to hold still.
    ///   - viewportHeight: Pixel height one screenful takes in the result.
    public static func capture(
        deviceUDID: String,
        scroll: Scroll,
        screenfuls: Double = 12,
        frameLimit: Int = 40,
        arrival: Duration = .seconds(10),
        settle: Duration = .milliseconds(700),
        viewportHeight: Int? = nil
    ) async throws -> Capture {
        // The opening frame waits for the screen to hold still like every other
        // one. A screen that is still filling in from the network hands back a
        // frame the scrolled ones have nothing in common with, and the picture
        // ends after one screenful for want of anything to splice it to.
        try await Task.sleep(for: arrival)
        var frames = [try await steadyShot(deviceUDID: deviceUDID, deadline: arrivalDeadline)]
        var scrolls = 0
        var reachedBottom = false
        // Every frame is a screenful tall; the picture's height is the first
        // one plus what each scroll added.
        let screenful = LongScreenshot.decode(frames[0])?.height ?? 1
        var height = 1.0
        while frames.count < max(1, frameLimit), height < max(1, screenfuls) {
            try await advance(deviceUDID: deviceUDID, scroll: scroll, reverse: false, settle: settle)
            scrolls += 1
            let next = try await steadyShot(deviceUDID: deviceUDID, deadline: scrollDeadline)
            // The same gesture stopped moving the page: it is at its end, and
            // the frame holds nothing the picture does not already have. Judged
            // by how far the content actually travelled, not by whether the two
            // frames differ — a page pinned at its bottom still repaints a few
            // pixels, and chasing those burns the whole frame budget one pixel
            // at a time.
            // Two outcomes end the capture, and only one of them is the end of
            // the page. A frame that cannot be lined up at all — the screen
            // changed under the gesture — is a frame nothing can be spliced to,
            // so the picture stops there, but it stops short rather than
            // finished.
            guard let travelled = LongScreenshot.advance(frames[frames.count - 1], next) else { break }
            if travelled < minimumAdvance {
                reachedBottom = true
                break
            }
            height += Double(travelled) / Double(screenful)
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

    /// Waits for the screen to hold still before taking the frame, up to
    /// `deadline`.
    ///
    /// Watching two frames agree beats guessing a duration: deceleration, a
    /// scroll indicator fading, a row that arrived late all take as long as
    /// they take. But some screens never agree — a looping animation, a
    /// shimmer, a carousel — so the wait is bounded and what it has at the
    /// deadline is what the picture gets. Catching one arbitrary frame of an
    /// animation is a fair price; waiting forever is not.
    private static func steadyShot(
        deviceUDID: String,
        pause: Duration = .milliseconds(350),
        deadline: Duration
    ) async throws -> Data {
        var frame = try await SimulatorScreenshotClient.png(deviceUDID: deviceUDID)
        var waited = Duration.zero
        while waited < deadline {
            try await Task.sleep(for: pause)
            waited += pause
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
