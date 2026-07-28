import Foundation

/// The app bundle as it exists on a simulator right now.
///
/// The only honest answer to "which build did this run exercise": neither a
/// test nor a run builds anything, so the installed `Info.plist` is the source
/// of truth — and comparing it against a packaged run's recorded build is what
/// stops a repro from being re-run against different code and pronounced fixed.
public struct InstalledAppBundle: Equatable, Sendable {
    public var path: URL
    public var version: String?
    public var build: String?

    public init(path: URL, version: String? = nil, build: String? = nil) {
        self.path = path
        self.version = version
        self.build = build
    }

    /// One line for a report: `3.20.0 (4398)`, as much of it as is known.
    public var shortDescription: String? {
        switch (version, build) {
        case let (version?, build?): "\(version) (\(build))"
        case let (version?, nil): version
        case let (nil, build?): "build \(build)"
        case (nil, nil): nil
        }
    }

    /// Nil when the app is not installed on the device, or its bundle cannot be
    /// read. Never throws: a caller asks this to enrich a report or warn, and
    /// failing to answer must not fail the work.
    public static func read(app: String, udid: String) async -> InstalledAppBundle? {
        guard let output = try? await ProcessRunner.runXcrun(["simctl", "get_app_container", udid, app, "app"]),
              output.status == 0
        else { return nil }
        let path = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let bundle = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Info.plist")),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return InstalledAppBundle(path: bundle) }
        return InstalledAppBundle(
            path: bundle,
            version: object["CFBundleShortVersionString"] as? String,
            build: object["CFBundleVersion"] as? String
        )
    }
}
