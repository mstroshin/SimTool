import Foundation

/// Deeplinks mined from the project checkout: every `scheme://path` literal
/// in source is a candidate route. The app's own URL schemes come from the
/// installed bundle's Info.plist, so the scan never guesses the scheme and
/// never harvests someone else's URLs.
enum DeeplinkHarvest {
    static let sourceExtensions: Set<String> = [
        "swift", "m", "mm", "h", "kt", "kts", "dart", "ts", "tsx", "js", "json", "yml", "yaml", "plist",
    ]

    /// Directories that hold build products or dependencies — their literals
    /// belong to other apps.
    private static let skippedDirectories: Set<String> = [
        ".git", ".build", "DerivedData", "Pods", "Carthage", "checkouts", "node_modules",
    ]

    /// Routes not worth putting on a map: destructive or service-only by name.
    static let denylist = ["delete", "remove", "clear", "reset", "logout", "log_out", "sign_out"]

    /// `CFBundleURLTypes` → the custom schemes the app answers to.
    static func schemes(fromInfoPlist data: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let urlTypes = plist["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        var schemes: [String] = []
        for urlType in urlTypes {
            for scheme in urlType["CFBundleURLSchemes"] as? [String] ?? [] where !schemes.contains(scheme) {
                schemes.append(scheme)
            }
        }
        return schemes
    }

    /// The `scheme://path` literals in one text, cleaned: an interpolation or
    /// placeholder cuts the URL at its start (leaving the static base route),
    /// trailing punctuation is trimmed, denylisted routes are dropped.
    static func urls(inText text: String, schemes: [String]) -> [String] {
        var results: [String] = []
        for scheme in schemes {
            var searchRange = text.startIndex..<text.endIndex
            while let match = text.range(of: "\(scheme)://", range: searchRange) {
                var end = match.upperBound
                while end < text.endIndex, isPathCharacter(text[end]) {
                    end = text.index(after: end)
                }
                searchRange = end..<text.endIndex
                var url = String(text[match.lowerBound..<end])
                while let last = url.last, "./-".contains(last) {
                    url.removeLast()
                }
                guard url.count > scheme.count + 3 else { continue }
                let lowered = url.lowercased()
                guard !denylist.contains(where: { lowered.contains($0) }) else { continue }
                if !results.contains(url) {
                    results.append(url)
                }
            }
        }
        return results
    }

    private static func isPathCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "/_-.".contains(character)
    }

    /// Scans the checkout. Unique URLs, shortest paths first — top-level
    /// routes are the likeliest to name a screen outright — capped, so one
    /// route-happy codebase does not flood every node's annotations.
    static func harvest(projectRoot: URL, schemes: [String], limit: Int = 40) -> [String] {
        guard !schemes.isEmpty else { return [] }
        var found: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator?.skipDescendants()
                }
                continue
            }
            guard sourceExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if let size = values?.fileSize, size > 4_000_000 { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  schemes.contains(where: { text.contains("\($0)://") }) else { continue }
            for link in urls(inText: text, schemes: schemes) where !found.contains(link) {
                found.append(link)
            }
        }
        let sorted = found.sorted { (pathDepth($0), $0) < (pathDepth($1), $1) }
        return Array(sorted.prefix(limit))
    }

    private static func pathDepth(_ url: String) -> Int {
        url.filter { $0 == "/" }.count
    }

    /// The meaningful tokens of a route: host and path segments, lowercased,
    /// with `_`/`-` squeezed out. `plata://payments/top_up` →
    /// `["payments", "topup"]`.
    static func routeTokens(of url: String) -> [String] {
        guard let schemeEnd = url.range(of: "://") else { return [] }
        return url[schemeEnd.upperBound...]
            .split(separator: "/")
            .map { $0.lowercased().filter { $0 != "_" && $0 != "-" } }
            .filter { !$0.isEmpty }
    }

    /// The screen a route names, or nil — attribution without ever opening
    /// the URL (a probe perturbs the app and mints orphan nodes for screens
    /// no tap reaches). Every token must appear in the screen's normalized
    /// name (`plata://invest` → `InvestMainScreen`); of several candidates
    /// the shortest name wins — the more general screen for the more general
    /// route — and a tie is ambiguity: a deeplink pinned on the wrong screen
    /// is worse than one left unattributed.
    static func screenIndex(for url: String, inNames names: [String]) -> Int? {
        let tokens = routeTokens(of: url)
        guard !tokens.isEmpty else { return nil }
        var best: (index: Int, length: Int)?
        var tied = false
        for (index, name) in names.enumerated() {
            let normalized = name.lowercased().filter { !"_- ".contains($0) }
            guard !normalized.isEmpty, tokens.allSatisfy({ normalized.contains($0) }) else { continue }
            if let current = best {
                if normalized.count < current.length {
                    best = (index, normalized.count)
                    tied = false
                } else if normalized.count == current.length {
                    tied = true
                }
            } else {
                best = (index, normalized.count)
            }
        }
        return tied ? nil : best?.index
    }
}
