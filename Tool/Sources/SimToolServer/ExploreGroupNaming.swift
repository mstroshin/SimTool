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
    /// Below this share of screens shared between the membership a name was
    /// recorded for and the one the group has now, the name describes something
    /// else. One screen joining a group of two clears it; a group whose members
    /// are mostly new does not, and neither does one that shrank to a fraction
    /// of what it was.
    public static let carryOverForFreshName = 0.5

    /// Whether a stored name still describes the group. Nothing is renamed
    /// automatically — a stale name keeps showing until a new one arrives, so
    /// the panel never blanks out while an agent is not around.
    public static func isStale(recorded: [String], current: [String]) -> Bool {
        // A name recorded with no membership beside it has nothing to have
        // drifted from, and reporting it stale asks a person to re-check a
        // name that may be perfectly good.
        guard !recorded.isEmpty, !current.isEmpty else { return false }
        return overlap(recorded, current) < carryOverForFreshName
    }

    /// How much of two memberships is the same screen, as a share of the
    /// larger of the two: 1 for the same set, 0 for disjoint ones.
    ///
    /// Of the larger, deliberately. Measured against the current size alone,
    /// the share only ever noticed a group *growing*: a flow that lost nine of
    /// its ten screens kept its name at a serene 1.0, though losing nine
    /// screens changes what a name describes at least as much as gaining nine.
    static func overlap(_ left: [String], _ right: [String]) -> Double {
        let widest = max(left.count, right.count)
        guard widest > 0 else { return 0 }
        return Double(Set(left).intersection(right).count) / Double(widest)
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
            let name = normalized(name)
            guard !name.isEmpty else { continue }
            keysByName[name, default: []].append(key)
        }
        return keysByName.values.filter { $0.count > 1 }.flatMap { $0 }.sorted()
    }

    /// The same check over everything that was ever recorded, which is the
    /// only set it can safely be asked of.
    ///
    /// Judging only the names of flows the map shows *right now* let a name
    /// slip out of sight and be handed to a second flow: one crawl where a
    /// feature shrinks to a single screen is enough to drop it off the panel,
    /// and when it comes back — as the same key, which is the point of keys —
    /// two chips read «Депозит». Nothing can then correct either of them from
    /// the outside, so the clash has to be refused when the name is recorded.
    public static func conflicts(in names: ExploreGroupNames) -> [String] {
        conflicts(in: names.names.mapValues(\.name))
    }

    /// One name as a reader compares it: what somebody typed with the padding
    /// and the capitals taken off.
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Recorded names lined up with the flows they describe.
    ///
    /// By the key they were recorded under, normally — the screen the flow
    /// opens at, stable across crawls, which is the whole reason names are
    /// keyed by it. But that key is only as stable as the screen the button
    /// really opens first: let one crawl catch the loading screen that flashes
    /// before it and the key moves one screen forward, leaving «Оплата счетов»
    /// on a flow that no longer exists. Silently, too — a group that is gone
    /// cannot report that its name went stale.
    ///
    /// So a record whose key names no flow is offered to the flow whose
    /// membership it still describes. Conservatively, because a wrong transfer
    /// puts a person's word on a feature they never named:
    ///
    /// - only to a flow no record of its own claims;
    /// - only when the membership still mostly matches — the same bar a name
    ///   clears to count as current — and no other flow matches as closely;
    ///   a tie is an ambiguity, and an ambiguity is left alone;
    /// - only when one record claims that flow, for the same reason;
    /// - never a name another flow already shows, so a transfer cannot mint
    ///   the two identical chips the recording path exists to prevent.
    ///
    /// The record itself stays where it is, under the key it was written for:
    /// a group that comes back finds its own name again, and that outlives any
    /// guess made here.
    static func matched(_ names: ExploreGroupNames, to groups: [ExploreGroup]) -> [String: ExploreGroupName] {
        var byKey: [String: ExploreGroupName] = [:]
        var orphans: [String] = []
        let flows = Set(groups.map(\.key))
        // Sorted: `names` is a dictionary, and which record is read first must
        // not depend on how Swift happened to hash its keys.
        for key in names.names.keys.sorted() {
            guard let record = names.names[key] else { continue }
            if flows.contains(key) { byKey[key] = record }
            // A record with no membership beside it — written before the
            // membership was kept — offers nothing to recognise a flow by.
            else if !record.members.isEmpty { orphans.append(key) }
        }
        guard !orphans.isEmpty else { return byKey }

        var shown = Set(byKey.values.map { normalized($0.name) })
        // Flow key -> the orphaned records that would move onto it.
        var claims: [String: [String]] = [:]
        for orphan in orphans {
            guard let record = names.names[orphan], !shown.contains(normalized(record.name)) else { continue }
            let ranked = groups
                .filter { byKey[$0.key] == nil }
                .map { (key: $0.key, match: overlap(record.members, $0.members)) }
                .filter { $0.match >= carryOverForFreshName }
                .sorted { ($0.match, $1.key) > ($1.match, $0.key) }
            guard let best = ranked.first, ranked.count == 1 || best.match > ranked[1].match else { continue }
            claims[best.key, default: []].append(orphan)
        }
        for (flow, claimants) in claims.sorted(by: { $0.key < $1.key }) {
            guard claimants.count == 1, let record = names.names[claimants[0]] else { continue }
            guard !shown.contains(normalized(record.name)) else { continue }
            byKey[flow] = record
            shown.insert(normalized(record.name))
        }
        return byKey
    }

    /// The recorded keys a name is being taken away from: the ones that carry
    /// it and no longer name a flow of the map at all.
    ///
    /// `matched` shows such a record on the flow that took its membership over
    /// — the right thing to show, and a dead end to leave there. Recording the
    /// same name for the flow it is showing on was refused, because the file
    /// then held two keys with one name; and the dead key could not be cleared
    /// either, since a key that names no flow is not one `saveGroupNames`
    /// accepts. The only way out was editing `groups.json` by hand.
    ///
    /// So recording a name for a live flow is read as what it is — a person
    /// confirming the move — and the keys that outlived their flows let go of
    /// it. Only those: a record whose flow is merely off the panel this run
    /// keeps its name, which is the entire reason clashes are judged over the
    /// whole file and not over what is on screen.
    public static func retired(name: String, in names: ExploreGroupNames, flows: Set<String>) -> [String] {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return [] }
        return names.names
            .filter { key, record in !flows.contains(key) && normalized(record.name) == wanted }
            .keys
            .sorted()
    }

    /// The label a group is shown under: what it was named, else the strongest
    /// candidate the map itself offers, else the raw key. A group is always
    /// selectable — an unnamed one is only less readable, never unusable.
    ///
    /// Strongest means first, and nothing is second-guessed here. Candidates
    /// arrive ranked by `nameCandidates`, which is the only place that knows
    /// where each of them came from — and knowing that is the whole game. The
    /// vocabulary that sorts a screen's identifiers is written for identifiers:
    /// asked about the word on a button it discarded `Card`, `List`, `Banner`,
    /// `Item` and `Hola Cash`, each of them a thing the product sells, and the
    /// flow behind the «Card» button ended up on the panel as
    /// `TopUpByCardScreen`.
    public static func label(name: String?, candidates: [String], key: String) -> String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return candidates.first { !$0.isEmpty } ?? key
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
    /// Walking the list in order is what makes the replacement as good as the
    /// label it replaces: `nameCandidates` ranks conventions — component names,
    /// id namespaces — behind real ones, so stepping forward never steps down.
    /// It used to: the first choice skipped those candidates and the
    /// replacement did not, so two flows that shared `AccountView` ended up
    /// reading `FooWidgetIds-Widget` and `BarWidgetIds-Widget`.
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
