/// Which of a simulator's framebuffers to stream.
///
/// A simulator publishes a framebuffer for every port it has: its own
/// screens, and also TV-out, CarPlay and — with Xcode 27's Device Hub — a
/// 7680×4320 "resizable" scene. The device type's screen sizes say which are
/// the device's own; on a foldable both panels are, and the lit one is pinned
/// as `preferred`. Matching ignores orientation. Without declared sizes, the
/// largest framebuffer wins, as it always has.
///
/// Adapted from serve-sim's `FramebufferSurfaceSelector`
/// (https://github.com/EvanBacon/serve-sim, Apache-2.0); see
/// THIRD_PARTY_NOTICES.md.
public enum FramebufferSurfaceSelector {
    public struct Size: Equatable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        var isLive: Bool { width > 0 && height > 0 }
        var area: Int { width * height }

        func matches(_ other: Size) -> Bool {
            (width == other.width && height == other.height) || (width == other.height && height == other.width)
        }
    }

    /// The index of the framebuffer to stream among `candidates`: the one the
    /// size `preferred` names, else the smallest of the device's own screens
    /// (a foldable at rest is closed, on its cover), else the largest.
    public static func select(_ candidates: [Size], screens: [Size], preferred: Size? = nil) -> Int? {
        let live = candidates.indices.filter { candidates[$0].isLive }
        if let preferred, let index = live.first(where: { candidates[$0].matches(preferred) }) {
            return index
        }
        let own = live.filter { index in screens.contains { candidates[index].matches($0) } }
        if let smallest = own.min(by: { candidates[$0].area < candidates[$1].area }) {
            return smallest
        }
        return live.max { candidates[$0].area < candidates[$1].area }
    }
}
