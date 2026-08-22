import XCTest
@testable import SimToolServer

final class ExploreGroupingTests: XCTestCase {
    // MARK: flows

    func testStraightCorridorOffersNoFlows() {
        let map = graph(
            nodes: [node("s-a"), node("s-b"), node("s-c")],
            edges: [edge("s-a", "s-b", "Next"), edge("s-b", "s-c", "Continue")]
        )
        XCTAssertTrue(ExploreGrouping.groups(of: map).isEmpty)
    }

    func testEveryForkButtonOpensAFlow() {
        let groups = ExploreGrouping.groups(of: sampleMap())
        XCTAssertEqual(
            Set(groups.filter { $0.level == 1 }.map(\.key)),
            ["s-topup", "s-methods", "s-bills"]
        )
        XCTAssertEqual(
            flow("s-topup").members,
            ["s-topup", "s-spei", "s-cash", "s-stores", "s-card", "s-between", "s-picker"]
        )
        XCTAssertEqual(flow("s-cash").members, ["s-cash", "s-stores"])
        XCTAssertEqual(flow("s-bills").members, ["s-bills", "s-reference"])
    }

    func testFlowOpensAtItsFirstScreen() {
        XCTAssertEqual(flow("s-cash").entry, "s-cash")
        XCTAssertEqual(flow("s-topup").entry, "s-topup")
    }

    // The hub the flows hang off — and the screen the app launches into — are
    // everything at once, which is the map, not a feature.
    func testNeitherTheRootNorALinearStepBecomesAFlow() {
        let keys = Set(ExploreGrouping.groups(of: sampleMap()).map(\.key))
        XCTAssertFalse(keys.contains("s-main"))
        XCTAssertFalse(keys.contains("s-payments"), "the only way forward from the root is not a choice")
        XCTAssertFalse(keys.contains("s-survey"), "a relaunch artifact opens nothing")
    }

    // MARK: shared screens

    func testSharedScreenJoinsEveryFlowThatReachesIt() {
        XCTAssertTrue(flow("s-topup").members.contains("s-between"))
        XCTAssertTrue(flow("s-methods").members.contains("s-between"))
        // The account picker sheet is four flows deep in the sharing.
        for key in ["s-topup", "s-methods", "s-between", "s-amount"] {
            XCTAssertTrue(flow(key).members.contains("s-picker"), key)
        }
        XCTAssertFalse(flow("s-cash").members.contains("s-picker"))
    }

    func testSharedScreenBehindTwoForksIsOneFlowWithTwoDoors() {
        let between = flow("s-between")
        XCTAssertEqual(between.members, ["s-between", "s-picker"])
        XCTAssertEqual(between.bridges, ["s-topup", "s-methods"], "both doors lead in, in map order")
    }

    // MARK: doors

    func testDoorIsDrawnAsBridgeNeverAsMember() {
        XCTAssertEqual(flow("s-spei").bridges, ["s-topup"])
        for group in ExploreGrouping.groups(of: sampleMap()) {
            XCTAssertTrue(Set(group.bridges).isDisjoint(with: Set(group.members)), group.key)
        }
    }

    func testButtonBackToAnAncestorSpawnsNoFlow() {
        // «Close» on the top-up sheet goes back to Payments: the way out of the
        // flow, not a feature of its own — and not a screen of the flow either.
        let map = sampleMap(extraEdges: [edge("s-topup", "s-payments", "Close")])
        let keys = Set(ExploreGrouping.groups(of: map).map(\.key))
        XCTAssertFalse(keys.contains("s-payments"))
        XCTAssertFalse(
            ExploreGrouping.groups(of: map).first { $0.key == "s-topup" }!.members.contains("s-payments")
        )
    }

    func testSelfLoopDoesNotMakeAScreenAFork() {
        let map = graph(
            nodes: [node("s-a"), node("s-b")],
            edges: [edge("s-a", "s-b", "Next"), edge("s-a", "s-a", "Refresh")]
        )
        XCTAssertTrue(ExploreGrouping.groups(of: map).isEmpty)
    }

    // MARK: levels

    func testFlowLevelsFollowForkNesting() {
        XCTAssertEqual(flow("s-topup").level, 1)
        XCTAssertEqual(flow("s-spei").level, 2)
        XCTAssertEqual(flow("s-between").level, 2, "a shared flow sits at the depth of its shallowest door")
        XCTAssertEqual(flow("s-fields").level, 3)
        XCTAssertEqual(flow("s-picker").level, 3)
    }

