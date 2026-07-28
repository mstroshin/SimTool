import Foundation

/// The tool's own version, reported by `simtool --version` and recorded in a
/// test session's provenance — a replayed run on another machine needs to know
/// which simtool produced the artifact it is replaying.
///
/// Kept in sync with `Formula/simtool.rb` by the release scripts; bump it in the
/// same commit that bumps the formula.
public enum SimToolVersion {
    public static let current = "0.9.0"
}
