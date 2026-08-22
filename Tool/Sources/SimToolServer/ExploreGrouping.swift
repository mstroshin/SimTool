import Foundation

// MARK: - Model

/// One flow of screens: a slice of the map that corresponds to a feature of
/// the app. Derived from what the map already carries — nothing here knows
/// anything about a particular application.
public struct ExploreGroup: Codable, Sendable, Equatable {
    /// The id of the screen the flow opens at — the target of the fork button
    /// that spawned it. Screen ids are stable across crawls, which is what
    /// lets a recorded name survive the map being rewritten under it.
    public var key: String
    /// How deeply the flow's door is nested: 1 for a branch off the outermost
    /// fork, 2 for a branch inside such a branch, and so on. Both make sense
    /// to offer: neither granularity reads well at every map size.
    public var level: Int
    /// Screens of the flow proper, in map order: everything reachable from the
    /// flow's first screen without walking back out through a screen every
    /// path from the launch point crosses. A screen several features share
    /// lands in each of their flows.
    public var members: [String]
    /// The fork screens whose buttons open the flow. Drawn with it as the way
    /// in, but never counted as the flow's own.
    public var bridges: [String]
    /// Where the sequence starts — the flow's first screen.
    public var entry: String?
    /// Raw material for a human name, strongest first. Never normalized: an
    /// agent picks from these, and a picked name stays traceable to the app.
    public var candidates: [String]
    /// Whether the flow is worth offering as a choice. A single card with no
    /// way in shows no sequence.
    public var displayable: Bool
    /// What a person named it, when anyone has. Nil leaves the flow readable
    /// through `label` rather than unusable.
    public var name: String?
    /// What to show it as: the name, else the strongest candidate, else `key`.
    /// The key stays visible next to it — with no way to correct a name by
    /// hand, seeing what a chip really filters is the only recourse.
    public var label: String
    /// The stored name was chosen for a membership this flow no longer has.
    /// Reported, never acted on: the old name keeps showing until a new one
    /// arrives.
    public var staleName: Bool

    public init(
        key: String,
        level: Int,
        members: [String],
        bridges: [String] = [],
        entry: String? = nil,
        candidates: [String] = [],
        displayable: Bool = false,
        name: String? = nil,
        label: String? = nil,
        staleName: Bool = false
    ) {
        self.key = key
        self.level = level
        self.members = members
        self.bridges = bridges
        self.entry = entry
        self.candidates = candidates
        self.displayable = displayable
        self.name = name
        self.label = label ?? ExploreGroupNaming.label(name: name, candidates: candidates, key: key)
        self.staleName = staleName
    }
}

// MARK: - Grouping

/// Splits a recorded map into the flows its own shape offers. Pure, so tests
/// feed it hand-written maps.
///
/// The signal is the map's transitions. A screen offering several ways forward
/// is a fork — the place where the user chooses a feature — and everything
/// behind one of its buttons is that feature's flow. Nothing here matches a
/// screen against a list of known features: the shape of the navigation is the
/// product's own decomposition, in whatever words its buttons carry.
public enum ExploreGrouping {
    /// The separator localization keys are namespaced with. Localization no
    /// longer decides membership, but the longest key prefix a flow's screens
    /// share is still offered as a name candidate.
    static let separator: Character = "_"

    /// A flow must own at least this many screens to be offered as a choice.
    /// The doors leading in do not count: they belong to the flow above, and
    /// counting them promoted every screen behind a fork button to a "flow" of
    /// one card. Those screens are already drawn inside the flow they hang off,
    /// so the chip added a filter nobody needs.
    public static let minimumDisplayableScreens = 2

    /// Every flow of the map, with whatever names have been recorded for them
    /// applied.
    public static func groups(of graph: ExploreGraph, names: ExploreGroupNames) -> [ExploreGroup] {
        named(groups(of: graph), with: names)
    }

    /// Recorded names applied to flows that were already computed, so a caller
    /// needing both the bare flows and the named ones splits the map once.
    public static func named(_ groups: [ExploreGroup], with names: ExploreGroupNames) -> [ExploreGroup] {
        let named = groups.map { group -> ExploreGroup in
            var group = group
            guard let recorded = names.names[group.key] else { return group }
            group.name = recorded.name
            group.label = ExploreGroupNaming.label(
                name: recorded.name,
                candidates: group.candidates,
                key: group.key
            )
            group.staleName = ExploreGroupNaming.isStale(recorded: recorded.members, current: group.members)
            return group
        }
        return ExploreGroupNaming.disambiguateLabels(named)
    }

    /// Every flow of the map, ordered coarse level first and by size within a
    /// level. A map with no forks — a straight corridor — offers no flows.
    public static func groups(of graph: ExploreGraph) -> [ExploreGroup] {
        ordered(Topology(graph: graph).flows())
    }

