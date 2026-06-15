import Foundation

/// Maps raw xcodebuild output lines to short human-readable statuses for
/// progress UIs. Unknown lines map to nil so callers keep the previous status.
public enum XcodebuildProgress {
    public static func status(forLine line: String) -> String? {
        guard let first = line.first, first != " ", first != "\t" else { return nil }
        if line.hasPrefix("Resolve Package Graph") || line.hasPrefix("Resolving ") {
            return "Resolving packages"
        }
        if line.hasPrefix("Build description") || line.hasPrefix("Planning") {
            return "Planning build"
        }
        let tokens = tokenize(line)
        guard let verb = tokens.first else { return nil }
        switch verb {
        case "SwiftCompile", "CompileSwift", "CompileSwiftSources", "CompileC":
            if let file = tokens.dropFirst().last(where: { token in
                sourceSuffixes.contains(where: token.hasSuffix)
            }) {
                return "Compiling \(lastPathComponent(file))"
            }
            return "Compiling sources"
        case "Ld":
            guard tokens.count > 1 else { return "Linking" }
            return "Linking \(lastPathComponent(tokens[1]))"
        case "CodeSign":
            guard tokens.count > 1 else { return "Signing" }
            return "Signing \(lastPathComponent(tokens[1]))"
        case "CompileAssetCatalog", "CompileAssetCatalogVariant":
            return "Compiling asset catalogs"
        case "CompileStoryboard", "CompileXIB":
            guard tokens.count > 1 else { return "Compiling interface files" }
            return "Compiling \(lastPathComponent(tokens[1]))"
        case "PhaseScriptExecution":
            guard tokens.count > 1 else { return "Running build script" }
            return "Running script \(tokens[1])"
        case "ProcessInfoPlistFile":
            return "Processing Info.plist"
        case "CopySwiftLibs", "CpResource", "PBXCp", "Copy", "CopyStringsFile", "CpHeader":
            return "Copying resources"
        default:
            return nil
        }
    }

    private static let sourceSuffixes = [".swift", ".m", ".mm", ".c", ".cc", ".cpp"]

    /// Splits a line on spaces while honoring xcodebuild's backslash-escaped
    /// spaces (e.g. `PhaseScriptExecution Run\ SwiftLint /path.sh`).
    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if character == "\\", next < line.endIndex, line[next] == " " {
                current.append(" ")
                index = line.index(index, offsetBy: 2)
            } else if character == " " {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                index = next
            } else {
                current.append(character)
                index = next
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
