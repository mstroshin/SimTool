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
    /// Raw material for a human name, strongest first: the words the app's own
    /// buttons carry, then the names a developer gave things, then the ones
    /// that name a convention rather than a thing — see `nameCandidates`, whose
    /// ranking everything reading this list relies on. Never normalized: an
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
        // Not `names.names[group.key]`: a name also reaches the flow its key
        // slid off — see `ExploreGroupNaming.matched`.
        let records = ExploreGroupNaming.matched(names, to: groups)
        let named = groups.map { group -> ExploreGroup in
            var group = group
            guard let recorded = records[group.key] else { return group }
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
        measured(edges: edges, nodes: nodes).descending(edges)
    }

    /// The same rule applied to a whole map, with the transition count brought
    /// in line with the transitions that survive it — a count of 30 over a map
    /// that kept 26 is a bug report waiting to happen. It is still a count of
    /// transitions, not of arrows: two buttons of one screen opening the same
    /// screen are two transitions drawn as one arrow, so a canvas that prints a
    /// number over the picture counts the arrows it drew itself.
    public static func descending(_ graph: ExploreGraph) -> ExploreGraph {
        var copy = graph
        copy.edges = descending(edges: graph.edges, nodes: graph.nodes)
        copy.stats.transitions = copy.edges.count
        return copy
    }

    /// How deep every screen of the map sits, and what that was measured from.
    struct Measure {
        /// Distance from the nearest screen the measuring started at.
        let level: [String: Int]
        /// The screens the app opens into: where the measuring starts, at zero.
        let openings: [String]
        /// Those, plus the entrance of each piece of map they cannot reach —
        /// which starts past the deepest screen they do reach, not at zero.
        ///
        /// A reading of this pass, all of it, `openings` included: which of the
        /// store's marks the measuring actually began at is this pass' answer,
        /// not the crawl's note. Nothing here is written back — a reading saved
        /// into the store comes back as a fact.
        let sources: [String]

        /// Whether the transition leads deeper into the app than the screen it
        /// leaves — the one question the drawn map asks of it.
        func descends(_ edge: ExploreTransitionEdge) -> Bool {
            guard let from = level[edge.from], let to = level[edge.to] else { return false }
            return to > from
        }

        func descending(_ edges: [ExploreTransitionEdge]) -> [ExploreTransitionEdge] {
            edges.filter(descends)
        }
    }

    /// Distance from the screens the app opens into, over *every* recorded
    /// transition. Measured on the full set on purpose: measuring it on the
    /// drawn subset would make the drawing rule read the distances its own
    /// output produced, and a screen could lose its last incoming arrow and
    /// then keep the zero that loss handed it.
    ///
    /// Every screen is measured from something. The screens no opening reaches
    /// are a piece of map in their own right — what a relaunch recorded before
    /// the crawl ever found the way in — so that piece is measured from its own
    /// entrance and laid past the deepest reached screen: its transitions are
    /// drawn among themselves, none of them poses as a descent into the part
    /// that hangs off the openings, and its forks still offer their features.
    /// Leaving it on its recorded depth drew nothing at all — in a fresh store
    /// those screens share one depth, and equal levels never descend — and
    /// leaving it unmeasured cost it every chip it had.
    static func measured(edges: [ExploreTransitionEdge], nodes: [ExploreScreenNode]) -> Measure {
        let (outgoing, incoming) = adjacency(edges: edges, nodes: nodes)
        let opened = openings(nodes: nodes, incoming: incoming, outgoing: outgoing)
        var level = depths(from: opened, outgoing: outgoing)
        var sources = opened
        let past = (level.values.max() ?? 0) + 1
        let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pending = nodes.map(\.id).filter { level[$0] == nil }
        while !pending.isEmpty {
            let left = Set(pending)
            // The entrance of what is left over: a screen nothing left in it
            // leads into. A piece that is one cycle has no such screen, and
            // there the anchor stands in — the cycle is then drawn as the
            // sequence it is, with only the hop that closes it left out, which
            // is what the rest of the map does with a hop leading back.
            var entrances = pending.filter { (incoming[$0] ?? []).allSatisfy { !left.contains($0) } }
            if entrances.isEmpty {
                guard let root = anchor(
                    among: pending.compactMap { byId[$0] },
                    incoming: incoming,
                    outgoing: outgoing
                ) else { break }
                entrances = [root]
            }
            var confined: [String: [String]] = [:]
            for id in pending { confined[id] = (outgoing[id] ?? []).filter { left.contains($0) } }
            let piece = depths(from: entrances, outgoing: confined)
            guard !piece.isEmpty else { break }
            for (id, distance) in piece { level[id] = past + distance }
            sources += entrances
            pending = pending.filter { level[$0] == nil }
        }
        return Measure(level: level, openings: opened, sources: sources)
    }

    /// Who leads where, over the transitions the store recorded. A self-loop
    /// is a screen changing state, and an endpoint the map no longer carries
    /// is a leftover of an older run: neither says anything about how deep a
    /// screen sits.
    static func adjacency(
        edges: [ExploreTransitionEdge],
        nodes: [ExploreScreenNode]
    ) -> (outgoing: [String: [String]], incoming: [String: [String]]) {
        let known = Set(nodes.map(\.id))
        var outgoing: [String: [String]] = [:]
        var incoming: [String: [String]] = [:]
        for edge in edges where known.contains(edge.from) && known.contains(edge.to) && edge.from != edge.to {
            outgoing[edge.from, default: []].append(edge.to)
            incoming[edge.to, default: []].append(edge.from)
        }
        return (outgoing, incoming)
    }

    /// The screens measuring the map starts at.
    ///
    /// Recorded first, guessed last. Standing *every* screen with no incoming
    /// transition in for an opening cost the map real arrows — one screen the
    /// crawl met only after a relaunch measured the whole map from itself, the
    /// transitions into the screens around it stopped descending, and a named
    /// feature disappeared with them without so much as a stale flag.
    ///
    /// 1. The screens the store marks as openings, minus the ones another
    ///    opening leads to — see `rootmost`. The mark is the only signal that
    ///    still holds in an app with a tab bar, where every screen has a way
    ///    home and none is left without an incoming transition.
    /// 2. Failing that, the screens no transition leads into that also sit at
    ///    the shallowest depth the crawl recorded. Three taps deep, such a
    ///    screen is an island the crawl relaunched into, not an opening.
    /// 3. Failing even that — every screen has a way in, and none is marked —
    ///    one screen stands in for the root; see `anchor`.
    static func openings(
        nodes: [ExploreScreenNode],
        incoming: [String: [String]],
        outgoing: [String: [String]]
    ) -> [String] {
        let marked = nodes.filter { $0.entryPoint == true }.map(\.id)
        if !marked.isEmpty {
            return rootmost(marked, among: nodes, incoming: incoming, outgoing: outgoing)
        }
        let shallowest = nodes.map(\.depth).min() ?? 0
        let unentered = nodes
            .filter { (incoming[$0.id] ?? []).isEmpty && $0.depth == shallowest }
            .map(\.id)
        if !unentered.isEmpty { return unentered }
        return [anchor(among: nodes, incoming: incoming, outgoing: outgoing)].compactMap { $0 }
    }

    /// Of the openings the store marks, the ones a better root does not lead
    /// to — where measuring the map has to start.
    ///
    /// A screen is an opening *and* a tap's destination more often than not: a
    /// pass relaunches onto a screen already charted three taps in and marks
    /// it, because a landing is what the mark records. Measuring from every
    /// mark handed such a screen level zero, and then nothing descended into it
    /// — every arrow into it left the drawn map, the fork that fed them stopped
    /// offering two ways forward, and the feature behind it stopped being
    /// offered at all. Marks only ever accumulate, so the map came apart a
    /// little further with every pass; once every screen carried one the map
    /// drew nothing.
    ///
    /// So the marks stay the facts they are and only the measuring is picky: a
    /// marked screen a better root reaches keeps its real distance, and the
    /// arrows into it stay drawn. Dropping it as a starting point costs the map
    /// nothing — whatever hangs off it is reached through the root above it
    /// just the same.
    ///
    /// Better by `rootOrder`, and not by who reaches whom, because reach alone
    /// cannot answer this. Openings reach each other constantly: in an app with
    /// a tab bar every screen reaches every other, and even in a plain map the
    /// screen a relaunch landed on has a way home, so "reachable from another
    /// opening" is true of the launch screen too and peeling by it emptied the
    /// map from the wrong end. Rank is a total order, so the best-ranked
    /// opening is always kept and the map is never measured from nowhere.
    static func rootmost(
        _ marked: [String],
        among nodes: [ExploreScreenNode],
        incoming: [String: [String]],
        outgoing: [String: [String]]
    ) -> [String] {
        guard marked.count > 1 else { return marked }
        let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let bestFirst = marked.compactMap { byId[$0] }.sorted {
            rootOrder($0, incoming: incoming, outgoing: outgoing)
                < rootOrder($1, incoming: incoming, outgoing: outgoing)
        }
        var kept: Set<String> = []
        var better: Set<String> = []
        for candidate in bestFirst {
            if better.isEmpty || !leadsTo(candidate.id, from: better, incoming: incoming) {
                kept.insert(candidate.id)
            }
            // Dropped or kept, it still stands between a worse opening and the
            // root: whatever reaches it reaches everything behind it.
            better.insert(candidate.id)
        }
        // Map order, not the order they were judged in: the sources travel on
        // to the reader, and a map reads best in the order it lists its screens.
        return marked.filter { kept.contains($0) }
    }

    /// Whether any of `sources` reaches `target` over the recorded
    /// transitions. Walked backwards from the target, so the first opening
    /// found upstream ends the search instead of the whole map being toured.
    static func leadsTo(_ target: String, from sources: Set<String>, incoming: [String: [String]]) -> Bool {
        var visited: Set<String> = [target]
        var queue = [target]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for previous in incoming[current] ?? [] where visited.insert(previous).inserted {
                if sources.contains(previous) { return true }
                queue.append(previous)
            }
        }
        return false
    }

    /// The screen a map — or a piece of one with no entrance of its own —
    /// hangs on when nothing recorded says which; the best candidate by
    /// `rootOrder`.
    static func anchor(
        among candidates: [ExploreScreenNode],
        incoming: [String: [String]],
        outgoing: [String: [String]]
    ) -> String? {
        candidates.min {
            rootOrder($0, incoming: incoming, outgoing: outgoing)
                < rootOrder($1, incoming: incoming, outgoing: outgoing)
        }?.id
    }

    /// How good a root a screen makes, best first: the shallowest depth the
    /// crawl wrote down, then the screen the most transitions touch, since the
    /// root of a map is its busiest screen; the id only breaks a remaining tie.
    ///
    /// Never the id on its own: an id is a prefix of the screen's structural
    /// hash, so choosing by it let one screen's markup change pick a different
    /// root — and redraw arrows and re-split features all across the map.
    static func rootOrder(
        _ node: ExploreScreenNode,
        incoming: [String: [String]],
        outgoing: [String: [String]]
    ) -> (Int, Int, String) {
        let touching = (incoming[node.id] ?? []).count + (outgoing[node.id] ?? []).count
        return (node.depth, -touching, node.id)
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

    /// A copy of the map with every node told which flows it joined — the one
    /// annotation that belongs in the store, because it is derived from the
    /// map's own shape and nothing but.
    ///
    /// Everything the crawl observed is left exactly as it wrote it — the
    /// recorded depth, and which screens a launch landed on. Both are read to
    /// measure the map, and a reading of a reading is how this went wrong
    /// twice: writing the measured distance back would leave a screen that
    /// lost its last incoming arrow holding the zero that loss handed it, and
    /// stamping this pass' choice of openings back over `entryPoint` invented
    /// openings for a store that marked none — the next read then took the
    /// invention for the crawl's own note and dropped the arrows into a screen
    /// nobody had ever launched at. `depth` and `entryPoint` in the store mean
    /// what their own docs say; what this pass makes of them stops here.
    ///
    /// A copy, deliberately: the crawler's own node array carries discovery
    /// bookkeeping (`depth` only ever shrinks, and the published edge set is
    /// derived from it), so annotating in place would rewrite state a run in
    /// flight still depends on.
    public static func annotated(_ graph: ExploreGraph) -> ExploreGraph {
        let topology = Topology(graph: graph)
        return annotated(graph, topology: topology, flows: topology.flows(), measuringDepth: false)
    }

    /// The annotated map and its named flows from one pass over the graph —
    /// what a status poll needs, and it needs it every few seconds while the
    /// crawl runs. Asking for the two separately split the map twice.
    ///
    /// This is the map as it is *shown*, so here every node carries the
    /// distance from the nearest opening — the number the canvas lays its
    /// columns out by, and the one the recorded depth cannot give (a screen a
    /// relaunch landed on keeps the depth it was found at). Computed for the
    /// answer and nowhere else: nothing written from here reaches the store.
    public static func annotatedWithGroups(
        _ graph: ExploreGraph,
        names: ExploreGroupNames
    ) -> (graph: ExploreGraph, groups: [ExploreGroup]) {
        let topology = Topology(graph: graph)
        let flows = topology.flows()
        return (
            annotated(graph, topology: topology, flows: flows, measuringDepth: true),
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
        flows: [ExploreGroup],
        measuringDepth: Bool
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
            // Distance from the nearest screen the app opens into — what the
            // canvas puts in columns. Only for a map on its way to a reader:
            // see `annotated(_:)` on why the store keeps the recorded depth.
            if measuringDepth, let reach = topology.reachDepth[node.id] { node.depth = reach }
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
        /// The screens the app opens into — see `Measure.openings`.
        private(set) var openings: [String] = []
        /// Those, plus the entrance of every piece of map they cannot reach:
        /// everything the measuring starts at — see `Measure.sources`.
        private(set) var sources: [String] = []
        /// Distance from the nearest of those, over the transitions the map
        /// draws. Every screen has one, which is what keeps a piece of map
        /// hanging off nothing from losing its features.
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
            // Measured off the recorded map, not off the drawn one: which
            // screens the app opens into is the crawl's own note, and reading
            // it back out of the arrows the drawing rule left over would make
            // an opening of every screen whose last incoming arrow it dropped.
            let measure = ExploreGrouping.measured(edges: graph.edges, nodes: graph.nodes)
            // The flows follow the map as it is drawn, not as it was recorded:
            // the store keeps every observed transition, including the hops
            // back out of a feature, and feeding those in would make one flow
            // reach into another.
            for edge in measure.descending(graph.edges)
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
            openings = measure.openings
            sources = measure.sources
            reachDepth = ExploreGrouping.depths(from: sources, outgoing: outgoing)
        }

        /// True when the map treats this screen as one the app opens into: the
        /// store marks it and no better root leads to it. The entrance of a
        /// piece of map nothing reaches is not one — it starts its own piece
        /// past the rest, which is not the same as opening the app.
        ///
        /// Not the question the store answers, either. A screen the store marks
        /// can also be one a tap reaches, and then it is measured where the taps
        /// put it, so the arrows into it stay drawn — while the mark stays the
        /// fact it was. This is a reading of that fact, and readings do not
        /// travel back into the store.
        func opensAt(_ id: String) -> Bool { openings.contains(id) }

        // MARK: flows

        /// Every flow the map offers: one per button of a fork screen, holding
        /// what lies behind that button.
        ///
        /// The map this walks is a DAG, and that is not luck: `descending`
        /// keeps a transition only when it lands on a screen with a strictly
        /// higher level, and no walk can keep climbing a single number and
        /// come back where it started. Three consequences are relied on rather
        /// than guarded against — a flow can never reach the door that opens
        /// it, a fork's button can never lead to a screen the fork itself sits
        /// behind, and every screen has dominators, because `Measure` leaves
        /// none of them unmeasured. Guarding against any of the three was code
        /// that could not run, and reading it suggested the drawn map can be
        /// shaped in ways it cannot.
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
            for fork in order where forks.contains(fork) {
                for target in targets[fork] ?? [] {
                    doors[target, default: []].append(fork)
                }
            }

            return doors.map { key, opens in
                // The flow is what lies behind its first screen: walking from
                // it can wander anywhere except back out through a screen
                // every path from the launch point crosses.
                let reach = reached(from: [key], avoiding: dominators[key] ?? [])
                let members = order.filter { reach.contains($0) }
                // Every door is a bridge and none of them a member: a flow
                // walks forward only, so it never arrives back at the screen
                // whose button opened it.
                let bridges = opens
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

        /// The screens every path from a source into `u` crosses, `u` itself
        /// aside. Computed by removal — `v` dominates `u` when taking `v` out
        /// of the map leaves `u` unreachable — because that is the exact
        /// question a flow asks: which screens can it not walk back out
        /// through.
        ///
        /// Every screen has an answer: `Measure` starts each piece of map at
        /// an entrance of its own, so a feature is never lost for hanging off
        /// a screen no opening reaches.
        func strictDominators() -> [String: Set<String>] {
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

        /// What the flow could be called, strongest first — and strongest is
        /// what the whole list order means, because everything downstream just
        /// walks it: the label a chip shows is the first candidate, and a chip
        /// whose word another one took moves to the next.
        ///
        /// Three tiers.
        ///
        /// 1. The product's own words: the labels on the buttons that open the
        ///    flow. These are never judged by anything. They are what the app
        ///    says out loud, and the vocabulary that sorts identifiers threw
        ///    away `Card`, `List`, `Banner` and `Hola Cash` — every one of
        ///    them a feature the product sells.
        /// 2. The names a developer gave things — the screens' own names, the
        ///    localization prefix the flow's screens share, the buttons'
        ///    accessibility identifiers — that read like a thing.
        /// 3. The ones that name a convention instead: a component, an id
        ///    namespace, a container. `AccountUpgradeWidgetIds-Widget` names
        ///    the button's id namespace while the screen right behind it is
        ///    called `AccountUpgradeView`, so it belongs behind it — but it
        ///    stays on offer, because an app whose buttons carry no labels
        ///    leaves nothing else, and showing it beats showing `s-c08837643e`.
        ///
        /// The key closes the list, always: it is the fallback of last resort.
        func nameCandidates(key: String, doors: [String], members: [String]) -> [String] {
            var words: [String] = []
            var names: [String] = []
            var conventions: [String] = []
            var seen = Set<String>()
            /// `spoken` marks a candidate as the app's own wording, which no
            /// identifier heuristic gets a say over.
            func add(_ value: String?, spoken: Bool = false) {
                guard let value = value?.nilIfEmpty, seen.insert(value).inserted else { return }
                if spoken { words.append(value) }
                else if ExploreEngine.isGenericName(value) { conventions.append(value) }
                else { names.append(value) }
            }
            for door in doors {
                for label in labels[Route(from: door, to: key)] ?? [] { add(label, spoken: true) }
            }
            add(titles[key])
            for member in members where member != key { add(titles[member]) }
            add(commonKeyPrefix(of: members))
            for door in doors {
                for identifier in identifiers[Route(from: door, to: key)] ?? [] { add(identifier) }
            }
            var result = words + names + conventions
            if seen.insert(key).inserted { result.append(key) }
            return result
        }

        /// The longest namespace every member has a key under — a name the
        /// localization convention proposes when the buttons' words are too
        /// generic.
        ///
        /// Every key of every member is asked, not the longest one each: a
        /// screen carries up to thirty keys, most of them shared vocabulary
        /// that belongs to no feature (`common_footer_disclaimer_long_legal_…`
        /// is longer than anything a feature names itself), and comparing only
        /// the longest key per screen let one such key wipe out the namespace
        /// the rest of the flow agreed on. A member the localization index
        /// could not place says nothing and is skipped rather than veto.
        private func commonKeyPrefix(of members: [String]) -> String? {
            var shared: Set<[String]>?
            for member in members {
                let keys = localizationKeys[member] ?? []
                guard !keys.isEmpty else { continue }
                var namespaces: Set<[String]> = []
                for key in keys {
                    let parts = key.split(separator: ExploreGrouping.separator).map(String.init)
                    for length in 1...max(parts.count, 1) { namespaces.insert(Array(parts.prefix(length))) }
                }
                shared = shared.map { $0.intersection(namespaces) } ?? namespaces
            }
            // The longest of them; between two of equal length the earlier in
            // the alphabet, so the same map always proposes the same name.
            let best = shared?.max { ($0.count, $1.joined()) < ($1.count, $0.joined()) }
            guard let best, !best.isEmpty else { return nil }
            return best.joined(separator: String(ExploreGrouping.separator))
        }
    }
}