    // MARK: what the map draws

    /// The transitions the map draws: those leading into a screen further from
    /// the app's openings than the one they leave. A hop onto a shallower or
    /// equally deep screen is the crawler coming back — the home tab, a modal's
    /// ✕, a cross-tab jump — and drawing those turns the map into a thicket.
    ///
    /// Computed, never stored: the store keeps every transition the crawl
    /// observed, because dropping one from the file loses it for good, while
    /// the distances this rule reads move around as the crawl finds shorter
    /// paths.
    public static func descending(
        edges: [ExploreTransitionEdge],
        nodes: [ExploreScreenNode]
    ) -> [ExploreTransitionEdge] {
        let level = levels(edges: edges, nodes: nodes)
        return edges.filter { edge in
            guard let from = level[edge.from], let to = level[edge.to] else { return false }
            return to > from
        }
    }

    /// The same rule applied to a whole map, with the transition count brought
    /// in line with what is drawn — a header saying "30 переходов" over 26
    /// arrows is a bug report waiting to happen.
    public static func descending(_ graph: ExploreGraph) -> ExploreGraph {
        var copy = graph
        copy.edges = descending(edges: graph.edges, nodes: graph.nodes)
        copy.stats.transitions = copy.edges.count
        return copy
    }

    /// Distance from the screens the app opens into, over *every* recorded
    /// transition. Measured on the full set on purpose: measuring it on the
    /// drawn subset would make the drawing rule read the distances its own
    /// output produced, and a screen could lose its last incoming arrow and
    /// then keep the zero that loss handed it.
    ///
    /// A map whose transitions form a cycle through every screen has no
    /// opening; there the shallowest recorded screen stands in, so the rule
    /// still has somewhere to measure from. Screens no opening reaches keep
    /// their own recorded depth, so a transition between two of them can still
    /// be drawn.
    static func levels(edges: [ExploreTransitionEdge], nodes: [ExploreScreenNode]) -> [String: Int] {
        let known = Set(nodes.map(\.id))
        var outgoing: [String: [String]] = [:]
        var hasIncoming: Set<String> = []
        for edge in edges where known.contains(edge.from) && known.contains(edge.to) && edge.from != edge.to {
            outgoing[edge.from, default: []].append(edge.to)
            hasIncoming.insert(edge.to)
        }
        var sources = nodes.map(\.id).filter { !hasIncoming.contains($0) }
        if sources.isEmpty, let shallowest = nodes.min(by: { ($0.depth, $0.id) < ($1.depth, $1.id) }) {
            sources = [shallowest.id]
        }
        var level = Self.depths(from: sources, outgoing: outgoing)
        for node in nodes where level[node.id] == nil { level[node.id] = node.depth }
        return level
    }

    /// Breadth-first distances from several sources at once.
    static func depths(from sources: [String], outgoing: [String: [String]]) -> [String: Int] {
        var distance: [String: Int] = [:]
        for source in sources { distance[source] = 0 }
        var queue = sources
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for next in outgoing[current] ?? [] where distance[next] == nil {
                distance[next] = distance[current]! + 1
                queue.append(next)
            }
        }
        return distance
    }

    /// A copy of the map with every node told which flows it joined, whether
    /// it is an entry point, and a depth that describes a real path.
    ///
    /// A copy, deliberately: the crawler's own node array carries discovery
    /// bookkeeping (`depth` only ever shrinks, and the published edge set is
    /// derived from it), so annotating in place would rewrite state a run in
    /// flight still depends on.
    public static func annotated(_ graph: ExploreGraph) -> ExploreGraph {
        let topology = Topology(graph: graph)
        return annotated(graph, topology: topology, flows: topology.flows())
    }

    /// The annotated map and its named flows from one pass over the graph —
    /// what a status poll needs, and it needs it every few seconds while the
    /// crawl runs. Asking for the two separately split the map twice.
    public static func annotatedWithGroups(
        _ graph: ExploreGraph,
        names: ExploreGroupNames
    ) -> (graph: ExploreGraph, groups: [ExploreGroup]) {
        let topology = Topology(graph: graph)
        let flows = topology.flows()
        return (
            annotated(graph, topology: topology, flows: flows),
            named(ordered(flows), with: names)
        )
    }

    /// Coarse level first, the bigger flow first within a level, key to break
    /// the remaining ties.
    private static func ordered(_ flows: [ExploreGroup]) -> [ExploreGroup] {
        flows.sorted { left, right in
            if left.level != right.level { return left.level < right.level }
            if left.members.count != right.members.count { return left.members.count > right.members.count }
            return left.key < right.key
        }
    }

    private static func annotated(
        _ graph: ExploreGraph,
        topology: Topology,
        flows: [ExploreGroup]
    ) -> ExploreGraph {
        var memberOf: [String: [String]] = [:]
        for flow in flows {
            for member in flow.members { memberOf[member, default: []].append(flow.key) }
        }
        var copy = graph
        copy.nodes = graph.nodes.map { node in
            var node = node
            let joined = memberOf[node.id] ?? []
            node.groups = joined.isEmpty ? nil : joined.sorted()
            let isEntry = topology.isEntryPoint(node.id)
            node.entryPoint = isEntry ? true : nil
            // Distance from the nearest screen the app can open into. A screen
            // recorded after a relaunch is such an opening itself, so it sits
            // at zero rather than keeping the crawl's discovery depth — a
            // number that describes no path anyone can walk.
            if let reach = topology.reachDepth[node.id] { node.depth = reach }
            return node
        }
        return copy
    }
}