    // MARK: displayable threshold

    func testOneScreenWithSomewhereLeftToTapIsNoFlowOfItsOwn() {
        // SpeiIn is a single screen with taps nobody has made: whatever it
        // opens is not on the map yet, so there is no sequence to offer. It
        // still draws inside the top-up flow it hangs off.
        let spei = flow("s-spei")
        XCTAssertEqual(spei.members, ["s-spei"])
        XCTAssertFalse(spei.displayable)
        XCTAssertTrue(flow("s-topup").members.contains("s-spei"))
        XCTAssertTrue(flow("s-topup").displayable)
    }

    func testOneScreenFlowWithNothingLeftToOpenStaysOffered() {
        // A screen with no transition out and every tap already made is
        // finished: nothing will ever join it, so the single card is the whole
        // truth about that branch.
        let map = graph(
            nodes: [
                node("s-main"),
                node("s-left", actionsTotal: 4, actionsTried: 4),
                node("s-right"),
                node("s-deeper"),
            ],
            edges: [
                edge("s-main", "s-left", "Cards"),
                edge("s-main", "s-right", "Bills"),
                edge("s-right", "s-deeper", "Reference"),
            ]
        )
        let groups = ExploreGrouping.groups(of: map)
        XCTAssertTrue(groups.first { $0.key == "s-left" }!.displayable)
        XCTAssertTrue(groups.first { $0.key == "s-right" }!.displayable, "two screens are a sequence")
    }

    func testNoFlowIsLabelledWithARawScreenId() {
        for group in ExploreGrouping.groups(of: sampleMap()) where group.displayable {
            XCTAssertFalse(
                group.label.hasPrefix("s-"),
                "a chip reading \(group.label) names nothing a reader can recognise"
            )
        }
    }

    // MARK: name candidates

    func testTheDoorButtonWordsLeadTheCandidates() {
        XCTAssertEqual(flow("s-spei").candidates.first, "CLABE")
        XCTAssertEqual(
            Array(flow("s-between").candidates.prefix(2)),
            ["From my account", "My accounts"],
            "every door's button words are offered"
        )
    }

    func testScreenNamesAndTheSharedKeyPrefixFollowTheButtonWords() {
        let cash = flow("s-cash")
        XCTAssertTrue(cash.candidates.contains("CashInScreen"))
        XCTAssertTrue(cash.candidates.contains("StoreListScreen"))
        XCTAssertTrue(
            cash.candidates.contains("payments_cash_in"),
            "localization still proposes a name, it just no longer decides membership: \(cash.candidates)"
        )
        XCTAssertEqual(cash.candidates.last, "s-cash", "the key is the fallback of last resort")
    }

    func testCandidatesNeverRepeat() {
        for group in ExploreGrouping.groups(of: sampleMap()) {
            XCTAssertEqual(Set(group.candidates).count, group.candidates.count, group.key)
        }
    }

    // MARK: whole-map shape

    func testGroupsAreOrderedCoarseLevelFirstThenBySize() {
        let groups = ExploreGrouping.groups(of: sampleMap())
        XCTAssertEqual(groups.map(\.level), groups.map(\.level).sorted())
        let coarseSizes = groups.filter { $0.level == 1 }.map(\.members.count)
        XCTAssertEqual(coarseSizes, coarseSizes.sorted(by: >))
        XCTAssertEqual(groups.first?.key, "s-methods", "ties break by key so the order does not drift")
    }

    func testUnreachableCycleSpawnsNothingAndBreaksNothing() {
        // A cycle of screens recorded with no way in: `s-x` forks, but no entry
        // point reaches it, so its island anchors no flow and joins none.
        let map = sampleMap(
            extraNodes: [node("s-x"), node("s-y"), node("s-z")],
            extraEdges: [
                edge("s-x", "s-y", "Swap"),
                edge("s-y", "s-x", "Swap back"),
                edge("s-x", "s-z", "Aside"),
            ]
        )
        let groups = ExploreGrouping.groups(of: map)
        XCTAssertFalse(groups.contains { !Set([$0.key] + $0.members).isDisjoint(with: ["s-x", "s-y", "s-z"]) })
    }

    // MARK: entry points

