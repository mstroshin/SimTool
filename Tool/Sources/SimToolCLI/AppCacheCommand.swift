import ArgumentParser
import Foundation
import SimToolCore

extension AppCommand {
    struct Cache: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cache",
            abstract: "SimTool's managed build cache: the DerivedData of builds without a configured derivedDataPath.",
            subcommands: [Prune.self]
        )
    }
}

extension AppCommand.Cache {
    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove the cached DerivedData of workspaces that are gone, or of builds unused for a while. A dry run unless --delete.",
            discussion: """
            Each build identity without a configured derivedDataPath keeps its own \
            DerivedData in ~/Library/Caches/SimTool/app-builds/DerivedData, gigabytes \
            each, and no build removes it. An entry goes when the workspace or project \
            it was built from no longer exists — a removed worktree, a deleted checkout \
            — when no build has used it for --older-than days, or with --all. An entry a \
            running build uses stays. Without --delete nothing is removed: the command \
            lists what would go and the space it would free. A DerivedData path a \
            project's config sets is the project's own and never touched.
            """
        )

        @Option(name: .customLong("older-than"), help: "Also remove entries no build has used for this many days.")
        var olderThan: Int?

        @Flag(help: "Remove every entry, not only stale ones.")
        var all = false

        @Flag(help: "Remove them. Without it, only list what would go.")
        var delete = false

        @OptionGroup var common: CommonJSON

        func validate() throws {
            if let olderThan, olderThan < 0 { throw ValidationError("--older-than takes a number of days, 0 or more.") }
        }

        func run() async throws {
            let cache = SimulatorAppBuildCache(simtoolDirectory: SimToolDirectory.resolve())
            let payload = SimulatorAppBuildCachePruner.prune(cache: cache, olderThanDays: olderThan, all: all, delete: delete)
            if common.json {
                try printJSON(payload)
                return
            }
            print(Self.report(payload))
        }

        static func report(_ payload: SimulatorAppBuildCachePrunePayload) -> String {
            let going = payload.entries.filter { payload.deleted ? $0.deleted : ($0.reason != nil && !$0.inUse) }
            let busy = payload.entries.filter { $0.reason != nil && $0.inUse }
            let failed = payload.deleted ? payload.entries.filter { $0.reason != nil && !$0.inUse && !$0.deleted } : []
            var lines: [String] = []
            if payload.entries.isEmpty {
                lines.append("The build cache at \(payload.root) is empty.")
            } else if going.isEmpty {
                lines.append("Nothing to remove among \(payload.entries.count) cached DerivedData in \(payload.root).")
            } else {
                let size = ByteCountFormatter.string(fromByteCount: payload.bytes, countStyle: .file)
                let verb = payload.deleted ? "Removed" : "Would remove"
                lines.append("\(verb) \(going.count) of \(payload.entries.count) cached DerivedData in \(payload.root), \(size):")
                for entry in going { lines.append("  " + describe(entry)) }
            }
            for entry in busy { lines.append("  kept, a build is using it: " + describe(entry)) }
            for entry in failed { lines.append("  could not remove: " + describe(entry)) }
            if !payload.deleted, !going.isEmpty {
                lines.append("Pass --delete to remove them.")
            }
            return lines.joined(separator: "\n")
        }

        private static func describe(_ entry: SimulatorAppBuildCacheEntry) -> String {
            let size = entry.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
            let name = URL(fileURLWithPath: entry.path).lastPathComponent
            let source = entry.workspacePath ?? "unknown workspace"
            return "\(size.padding(toLength: 9, withPad: " ", startingAt: 0)) \(name.prefix(12))…  \(source) — \(entry.reason ?? "")"
        }
    }
}