// MARK: - Topology

extension ExploreGrouping {
    /// What the map's edges say about reach: which screen the app opens into,
    /// how far every other screen sits from it, which screens no tap leads to,
    /// and where the map forks into features. Built once per grouping pass.
    struct Topology {
        let order: [String]
        private(set) var outgoing: [String: [String]] = [:]
        private(set) var incoming: [String: [String]] = [:]
        /// Labels of the transitions from one screen to another — the
        /// product's own words for what a button opens.
        private(set) var labels: [Route: [String]] = [:]
        /// Accessibility identifiers of the same transitions, kept apart from
        /// the words: an id is a name only a developer reads, so it is the last
        /// thing a flow should be called after.
        private(set) var identifiers: [Route: [String]] = [:]
        private(set) var titles: [String: String] = [:]
        private(set) var localizationKeys: [String: [String]] = [:]
        /// Whether the screen still has taps nobody has made — the difference
        /// between a screen the map has finished with and one it merely
        /// reached.
        private(set) var hasUntriedActions: [String: Bool] = [:]
        /// Distance from the nearest entry point, so every screen has one —
        /// including those only a relaunch reaches. This is what gets written
        /// back into the map.
        private(set) var reachDepth: [String: Int] = [:]

        struct Route: Hashable {
            let from: String
            let to: String
        }

        init(graph: ExploreGraph) {
            order = graph.nodes.map(\.id)
            let known = Set(order)
            for node in graph.nodes {
                titles[node.id] = node.title
                localizationKeys[node.id] = node.localizationKeys ?? []
                hasUntriedActions[node.id] = ExploreEngine.hasUntriedActions(node)
            }
            // The flows follow the map as it is drawn, not as it was recorded:
            // the store keeps every observed transition, including the hops
            // back out of a feature, and feeding those in would make one flow
            // reach into another.
            for edge in ExploreGrouping.descending(edges: graph.edges, nodes: graph.nodes)
            where known.contains(edge.from) && known.contains(edge.to) {
                outgoing[edge.from, default: []].append(edge.to)
                incoming[edge.to, default: []].append(edge.from)
                let route = Route(from: edge.from, to: edge.to)
                if let label = edge.action.targetLabel?.nilIfEmpty {
                    labels[route, default: []].append(label)
                }
                if let identifier = edge.action.targetId?.nilIfEmpty {
                    identifiers[route, default: []].append(identifier)
                }
            }
            reachDepth = ExploreGrouping.depths(from: entryPoints, outgoing: outgoing)
        }

        /// The screens the app opens into: those no tap leads to. Everything
        /// reachable, and every flow, hangs off these.
        var entryPoints: [String] {
            order.filter { (incoming[$0] ?? []).isEmpty }
        }

        /// True when no transition leads into the screen — it was recorded on
        /// launch or after a relaunch rather than reached by a tap.
        func isEntryPoint(_ id: String) -> Bool { (incoming[id] ?? []).isEmpty }

        // MARK: flows

