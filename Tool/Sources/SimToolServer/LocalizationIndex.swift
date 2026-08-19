import Foundation

/// Reverse lookup from a visible UI string to the localization keys that can
/// produce it, built by scanning the project checkout once per exploration
/// run. Value-based matching is inherently many-to-many — one label can be
/// minted by several keys — so lookups return every candidate, capped.
struct LocalizationIndex: Sendable {
    private let keysByValue: [String: [String]]

    static let empty = LocalizationIndex(keysByValue: [:])

    init(keysByValue: [String: [String]]) {
        self.keysByValue = keysByValue
    }

    /// Directories that hold build products, dependencies, or test fixtures —
    /// never the app's own shipping strings.
    private static let skippedDirectories: Set<String> = [
        ".git", ".build", "DerivedData", "Pods", "Carthage", "checkouts", "node_modules",
    ]

    static func build(projectRoot: URL) -> LocalizationIndex {
        var keysByValue: [String: [String]] = [:]
        let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(name) || name.localizedCaseInsensitiveContains("test") {
                    enumerator?.skipDescendants()
                }
                continue
            }
            // Classic tables live in `<locale>.lproj/*.strings` (InfoPlist.strings
            // holds system-permission texts, not screens); catalogs are flat files.
            let isStringsTable = name.hasSuffix(".strings") && name != "InfoPlist.strings"
                && url.deletingLastPathComponent().pathExtension == "lproj"
            let isCatalog = name.hasSuffix(".xcstrings")
            guard isStringsTable || isCatalog else { continue }
            if let size = values?.fileSize, size > 8_000_000 { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            for (key, value) in isCatalog ? parseCatalog(data) : parseStringsTable(data) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2 else { continue }
                var keys = keysByValue[trimmed, default: []]
                if !keys.contains(key), keys.count < 6 {
                    keys.append(key)
                    keysByValue[trimmed] = keys
                }
            }
        }
        return LocalizationIndex(keysByValue: keysByValue)
    }

    /// `.strings` is an old-style property list, which Foundation parses
    /// natively — escapes and comments included.
    static func parseStringsTable(_ data: Data) -> [(key: String, value: String)] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let table = plist as? [String: String] else { return [] }
        return table.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    /// `.xcstrings` catalogs: every localization's value counts, and an entry
    /// with no localizations displays its own key.
    static func parseCatalog(_ data: Data) -> [(key: String, value: String)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: Any] else { return [] }
        var entries: [(key: String, value: String)] = []
        for key in strings.keys.sorted() {
            guard let entry = strings[key] as? [String: Any] else { continue }
            guard let localizations = entry["localizations"] as? [String: Any], !localizations.isEmpty else {
                entries.append((key, key))
                continue
            }
            for locale in localizations.keys.sorted() {
                guard let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any],
                      let value = unit["value"] as? String else { continue }
                entries.append((key, value))
            }
        }
        return entries
    }

    /// The keys whose value matches one of the screen's visible strings, in
    /// the order the strings appear on screen. A value minted by many keys
    /// ("Back", "Continue") identifies none of them — such labels are skipped,
    /// and at most two candidates per label survive.
    func keys(forLabels labels: [String], limit: Int = 30) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for label in labels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, let keys = keysByValue[trimmed], keys.count <= 4 else { continue }
            for key in keys.prefix(2) where seen.insert(key).inserted {
                result.append(key)
                if result.count >= limit { return result }
            }
        }
        return result
    }
}
