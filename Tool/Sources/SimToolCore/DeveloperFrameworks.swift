import Foundation

/// Locates Apple's private simulator frameworks across the differing Xcode layouts.
///
/// Up to and including Xcode 26, `SimulatorKit.framework` ships under
/// `Developer/Library/PrivateFrameworks`. Xcode 27 moved it to
/// `Contents/SharedFrameworks`, which lives *outside* the developer directory
/// returned by `xcode-select -p`. `CoreSimulator.framework` is installed
/// system-wide under `/Library/Developer/PrivateFrameworks`. This resolver
/// searches every known location so the tool keeps working regardless of which
/// Xcode is selected.
public enum DeveloperFrameworks {
    /// The active developer directory: `DEVELOPER_DIR` if set, otherwise the
    /// output of `xcode-select -p`, falling back to the conventional location.
    public static func developerDir() -> String {
        if let value = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !value.isEmpty {
            return value
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let selected = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (selected?.isEmpty == false) ? selected! : "/Applications/Xcode.app/Contents/Developer"
    }

    /// Candidate bundle paths for a private framework, in priority order.
    public static func candidateBundlePaths(_ name: String, developerDir dev: String) -> [String] {
        [
            "\(dev)/Library/PrivateFrameworks/\(name).framework",      // Xcode <= 26
            "\(dev)/../SharedFrameworks/\(name).framework",            // Xcode 27+
            "/Library/Developer/PrivateFrameworks/\(name).framework",  // system install
        ]
    }

    /// The first existing bundle path for `name`, or `nil` if none is present.
    public static func frameworkBundlePath(
        _ name: String,
        developerDir dev: String = DeveloperFrameworks.developerDir()
    ) -> String? {
        candidateBundlePaths(name, developerDir: dev).first { FileManager.default.fileExists(atPath: $0) }
    }
}