        /// Every flow the map offers: one per button of a fork screen, holding
        /// what lies behind that button.
        func flows() -> [ExploreGroup] {
            let dominators = strictDominators()
            var targets: [String: [String]] = [:]
            for source in order {
                var seen = Set<String>()
                targets[source] = (outgoing[source] ?? []).filter { $0 != source && seen.insert($0).inserted }
            }
            // A fork is a screen offering two or more distinct ways forward —
            // the place where the user chooses a feature.
            let forks = Set(order.filter { (targets[$0] ?? []).count >= 2 })

            // Flow key -> the fork screens whose buttons open it, in map
            // order. Two forks offering the same screen open one flow, not two.
            var doors: [String: [String]] = [:]
            for fork in order where forks.contains(fork) && dominators[fork] != nil {
                for target in targets[fork] ?? [] {
                    // A button back to a screen the fork itself sits behind is
                    // the way out of the flow, not a flow of its own.
                    guard !(dominators[fork] ?? []).contains(target) else { continue }
                    doors[target, default: []].append(fork)
                }
            }

            return doors.map { key, opens in
                // The flow is what lies behind its first screen: walking from
                // it can wander anywhere except back out through a screen
                // every path from the launch point crosses.
                let reach = reached(from: [key], avoiding: dominators[key] ?? [])
                let members = order.filter { reach.contains($0) }
                let bridges = opens.filter { !reach.contains($0) }
                // How deeply the door is nested: a branch off the outermost
                // fork is level 1, a branch inside such a branch level 2.
                let level = 1 + (opens.map { (dominators[$0] ?? []).intersection(forks).count }.min() ?? 0)
                return ExploreGroup(
                    key: key,
                    level: level,
                    members: members,
                    bridges: bridges,
                    entry: key,
                    candidates: nameCandidates(key: key, doors: opens, members: members),
                    displayable: isDisplayable(members: members)
                )
            }
        }

        /// Whether the flow is worth a chip of its own. A sequence of screens
        /// is; a single screen is not — it already shows inside the flow it
        /// hangs off, and a chip filtering the map down to one card only
        /// crowds the panel. The exception is a screen with nothing further to
        /// open: no transition out and no untried tap left. Nothing will ever
        /// join it, so the one card is the whole truth about it.
        func isDisplayable(members: [String]) -> Bool {
            if members.count >= ExploreGrouping.minimumDisplayableScreens { return true }
            guard let only = members.first else { return false }
            return (outgoing[only] ?? []).isEmpty && !(hasUntriedActions[only] ?? false)
        }

        /// The screens every path from an entry point into `u` crosses, `u`
        /// itself aside. Computed by removal — `v` dominates `u` when taking
        /// `v` out of the map leaves `u` unreachable — because that is the
        /// exact question a flow asks: which screens can it not walk back out
        /// through. Screens no entry point reaches carry no entry, and spawn
        /// and join no flows.
        func strictDominators() -> [String: Set<String>] {
            let sources = entryPoints
            let reachable = Set(reachDepth.keys)
            var result: [String: Set<String>] = [:]
            for id in reachable { result[id] = [] }
            for blocked in reachable {
                let survived = reached(from: sources, avoiding: [blocked])
                for id in reachable where id != blocked && !survived.contains(id) {
                    result[id]?.insert(blocked)
                }
            }
            return result
        }

        /// Forward reachability with some screens taken out of the map.
        func reached(from sources: [String], avoiding blocked: Set<String>) -> Set<String> {
            var visited = Set(sources.filter { !blocked.contains($0) })
            var queue = Array(visited)
            var head = 0
            while head < queue.count {
                let current = queue[head]
                head += 1
                for next in outgoing[current] ?? []
                where !blocked.contains(next) && visited.insert(next).inserted {
                    queue.append(next)
                }
            }
            return visited
        }

        /// What the flow could be called, strongest first: the product's own
        /// words on the buttons that open it, then the screens' names, then
        /// the longest localization prefix its screens share, then the key.
        func nameCandidates(key: String, doors: [String], members: [String]) -> [String] {
            var result: [String] = []
            var seen = Set<String>()
            func add(_ value: String?) {
                guard let value = value?.nilIfEmpty, seen.insert(value).inserted else { return }
                result.append(value)
            }
            for door in doors {
                for label in labels[Route(from: door, to: key)] ?? [] { add(label) }
            }
            add(titles[key])
            for member in members where member != key { add(titles[member]) }
            add(commonKeyPrefix(of: members))
            // The buttons' accessibility identifiers only after all of those: a
            // chip reading `AccountUpgradeWidgetIds-Widget` names the button's
            // id namespace, while the screen right behind it is called
            // `AccountUpgradeView` — and an app whose buttons carry no labels
            // would otherwise have every flow named after plumbing.
            for door in doors {
                for identifier in identifiers[Route(from: door, to: key)] ?? [] { add(identifier) }
            }
            add(key)
            return result
        }

        /// The longest namespace every member's keys agree on — a name the
        /// localization convention proposes when the buttons' words are too
        /// generic.
        private func commonKeyPrefix(of members: [String]) -> String? {
            var shared: [String]?
            for member in members {
                let prefixes = (localizationKeys[member] ?? []).map {
                    $0.split(separator: ExploreGrouping.separator).map(String.init)
                }
                guard let longest = prefixes.max(by: { $0.count < $1.count }) else { continue }
                shared = shared.map { current in
                    Array(zip(current, longest).prefix { $0 == $1 }.map(\.0))
                } ?? longest
            }
            guard let shared, !shared.isEmpty else { return nil }
            return shared.joined(separator: String(ExploreGrouping.separator))
        }
    }
}
