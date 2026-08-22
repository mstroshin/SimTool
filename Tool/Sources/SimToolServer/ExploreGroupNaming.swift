import Foundation

/// One human name given to a group, together with the membership it was chosen
/// for. The membership is what later tells a group that merely grew from one
/// that became a different thing.
public struct ExploreGroupName: Codable, Sendable, Equatable {
    public var name: String
    public var members: [String]

    public init(name: String, members: [String]) {
        self.name = name
        self.members = members
    }
}

/// Names live in their own file beside `graph.json`, for the same reason the
/// canvas arrangement does: the crawler rewrites the graph after every step,
/// and a name written into it would race that write.
public struct ExploreGroupNames: Codable, Sendable {
    public var schemaVersion: Int
    /// Group key -> what a person calls it.
    public var names: [String: ExploreGroupName]

    public init(schemaVersion: Int = 1, names: [String: ExploreGroupName] = [:]) {
        self.schemaVersion = schemaVersion
        self.names = names
    }
}

/// What the tab sends when it asks for names, and what an agent posts back.
public struct ExploreGroupNamesRequest: Codable, Sendable {
    public var names: [String: String]

    public init(names: [String: String] = [:]) {
        self.names = names
    }
}

public enum ExploreGroupNaming {
    /// Below this share of a group's screens carried over from the naming, the
    /// name describes something else. One screen joining a group of two clears
    /// it; a group whose members are mostly new does not.
    public static let carryOverForFreshName = 0.5

    /// Whether a stored name still describes the group. Nothing is renamed
    /// automatically — a stale name keeps showing until a new one arrives, so
    /// the panel never blanks out while an agent is not around.
    public static func isStale(recorded: [String], current: [String]) -> Bool {
        guard !current.isEmpty else { return false }
        let carried = Set(recorded).intersection(current).count
        return Double(carried) / Double(current.count) < carryOverForFreshName
    }

    /// Two groups shown side by side may not carry one name: a chip whose label
    /// matches another's says nothing about what it filters. Compared trimmed
    /// and case-insensitively, because "Bill pay" and "bill pay" are the same
    /// label to a reader.
    ///
    /// Returns the group keys involved in a clash, sorted, or an empty array.
    public static func conflicts(in names: [String: String]) -> [String] {
        var keysByName: [String: [String]] = [:]
        for (key, name) in names {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }
            keysByName[normalized, default: []].append(key)
        }
        return keysByName.values.filter { $0.count > 1 }.flatMap { $0 }.sorted()
    }

    /// The label a group is shown under: what it was named, else the strongest
    /// candidate the map itself offers, else the raw key. A group is always
    /// selectable — an unnamed one is only less readable, never unusable.
    public static func label(name: String?, candidates: [String], key: String) -> String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let candidate = candidates.first(where: { !$0.isEmpty }) { return candidate }
        return key
    }

    /// Moves unnamed groups onto the next name the map offers wherever a label
    /// would otherwise be shared.
    ///
    /// Posted names are checked for collisions when they arrive, but a label
    /// can also come from a candidate — and two hubs' buttons can carry the
    /// same word ("Deposit" opens a top-up sheet in payments and another one in
    /// investing). Identical chips would say nothing about what they filter, so
    /// a clashing group walks down its candidates — the screens' own names come
    /// right after the buttons' words — and takes the first one no other chip
    /// shows. The key is the last resort it was always meant to be: a chip
    /// reading `s-c08837643e` names nothing a reader can recognise.
    ///
    /// A named group is never touched: its name was vetted, and silently
    /// replacing it would hide the collision instead of the person seeing it.
    public static func disambiguateLabels(_ groups: [ExploreGroup]) -> [ExploreGroup] {
        var shownBy: [String: Int] = [:]
        for group in groups where group.displayable {
            shownBy[group.label.lowercased(), default: 0] += 1
        }
        // Every group in a clash moves, not all but one of them: which chip
        // would have kept the shared word depends on map order, and a reader
        // cannot tell that the "Deposit" they see is one of two.
        var claimed = Set(shownBy.filter { $0.value == 1 }.keys)
        return groups.map { group in
            guard group.displayable, group.name == nil else { return group }
            guard (shownBy[group.label.lowercased()] ?? 0) > 1 else { return group }
            let replacement = group.candidates.first {
                let candidate = $0.lowercased()
                return !claimed.contains(candidate) && (shownBy[candidate] ?? 0) < 2
            } ?? group.key
            claimed.insert(replacement.lowercased())
            var group = group
            group.label = replacement
            return group
        }
    }
}