    func testScreenWithNoIncomingTransitionIsAnEntryPointAndHasNoDepth() {
        let topology = ExploreGrouping.Topology(graph: sampleMap())

        XCTAssertEqual(topology.root, "s-main")
        // `s-survey` was recorded after a relaunch: no tap leads to it.
        XCTAssertTrue(topology.isEntryPoint("s-survey"))
        XCTAssertNil(topology.depth["s-survey"])
        XCTAssertEqual(topology.depth["s-payments"], 1)
        XCTAssertEqual(topology.depth["s-spei"], 3)
        // The launch screen has no incoming transition either, but its depth
        // describes a real path — the empty one.
        XCTAssertTrue(topology.isEntryPoint("s-main"))
        XCTAssertEqual(topology.depth["s-main"], 0)
    }

    func testRootIsTheScreenTheMapHangsOffNotTheFirstRecorded() {
        // `s-survey` is recorded first and carries no incoming transition, but
        // nothing hangs off it.
        let map = sampleMap()
        let reordered = ExploreGraph(
            schemaVersion: map.schemaVersion,
            run: map.run,
            stats: map.stats,
            nodes: [map.nodes.first { $0.id == "s-survey" }!] + map.nodes.filter { $0.id != "s-survey" },
            edges: map.edges
        )
        XCTAssertEqual(ExploreGrouping.Topology(graph: reordered).root, "s-main")
    }

    // MARK: annotation

    func testAnnotatedNodesCarryTheirFlows() {
        let annotated = ExploreGrouping.annotated(sampleMap())
        func groups(_ id: String) -> [String]? {
            annotated.nodes.first { $0.id == id }?.groups
        }
        XCTAssertEqual(groups("s-between"), ["s-between", "s-methods", "s-topup"])
        XCTAssertEqual(groups("s-stores"), ["s-cash", "s-topup"])
        XCTAssertNil(groups("s-main"), "the root belongs to the map, not to a feature")
        XCTAssertNil(groups("s-survey"))
        XCTAssertEqual(annotated.nodes.first { $0.id == "s-survey" }?.entryPoint, true)
        XCTAssertEqual(annotated.nodes.first { $0.id == "s-survey" }?.depth, 0)
    }

    // MARK: cost

    // The crawler rewrites the store after every step, and grouping runs on
    // each of those writes. A map far larger than any real one must still cost
    // a blink, or a long crawl pays for it once per tap.
    func testGroupingALargeMapStaysCheap() {
        var nodes: [ExploreScreenNode] = [node("s-root")]
        var edges: [ExploreTransitionEdge] = []
        for feature in 0..<40 {
            for screen in 0..<10 {
                let id = "s-f\(feature)-\(screen)"
                nodes.append(node(id, keys: ["feature\(feature)_section\(screen % 3)_title"]))
                let parent = screen == 0 ? "s-root" : "s-f\(feature)-\(screen - 1)"
                edges.append(edge(parent, id, "Step \(screen)"))
            }
        }
        let map = graph(nodes: nodes, edges: edges)
        XCTAssertEqual(map.nodes.count, 401)

        let started = Date()
        let annotated = ExploreGrouping.annotated(map)
        let groups = ExploreGrouping.groups(of: annotated)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(groups.count, 40)
        XCTAssertTrue(groups.allSatisfy { $0.level == 1 && $0.members.count == 10 })
        XCTAssertLessThan(elapsed, 1.0, "grouping 401 screens took \(elapsed)s")
    }

    // MARK: helpers

    private func flow(_ key: String, file: StaticString = #filePath, line: UInt = #line) -> ExploreGroup {
        guard let found = ExploreGrouping.groups(of: sampleMap()).first(where: { $0.key == key }) else {
            XCTFail("no flow \(key)", file: file, line: line)
            return ExploreGroup(key: key, level: 1, members: [])
        }
        return found
    }

