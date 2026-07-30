import Foundation

/// The tool's own version, reported by `simtool --version` and recorded in a
/// test session's provenance — a replayed run on another machine needs to know
/// which simtool produced the artifact it is replaying.
public enum SimToolVersion {
    /// The released version this source tree is based on. Kept in sync with
    /// `Formula/simtool.rb`; a test fails when the two drift.
    public static let base = "0.10.0"

    /// Whether this binary came out of the release packaging, which compiles with
    /// `SIMTOOL_RELEASE` defined. A build from a working tree does not.
    public static let isRelease: Bool = {
        #if SIMTOOL_RELEASE
        true
        #else
        false
        #endif
    }()

    /// What the binary reports. A build from a working tree says so, because a
    /// verdict recorded against a locally built simtool is not a verdict recorded
    /// against the published release of the same number — and keeping those apart
    /// is the whole job of provenance.
    public static let current = isRelease ? base : base + "-dev"
}