    /// A map shaped the way a product's payments tab really is: two hubs
    /// hanging off one screen, a feature behind every hub button, two flows
    /// sharing a screen (`s-between`), a picker sheet shared even deeper
    /// (`s-picker`), and one screen recorded after a relaunch (`s-survey`).
    ///
    ///     s-main ── s-payments ─┬─ s-topup ──┬─ s-spei
    ///                           │            ├─ s-cash ── s-stores
    ///                           │            ├─ s-card
    ///                           │            └─ s-between ── s-picker
    ///                           ├─ s-methods ─┬─ s-clabe
    ///                           │             ├─ s-phone
    ///                           │             ├─ s-between
    ///                           │             └─ s-amount ─┬─ s-picker
    ///                           │                          └─ s-fields
    ///                           └─ s-bills ── s-reference
    ///     s-survey (no incoming transition)
    private func sampleMap(
        extraNodes: [ExploreScreenNode] = [],
        extraEdges: [ExploreTransitionEdge] = []
    ) -> ExploreGraph {
        graph(
            nodes: [
                node("s-main", title: "MainScreen"),
                node("s-payments", title: "MainPaymentsScreen"),
                node("s-topup", title: "TopUpBottomSheet"),
                node("s-spei", title: "SpeiInScreen", keys: ["payments_spei_in_details_subtitle"]),
                node("s-cash", title: "CashInScreen", keys: ["payments_cash_in_onboarding_title"]),
                node("s-stores", title: "StoreListScreen", keys: ["payments_cash_in_store_list_title"]),
                node("s-card", title: "TopUpByCardScreen"),
                node("s-between", title: "BetweenAccountsScreen"),
                node("s-methods", title: "TransferMethodsScreen"),
                node("s-clabe", title: "ClabeReferenceInputScreen"),
                node("s-phone", title: "PaymentContactList"),
                node("s-amount", title: "AmountInputScreen"),
                node("s-picker", title: "AccountListBottomSheet"),
                node("s-fields", title: "AdditionalFieldsBottomSheet"),
                node("s-bills", title: "CategoryListScreen"),
                node("s-reference", title: "BillPayReferenceInputScreen"),
                node("s-survey", title: "SurveyScreen"),
            ] + extraNodes,
            edges: [
                edge("s-main", "s-payments", "Pay"),
                edge("s-payments", "s-topup", "Deposit"),
                edge("s-topup", "s-spei", "CLABE"),
                edge("s-topup", "s-cash", "Cash"),
                edge("s-cash", "s-stores", "Choose store"),
                edge("s-topup", "s-card", "Card"),
                edge("s-topup", "s-between", "From my account"),
                edge("s-between", "s-picker", "From Crédito"),
                edge("s-payments", "s-methods", "Transfer"),
                edge("s-methods", "s-clabe", "CLABE"),
                edge("s-methods", "s-phone", "Phone"),
                edge("s-methods", "s-between", "My accounts"),
                edge("s-methods", "s-amount", "Recipient"),
                edge("s-amount", "s-picker", "From Cuenta"),
                edge("s-amount", "s-fields", "+ Additional fields"),
                edge("s-payments", "s-bills", "Bill payments"),
                edge("s-bills", "s-reference", "Recarga"),
            ] + extraEdges
        )
    }

    private func node(
        _ id: String,
        title: String? = nil,
        keys: [String] = [],
        actionsTotal: Int = 1,
        actionsTried: Int = 0
    ) -> ExploreScreenNode {
        ExploreScreenNode(
            id: id,
            title: title ?? id,
            fingerprint: id,
            key: id,
            screenshot: "shots/\(id).png",
            depth: 0,
            visits: 1,
            states: nil,
            actionsTotal: actionsTotal,
            actionsTried: actionsTried,
            firstSeenAt: "2026-08-19T10:00:00Z",
            triedActionKeys: nil,
            deeplinks: nil,
            localizationKeys: keys.isEmpty ? nil : keys
        )
    }

    private func edge(_ from: String, _ to: String, _ label: String?) -> ExploreTransitionEdge {
        ExploreTransitionEdge(
            id: "\(from)->\(to)-\(label ?? "")",
            from: from,
            to: to,
            action: ExploreTransitionAction(kind: "tap", targetId: nil, targetLabel: label),
            count: 1
        )
    }

    private func graph(nodes: [ExploreScreenNode], edges: [ExploreTransitionEdge]) -> ExploreGraph {
        ExploreGraph(
            schemaVersion: 2,
            run: ExploreRunMeta(
                id: "run",
                app: "com.example.app",
                device: "iPhone 17",
                profile: nil,
                startedAt: "2026-08-19T10:00:00Z",
                finishedAt: nil
            ),
            stats: ExploreStats(screens: nodes.count, transitions: edges.count, steps: 0, relaunches: 0),
            nodes: nodes,
            edges: edges
        )
    }
}
