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

    // Every door of a flow is drawn with it as the way in, and none of them is
    // ever one of its screens: a flow only walks forward, so it cannot arrive
    // back at the screen whose button opened it.
    func testEveryDoorIsABridgeAndNoneOfThemAMember() {
        XCTAssertEqual(flow("s-spei").bridges, ["s-topup"])
        XCTAssertEqual(flow("s-between").bridges, ["s-topup", "s-methods"], "both doors lead in")
        for group in ExploreGrouping.groups(of: sampleMap()) {
            XCTAssertFalse(group.bridges.isEmpty, "\(group.key) is behind a fork button")
            XCTAssertTrue(Set(group.bridges).isDisjoint(with: Set(group.members)), group.key)
        }
    }

    func testButtonBackToAnAncestorSpawnsNoFlow() {
        // «Close» on the top-up sheet goes back to Payments: the way out of the
        // flow, not a feature of its own — and not a screen of the flow either.
        // The map never draws that arrow in the first place, which is the whole
        // reason no flow can hang off it: Payments sits nearer the opening than
        // the sheet, so the hop is the crawler coming back.
        let map = sampleMap(extraEdges: [edge("s-topup", "s-payments", "Close")])
        let drawn = ExploreGrouping.descending(map)
        XCTAssertTrue(map.edges.contains { $0.from == "s-topup" && $0.to == "s-payments" })
        XCTAssertFalse(drawn.edges.contains { $0.from == "s-topup" && $0.to == "s-payments" })

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

    // An app whose buttons carry no accessibility label leaves only their
    // identifiers to name a flow after — and those name the button's id
    // namespace, not the feature. The screen behind the door does better.
    func testAFlowBehindUnlabelledButtonsIsNamedAfterItsScreen() {
        let map = graph(
            nodes: [
                node("s-main", title: "MainScreen"),
                node("s-upgrade", title: "AccountUpgradeView"),
                node("s-benefits", title: "BenefitsScreen"),
                node("s-cards", title: "CardDetailsScreen"),
            ],
            edges: [
                identifiedEdge("s-main", "s-upgrade", "AccountUpgradeWidgetIds-Widget"),
                identifiedEdge("s-upgrade", "s-benefits", "AccountUpgradeView-BenefitsHolaCell"),
                identifiedEdge("s-main", "s-cards", "HolaCardMiniRow-CardView"),
            ]
        )
        let groups = ExploreGrouping.groups(of: map)
        XCTAssertEqual(groups.first { $0.key == "s-upgrade" }?.label, "AccountUpgradeView")
        // The identifiers stay on offer — last, where an agent can still see
        // what the map really had.
        XCTAssertEqual(groups.first { $0.key == "s-upgrade" }?.candidates.last, "s-upgrade")
        XCTAssertTrue(
            groups.first { $0.key == "s-upgrade" }?.candidates.contains("AccountUpgradeWidgetIds-Widget") == true
        )
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

    // The vocabulary that sorts a screen's identifiers is written for
    // identifiers. Asked about the word on a button it threw away `Card`,
    // `List`, `Banner` and `Hola Cash` — every one of them something the
    // product sells — and the flow behind the «Card» button showed up as
    // `TopUpByCardScreen`.
    func testTheWordOnAButtonIsNotJudgedByTheIdentifierVocabulary() {
        XCTAssertEqual(flow("s-card").label, "Card")

        let map = graph(
            nodes: [
                node("s-main", title: "MainScreen", depth: 0, entryPoint: true),
                node("s-cash", title: "HolaCashLandingScreen", depth: 1),
                node("s-cash-details", title: "CashDetailsScreen", depth: 2),
                node("s-list", title: "TransactionListScreen", depth: 1),
                node("s-list-item", title: "TransactionScreen", depth: 2),
            ],
            edges: [
                edge("s-main", "s-cash", "Hola Cash"),
                edge("s-cash", "s-cash-details", "How it works"),
                edge("s-main", "s-list", "List"),
                edge("s-list", "s-list-item", "Open"),
            ]
        )
        let groups = ExploreGrouping.groups(of: map)
        XCTAssertEqual(groups.first { $0.key == "s-cash" }?.label, "Hola Cash")
        XCTAssertEqual(groups.first { $0.key == "s-list" }?.label, "List")
    }

    // Two hubs' buttons can carry the same word, and then a chip has to move
    // on to the next candidate. Moving on must not mean moving down: the
    // replacement used to be picked with no regard for what it reads like, so
    // two flows that shared a word ended up named after the id namespaces of
    // the buttons that open them.
    func testAChipThatMovesOffASharedWordDoesNotLandOnAComponentName() {
        // Both top-up sheets are the same design-system sheet, so both flows
        // open at a screen whose name says only that. The screen a step later
        // is what tells them apart.
        let map = graph(
            nodes: [
                node("s-main", title: "MainScreen", depth: 0, entryPoint: true),
                node("s-payments", title: "PaymentsScreen", depth: 1),
                node("s-invest", title: "InvestScreen", depth: 1),
                node("s-pay-topup", title: "HolaBottomSheet", depth: 2),
                node("s-pay-amount", title: "PayAmountScreen", depth: 3),
                node("s-pay-history", title: "PayHistoryScreen", depth: 2),
                node("s-inv-topup", title: "HolaBottomSheet", depth: 2),
                node("s-inv-amount", title: "InvestAmountScreen", depth: 3),
                node("s-inv-history", title: "InvestHistoryScreen", depth: 2),
            ],
            edges: [
                edge("s-main", "s-payments", "Pay"),
                edge("s-main", "s-invest", "Invest"),
                edge("s-payments", "s-pay-topup", "Deposit"),
                edge("s-payments", "s-pay-history", "History"),
                edge("s-pay-topup", "s-pay-amount", "Continue"),
                edge("s-invest", "s-inv-topup", "Deposit"),
                edge("s-invest", "s-inv-history", "History"),
                edge("s-inv-topup", "s-inv-amount", "Continue"),
            ]
        )
        // Through the named path: the labels a panel shows are the ones that
        // have been walked apart from each other.
        let groups = ExploreGrouping.groups(of: map, names: ExploreGroupNames())
        XCTAssertEqual(groups.first { $0.key == "s-pay-topup" }?.label, "PayAmountScreen")
        XCTAssertEqual(groups.first { $0.key == "s-inv-topup" }?.label, "InvestAmountScreen")
        // The component's name stays on offer, behind everything that reads
        // like a thing: an app whose screens are all design-system templates
        // has nothing else.
        XCTAssertEqual(
            groups.first { $0.key == "s-pay-topup" }?.candidates,
            ["Deposit", "PayAmountScreen", "HolaBottomSheet", "s-pay-topup"]
        )
    }

    // A screen carries up to thirty localization keys, most of them shared
    // vocabulary that belongs to no feature. Comparing only the longest key of
    // each screen let one such key — `common_footer_disclaimer_long_legal_text`
    // is longer than anything a feature names itself — wipe out the namespace
    // the rest of the flow agreed on.
    func testTheSharedNamespaceSurvivesALongerKeyThatBelongsToNobody() {
        let map = graph(
            nodes: [
                node("s-main", title: "MainScreen", depth: 0, entryPoint: true),
                node("s-bills", title: "Screen", keys: ["billing_invoices_category_title"], depth: 1),
                node(
                    "s-reference",
                    title: "Screen",
                    keys: ["common_footer_disclaimer_long_legal_text", "billing_invoices_reference_title"],
                    depth: 2
                ),
                node("s-profile", title: "Screen", keys: ["profile_menu_title"], depth: 1),
            ],
            edges: [
                identifiedEdge("s-main", "s-bills", "MainScreenIds-BillsCell"),
                identifiedEdge("s-bills", "s-reference", "BillsScreenIds-Cell"),
                identifiedEdge("s-main", "s-profile", "MainScreenIds-ProfileCell"),
            ]
        )
        let bills = ExploreGrouping.groups(of: map).first { $0.key == "s-bills" }
        XCTAssertEqual(bills?.candidates.first, "billing_invoices")
        XCTAssertEqual(bills?.label, "billing_invoices")
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

    // A piece of map no opening reaches — screens a relaunch recorded before
    // the crawl found the way in. It is still a map: its transitions are drawn
    // among themselves, measured from its own entrance, and its fork still
    // offers what lies behind its buttons. Left on the recorded depth those
    // screens shared, all three arrows went missing and the tab showed three
    // cards with nothing between them.
    func testAPieceOfMapNoOpeningReachesKeepsItsArrows() {
        let map = sampleMap(
            extraNodes: [node("s-x", depth: 5), node("s-y", depth: 5), node("s-z", depth: 5)],
            extraEdges: [
                edge("s-x", "s-y", "Swap"),
                edge("s-y", "s-x", "Swap back"),
                edge("s-x", "s-z", "Aside"),
            ]
        )
        let drawn = ExploreGrouping.descending(map)
        XCTAssertTrue(drawn.edges.contains { $0.from == "s-x" && $0.to == "s-y" })
        XCTAssertTrue(drawn.edges.contains { $0.from == "s-x" && $0.to == "s-z" })
        XCTAssertFalse(
            drawn.edges.contains { $0.from == "s-y" && $0.to == "s-x" },
            "the hop that closes a cycle is the way back, the same as anywhere else on the map"
        )
    }

    func testAPieceOfMapNoOpeningReachesNeitherJoinsNorBreaksTheAppsFlows() {
        let island: [String] = ["s-x", "s-y", "s-z"]
        let map = sampleMap(
            extraNodes: island.map { node($0, depth: 5) },
            extraEdges: [
                edge("s-x", "s-y", "Swap"),
                edge("s-y", "s-x", "Swap back"),
                edge("s-x", "s-z", "Aside"),
            ]
        )
        let groups = ExploreGrouping.groups(of: map)
        // Its own fork offers its own flows — nothing hanging off the app's
        // openings gains or loses a screen because of it.
        for group in groups {
            let touched = Set([group.key] + group.members + group.bridges)
            XCTAssertTrue(
                touched.isSubset(of: Set(island)) || touched.isDisjoint(with: Set(island)),
                "\(group.key) mixes the island into the app's features"
            )
        }
        let withoutIsland = ExploreGrouping.groups(of: sampleMap())
        XCTAssertEqual(
            groups.filter { Set($0.members).isDisjoint(with: Set(island)) }.map(\.key),
            withoutIsland.map(\.key)
        )
        XCTAssertEqual(
            groups.filter { !Set($0.members).isDisjoint(with: Set(island)) }.map(\.key).sorted(),
            ["s-y", "s-z"],
            "what lies behind the island's own fork buttons"
        )
    }

    // MARK: entry points

    func testScreenWithNoIncomingTransitionIsAnEntryPointAndMeasuredFromItself() {
        let topology = ExploreGrouping.Topology(graph: sampleMap())

        // `s-survey` was recorded after a relaunch: no tap leads to it, so it
        // is an opening of its own and everything is measured from there.
        XCTAssertTrue(topology.opensAt("s-survey"))
        XCTAssertEqual(topology.reachDepth["s-survey"], 0)
        XCTAssertTrue(topology.opensAt("s-main"))
        XCTAssertEqual(topology.reachDepth["s-main"], 0)
        XCTAssertEqual(topology.reachDepth["s-payments"], 1)
        XCTAssertEqual(topology.reachDepth["s-spei"], 3)
    }

    // A pass that relaunches onto a screen the map already carries marks it —
    // that is what the mark records, and the mark is the map's only signal in
    // an app where every screen has a way home. It must cost the map nothing:
    // measured from every mark, such a screen sat at level zero, no transition
    // could descend into it, and the fork feeding it stopped being a fork —
    // taking the feature behind it off the panel with no stale flag and no way
    // to notice. Marks only ever accumulate, so it got worse every pass.
    func testALandingOnAChartedScreenCostsTheMapNothing() {
        let baseline = drawing(of: sampleMap())
        for landing in sampleMap().nodes.map(\.id) {
            let map = marking([landing], in: sampleMap())
            XCTAssertEqual(drawing(of: map), baseline, "a pass landed on \(landing)")
            // The mark is still the fact the crawl recorded — it is only not
            // where this map is measured from.
            XCTAssertEqual(map.nodes.first { $0.id == landing }?.entryPoint, true)
        }
    }

    // The end state of that accumulation, and of the writer that used to stamp
    // its own reading back into the file: every screen marked. The map drew
    // nothing at all and offered no features — an empty canvas over a store
    // that held the whole app.
    func testAMapWhereEveryScreenIsMarkedStillDrawsItself() {
        let map = marking(sampleMap().nodes.map(\.id), in: sampleMap())
        XCTAssertEqual(drawing(of: map), drawing(of: sampleMap()))
    }

    // Which of two openings that reach each other the map hangs on is decided
    // by the depth the crawl recorded — and that is why a landing must not
    // flatten it (`ExploreController.settledDepth`). Here the app opens at
    // `s-home` and a later pass relaunched onto the hub one tap in: the hub is
    // the busier screen, so with its depth flattened to zero it wins the tie
    // and the map is measured from it — the arrow from the launch screen into
    // the hub then climbs instead of descending and is not drawn at all.
    func testTheRecordedDepthDecidesWhichOfTwoOpeningsTheMapHangsOn() {
        func map(hubDepth: Int) -> ExploreGraph {
            graph(
                nodes: [
                    node("s-home", depth: 0, entryPoint: true),
                    node("s-hub", depth: hubDepth, entryPoint: true),
                    node("s-x", depth: hubDepth + 1),
                    node("s-y", depth: hubDepth + 1),
                    node("s-z", depth: hubDepth + 1),
                ],
                edges: [
                    edge("s-home", "s-hub", "Hub"),
                    edge("s-hub", "s-x", "X"),
                    edge("s-hub", "s-y", "Y"),
                    edge("s-hub", "s-z", "Z"),
                    edge("s-hub", "s-home", "Inicio"),
                ]
            )
        }
        let recorded = ExploreGrouping.Topology(graph: map(hubDepth: 1))
        XCTAssertEqual(recorded.openings, ["s-home"])
        XCTAssertTrue(
            ExploreGrouping.descending(map(hubDepth: 1)).edges.contains { $0.from == "s-home" && $0.to == "s-hub" }
        )

        let flattened = ExploreGrouping.Topology(graph: map(hubDepth: 0))
        XCTAssertEqual(flattened.openings, ["s-hub"], "the busier screen takes the tie a depth of 0 gave it")
        XCTAssertFalse(
            ExploreGrouping.descending(map(hubDepth: 0)).edges.contains { $0.from == "s-home" && $0.to == "s-hub" }
        )
    }

    func testTheOrderScreensWereRecordedInDoesNotChangeTheMap() {
        // `s-survey` carries no incoming transition and nothing hangs off it;
        // recording it first must not turn it into the screen the map hangs on.
        let map = sampleMap()
        let reordered = ExploreGraph(
            schemaVersion: map.schemaVersion,
            run: map.run,
            stats: map.stats,
            nodes: [map.nodes.first { $0.id == "s-survey" }!] + map.nodes.filter { $0.id != "s-survey" },
            edges: map.edges
        )
        let topology = ExploreGrouping.Topology(graph: reordered)
        XCTAssertEqual(topology.reachDepth["s-payments"], 1)
        XCTAssertEqual(topology.reachDepth["s-spei"], 3)
        XCTAssertEqual(
            Set(ExploreGrouping.groups(of: reordered).map(\.key)),
            Set(ExploreGrouping.groups(of: map).map(\.key))
        )
    }

    // A screen the crawl met only after a relaunch and never reached by a tap
    // carries no incoming transition. Standing that in for an opening let it
    // measure the map from itself: one transition out of it was enough to stop
    // the real arrows into its neighbours from descending, and the feature
    // behind one of them vanished — chip, recorded name and all, without so
    // much as a stale flag. The recorded depth is what tells the two apart.
    func testAScreenRecordedDeepInTheMapIsNoOpeningEvenWithNoWayIn() {
        let map = sampleMap(
            extraNodes: [node("s-promo", title: "PromoScreen", depth: 3)],
            extraEdges: [edge("s-promo", "s-cash", "Deposit")]
        )
        XCTAssertFalse(ExploreGrouping.Topology(graph: map).opensAt("s-promo"))

        let drawn = ExploreGrouping.descending(map)
        XCTAssertTrue(drawn.edges.contains { $0.from == "s-topup" && $0.to == "s-cash" })
        XCTAssertTrue(drawn.edges.contains { $0.from == "s-cash" && $0.to == "s-stores" })
        XCTAssertFalse(
            drawn.edges.contains { $0.from == "s-promo" },
            "a screen the openings cannot reach may not pose as a descent into the map"
        )

        let groups = ExploreGrouping.groups(of: map)
        XCTAssertEqual(groups.first { $0.key == "s-cash" }?.members, ["s-cash", "s-stores"])
        XCTAssertEqual(
            groups.first { $0.key == "s-topup" }?.members,
            ExploreGrouping.groups(of: sampleMap()).first { $0.key == "s-topup" }?.members
        )

        // The same holds in a map that marks no openings at all — one written
        // before they were marked, or by hand. The recorded depth still tells a
        // screen three taps in from one the app opens at.
        let unmarked = withoutOpenings(map)
        XCTAssertFalse(ExploreGrouping.Topology(graph: unmarked).opensAt("s-promo"))
        XCTAssertTrue(
            ExploreGrouping.descending(unmarked).edges.contains { $0.from == "s-topup" && $0.to == "s-cash" }
        )
        XCTAssertEqual(
            ExploreGrouping.groups(of: unmarked).first { $0.key == "s-cash" }?.members,
            ["s-cash", "s-stores"]
        )
    }

    // Every screen of an app with a tab bar has a way home, so no screen is
    // left without an incoming transition and the map's shape says nothing
    // about where it opens. What the crawl recorded still does.
    func testAWayHomeFromEveryScreenDoesNotCostTheMapItsOpening() {
        let map = sampleMap(extraEdges: homeEdges())
        let topology = ExploreGrouping.Topology(graph: map)

        XCTAssertTrue(topology.opensAt("s-main"))
        XCTAssertEqual(topology.reachDepth["s-payments"], 1)
        XCTAssertEqual(topology.reachDepth["s-spei"], 3)
        XCTAssertEqual(
            Set(ExploreGrouping.groups(of: map).map(\.key)),
            Set(ExploreGrouping.groups(of: sampleMap()).map(\.key)),
            "a way home from every screen does not re-split the features"
        )
        let drawn = ExploreGrouping.descending(map)
        XCTAssertFalse(drawn.edges.contains { $0.to == "s-main" && $0.from != "s-main" })
        XCTAssertTrue(drawn.edges.contains { $0.from == "s-cash" && $0.to == "s-stores" })
    }

    // A map that records no opening at all — hand-authored, or written before
    // openings were marked — still needs one screen to hang on. It must not be
    // chosen by id: an id is a prefix of the screen's structural hash, so one
    // screen's markup changing picked a different root, redrew the arrows and
    // re-split the features.
    func testTheStandInRootDoesNotDependOnScreenIds() {
        let map = tabBarMap(opening: false)
        let renamed = renaming("s-cards", to: "s-0000000000", in: map)

        XCTAssertEqual(
            ExploreGrouping.Topology(graph: map).sources,
            ["s-home"],
            "the shallowest screen the crawl recorded, not the first id in the map"
        )
        XCTAssertEqual(ExploreGrouping.Topology(graph: renamed).sources, ["s-home"])
        XCTAssertEqual(
            Set(ExploreGrouping.descending(renamed).edges.map { "\($0.from)→\($0.to)" }),
            Set(["s-home→s-0000000000", "s-0000000000→s-limits", "s-home→s-pay",
                 "s-pay→s-amount", "s-home→s-invest", "s-invest→s-detail", "s-home→s-alert"])
        )
        XCTAssertEqual(
            Set(ExploreGrouping.groups(of: renamed).map(\.key)),
            ["s-0000000000", "s-pay", "s-invest", "s-alert"]
        )
        // The map is measured from the stand-in — that is what standing in is —
        // but the reading stops there. Written back as the crawl's note, the
        // next read would take this pass' guess for a screen the app opens at.
        XCTAssertTrue(ExploreGrouping.Topology(graph: map).opensAt("s-home"))
        XCTAssertNil(ExploreGrouping.annotated(map).nodes.first { $0.id == "s-home" }?.entryPoint)
    }

    func testAnAppWithATabBarStillOffersItsFeatures() {
        for opening in [true, false] {
            let map = tabBarMap(opening: opening)
            XCTAssertEqual(
                Set(ExploreGrouping.groups(of: map).filter(\.displayable).map(\.key)),
                ["s-cards", "s-pay", "s-invest"],
                "recorded opening: \(opening)"
            )
        }
    }

    // MARK: tab bars

    // The tab bar is the app's own top level: its items sit side by side, so
    // every one of them opens a root of the map. Measured from the home screen
    // alone, four fifths of the app hung off it as if the user had walked
    // there from home — the invest tab three columns in behind a home widget,
    // the chat tab behind whatever screen happened to reach it first.
    func testEveryTabOfTheTabBarIsARootOfItsOwn() {
        let shown = ExploreGrouping.annotatedWithGroups(tabRootMap(), names: ExploreGroupNames()).graph
        func depth(_ id: String) -> Int? { shown.nodes.first { $0.id == id }?.depth }

        for tab in ["s-home", "s-pay", "s-invest", "s-invite"] {
            XCTAssertEqual(depth(tab), 0, tab)
        }
        // And each of them measures its own feature from itself, rather than
        // from the tab the crawl happened to launch into.
        XCTAssertEqual(depth("s-amount"), 1)
        XCTAssertEqual(depth("s-detail"), 1)
        XCTAssertEqual(depth("s-cards"), 1)
    }

    // Every screen carrying the tab bar leads to every tab, so a root chosen by
    // reach would keep one tab and peel the rest. The tab bar says otherwise,
    // and it is the app talking.
    func testATabsLandingIsNoLessARootForBeingReachableFromAnotherTab() {
        let map = tabRootMap(extraEdges: [edge("s-amount", "s-invest", "Invertir")])
        let shown = ExploreGrouping.annotatedWithGroups(map, names: ExploreGroupNames()).graph
        XCTAssertEqual(shown.nodes.first { $0.id == "s-invest" }?.depth, 0)
    }

    // The cost of the rule, kept where it can be read: an arrow into a tab's
    // landing from elsewhere in the app is no longer drawn — a widget on the
    // home screen opening the same investment screen the invest tab shows. The
    // store keeps the transition; the map draws five roots instead of one tree.
    func testAWidgetOpeningATabsLandingStaysInTheStoreButIsNotDrawn() {
        let map = tabRootMap(extraEdges: [edge("s-home", "s-invest", "PortfolioWidget")])
        let drawn = ExploreGrouping.descending(map)

        XCTAssertTrue(map.edges.contains { $0.from == "s-home" && $0.to == "s-invest" })
        XCTAssertFalse(drawn.edges.contains { $0.from == "s-home" && $0.to == "s-invest" })
        XCTAssertEqual(drawn.stats.transitions, drawn.edges.count)
    }

    // A tab bar the app builds out of its own buttons carries no subrole, and
    // then nothing at the accessibility layer says these screens are roots —
    // the map is the one it always was. What the reading may not do is invent
    // the mark: that is how a store where every screen is an opening drew
    // nothing at all.
    func testAMapWithNoTabTransitionsIsMeasuredExactlyAsBefore() {
        let plain = untabbing(tabRootMap())
        let shown = ExploreGrouping.annotatedWithGroups(plain, names: ExploreGroupNames()).graph
        func depth(_ id: String) -> Int? { shown.nodes.first { $0.id == id }?.depth }

        XCTAssertEqual(depth("s-home"), 0)
        for tab in ["s-pay", "s-invest", "s-invite"] {
            XCTAssertEqual(depth(tab), 1, tab)
        }
        XCTAssertEqual(ExploreGrouping.tabRoots(edges: plain.edges, nodes: plain.nodes), [])
    }

    // One tab, one root. Tapped mid-flow, the home tab came back to the flow's
    // own screen instead of home — and that screen, three taps deep, stood in
    // the map as a root beside the real ones.
    func testATabThatLandsSomewhereElseOnceStillOwnsOneRoot() {
        let map = tabRootMap(
            extraNodes: [node("s-form", title: "ApplicationFormScreen", depth: 3)],
            extraEdges: [tabEdge("s-detail", "s-form", "platform_tabbar_main")]
        )
        let shown = ExploreGrouping.annotatedWithGroups(map, names: ExploreGroupNames()).graph
        func depth(_ id: String) -> Int? { shown.nodes.first { $0.id == id }?.depth }

        XCTAssertEqual(depth("s-home"), 0, "the shallowest landing of the home tab stays its root")
        XCTAssertNotEqual(depth("s-form"), 0, "the screen it came back to once is no root")
        XCTAssertTrue(
            ExploreGrouping.descending(map).edges.contains { $0.from == "s-detail" && $0.to == "s-form" },
            "and the tap that reached it is drawn as the arrow it is"
        )
    }

    // The drawn map has no arrow into a tab's landing — it is an opening, and
    // nothing descends into one — so the canvas has nowhere to learn that this
    // screen is what «invest» opens. The shown map tells it outright; the store
    // keeps the transitions and needs no copy of their names.
    func testTheShownMapTellsEachScreenWhichTabOpensIt() {
        let map = tabRootMap()
        let shown = ExploreGrouping.annotatedWithGroups(map, names: ExploreGroupNames()).graph
        func tabs(_ id: String) -> [String]? { shown.nodes.first { $0.id == id }?.tabKeys }

        XCTAssertEqual(tabs("s-pay"), ["platform_tabbar_payments"])
        XCTAssertEqual(tabs("s-home"), ["platform_tabbar_main"])
        XCTAssertNil(tabs("s-amount"), "a screen no tab opens claims no tab")

        // And the landing the map refused as a root does not go on claiming the
        // tab's name either: one source answers both questions.
        let withStray = tabRootMap(
            extraNodes: [node("s-form", title: "ApplicationFormScreen", depth: 3)],
            extraEdges: [tabEdge("s-detail", "s-form", "platform_tabbar_main")]
        )
        let strayShown = ExploreGrouping.annotatedWithGroups(withStray, names: ExploreGroupNames()).graph
        XCTAssertNil(
            strayShown.nodes.first { $0.id == "s-form" }?.tabKeys,
            "the home tab's root is the home screen, not the form it came back to once"
        )
        XCTAssertEqual(strayShown.nodes.first { $0.id == "s-home" }?.tabKeys, ["platform_tabbar_main"])
        XCTAssertTrue(
            ExploreGrouping.annotated(map).nodes.allSatisfy { $0.tabKeys == nil },
            "and the store carries the transitions, not a second copy of their names"
        )
    }

    // Marks accumulate: pass after pass lands on screens the map already holds,
    // and every one of them is written down. A map where the tabs *and* every
    // screen behind them are marked must still draw itself.
    func testAMapWhereEveryScreenIsMarkedStillDrawsItsTabs() {
        let map = marking(tabRootMap().nodes.map(\.id), in: tabRootMap())
        let shown = ExploreGrouping.annotatedWithGroups(map, names: ExploreGroupNames()).graph

        XCTAssertFalse(ExploreGrouping.descending(map).edges.isEmpty, "a map that draws nothing is the bug")
        for tab in ["s-home", "s-pay", "s-invest", "s-invite"] {
            XCTAssertEqual(shown.nodes.first { $0.id == tab }?.depth, 0, tab)
        }
    }

    // MARK: what is stored vs what is drawn

    func testATransitionOntoAShallowerScreenStaysInTheStoreButIsNotDrawn() {
        // The crawl tapped its way from the store list back up to the hub. The
        // fact belongs in the store; the arrow would only tangle the map.
        let map = sampleMap(extraEdges: [edge("s-stores", "s-payments", "Home")])
        let drawn = ExploreGrouping.descending(map)

        XCTAssertTrue(map.edges.contains { $0.from == "s-stores" && $0.to == "s-payments" })
        XCTAssertFalse(drawn.edges.contains { $0.from == "s-stores" && $0.to == "s-payments" })
        XCTAssertEqual(drawn.stats.transitions, drawn.edges.count)
    }

    func testAScreenEnteredTwiceKeepsTheArrowsThatLeadToIt() {
        // A relaunch landed on a charted screen, so the store carries it with
        // depth 0 — the crawl's note that a pass opened there. That must not
        // cost the screen the transitions leading into it: measuring from the
        // recorded transitions rather than from that zero is what keeps them.
        let map = sampleMap()
        let flattened = ExploreGraph(
            schemaVersion: map.schemaVersion,
            run: map.run,
            stats: map.stats,
            nodes: map.nodes.map { node in
                guard node.id == "s-cash" else { return node }
                var node = node
                node.depth = 0
                return node
            },
            edges: map.edges
        )
        let drawn = ExploreGrouping.descending(flattened)
        XCTAssertTrue(drawn.edges.contains { $0.from == "s-topup" && $0.to == "s-cash" })
        XCTAssertTrue(drawn.edges.contains { $0.from == "s-cash" && $0.to == "s-stores" })
        XCTAssertFalse(ExploreGrouping.Topology(graph: flattened).opensAt("s-cash"))
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
    }

    // What goes into the store is the crawl's own record, untouched: how deep
    // it walked, and which screens it launched at. The map is measured from
    // both, so writing either one back would make the drawing rule read its own
    // output — a screen the openings cannot reach was handed a zero, the next
    // pass took the zero for a screen the app launches into, and a relaunch
    // artifact came to measure the whole map and cost it real arrows.
    //
    // Both directions of the mark matter. A store that marks nothing must not
    // come back marked, and a store that marks a screen must not come back
    // without it: the mark is the only signal that survives an app where every
    // screen has a way home.
    func testTheStoreKeepsWhatTheCrawlRecorded() {
        let map = sampleMap(
            extraNodes: [node("s-promo", title: "PromoScreen", depth: 3)],
            extraEdges: [edge("s-promo", "s-cash", "Deposit")]
        )
        let stored = ExploreGrouping.annotated(map)

        XCTAssertEqual(stored.nodes.map(\.depth), map.nodes.map(\.depth))
        XCTAssertEqual(stored.nodes.first { $0.id == "s-promo" }?.depth, 3)
        XCTAssertEqual(stored.nodes.map(\.entryPoint), map.nodes.map(\.entryPoint))
        XCTAssertNil(stored.nodes.first { $0.id == "s-promo" }?.entryPoint)
        XCTAssertEqual(stored.nodes.first { $0.id == "s-main" }?.entryPoint, true)
        XCTAssertEqual(
            ExploreGrouping.annotated(withoutOpenings(map)).nodes.compactMap { $0.entryPoint == true ? $0.id : nil },
            [],
            "a map that marks nothing must not come back marked"
        )
        // A landing marked on a screen a tap also reaches survives the trip
        // too, and still costs the file nothing.
        let landed = marking(["s-cash"], in: map)
        XCTAssertEqual(
            ExploreGrouping.annotated(landed).nodes.first { $0.id == "s-cash" }?.entryPoint,
            true
        )

        // Read the store back and the map is the same map, arrow for arrow and
        // feature for feature — which is what "never reads its own output"
        // buys.
        XCTAssertEqual(
            ExploreGrouping.descending(stored).edges.map { "\($0.from)→\($0.to)" },
            ExploreGrouping.descending(map).edges.map { "\($0.from)→\($0.to)" }
        )
        XCTAssertEqual(
            ExploreGrouping.groups(of: stored).map { "\($0.key):\($0.members.joined(separator: ","))" },
            ExploreGrouping.groups(of: map).map { "\($0.key):\($0.members.joined(separator: ","))" }
        )
    }

    // The map on its way to the tab is the one that carries measured depths:
    // the canvas lays its columns out by them, and a screen a relaunch landed
    // on keeps a recorded depth that describes no path anyone can walk.
    func testTheMapTheTabSeesCarriesTheMeasuredDepth() {
        let map = sampleMap(
            extraNodes: [node("s-promo", title: "PromoScreen", depth: 3)],
            extraEdges: [edge("s-promo", "s-cash", "Deposit")]
        )
        let shown = ExploreGrouping.annotatedWithGroups(map, names: ExploreGroupNames()).graph
        func depth(_ id: String) -> Int? { shown.nodes.first { $0.id == id }?.depth }

        XCTAssertEqual(depth("s-main"), 0)
        XCTAssertEqual(depth("s-spei"), 3)
        XCTAssertEqual(depth("s-promo"), 0, "the piece of map it starts opens flush left")
        XCTAssertEqual(depth("s-cash"), 3, "and does not pull the screen it leads to up to itself")
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

        // And the same map after a store has been running long enough for every
        // screen to have been landed on: the openings are sifted one against
        // another, which is a walk per mark, so a map where everything is marked
        // is where that costs the most.
        let marked = marking(map.nodes.map(\.id), in: map)
        let markedStarted = Date()
        let markedGroups = ExploreGrouping.groups(of: ExploreGrouping.annotated(marked))
        let markedElapsed = Date().timeIntervalSince(markedStarted)

        XCTAssertEqual(markedGroups.count, 40, "and the features are the same features")
        XCTAssertLessThan(markedElapsed, 1.0, "grouping 401 marked screens took \(markedElapsed)s")
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
    /// Recorded the way a crawl records: every screen carries the depth it was
    /// found at, and the two screens a pass launched into are marked as
    /// openings.
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
                node("s-main", title: "MainScreen", depth: 0, entryPoint: true),
                node("s-payments", title: "MainPaymentsScreen", depth: 1),
                node("s-topup", title: "TopUpBottomSheet", depth: 2),
                node("s-spei", title: "SpeiInScreen", keys: ["payments_spei_in_details_subtitle"], depth: 3),
                node("s-cash", title: "CashInScreen", keys: ["payments_cash_in_onboarding_title"], depth: 3),
                node("s-stores", title: "StoreListScreen", keys: ["payments_cash_in_store_list_title"], depth: 4),
                node("s-card", title: "TopUpByCardScreen", depth: 3),
                node("s-between", title: "BetweenAccountsScreen", depth: 3),
                node("s-methods", title: "TransferMethodsScreen", depth: 2),
                node("s-clabe", title: "ClabeReferenceInputScreen", depth: 3),
                node("s-phone", title: "PaymentContactList", depth: 3),
                node("s-amount", title: "AmountInputScreen", depth: 3),
                node("s-picker", title: "AccountListBottomSheet", depth: 4),
                node("s-fields", title: "AdditionalFieldsBottomSheet", depth: 4),
                node("s-bills", title: "CategoryListScreen", depth: 2),
                node("s-reference", title: "BillPayReferenceInputScreen", depth: 3),
                node("s-survey", title: "SurveyScreen", depth: 0, entryPoint: true),
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

    /// `depth` and `entryPoint` are the crawl's own record of how it met the
    /// screen — how far it had walked, and whether it launched there. The map
    /// is measured from those, so a fixture that leaves every screen at depth
    /// 0 cannot tell a screen the app opens into from one nothing leads to.
    private func node(
        _ id: String,
        title: String? = nil,
        keys: [String] = [],
        actionsTotal: Int = 1,
        actionsTried: Int = 0,
        depth: Int = 0,
        entryPoint: Bool? = nil
    ) -> ExploreScreenNode {
        var node = ExploreScreenNode(
            id: id,
            title: title ?? id,
            fingerprint: id,
            key: id,
            screenshot: "shots/\(id).png",
            depth: depth,
            visits: 1,
            states: nil,
            actionsTotal: actionsTotal,
            actionsTried: actionsTried,
            firstSeenAt: "2026-08-19T10:00:00Z",
            triedActionKeys: nil,
            deeplinks: nil,
            localizationKeys: keys.isEmpty ? nil : keys
        )
        node.entryPoint = entryPoint
        return node
    }

    /// Everything about a map that a reader can see: the arrows it draws and
    /// the features it offers, each with the screens it holds. The two answers
    /// a marked opening used to quietly take apart.
    private func drawing(of map: ExploreGraph) -> [String] {
        ExploreGrouping.descending(map).edges.map { "arrow \($0.from)→\($0.to)" }
            + ExploreGrouping.groups(of: map).filter(\.displayable).map {
                "flow \($0.key):\($0.members.joined(separator: ","))"
            }
    }

    /// The same map with more screens marked as openings — what a pass that
    /// relaunched onto them writes down.
    private func marking(_ ids: [String], in map: ExploreGraph) -> ExploreGraph {
        var copy = map
        copy.nodes = map.nodes.map { node in
            var node = node
            if ids.contains(node.id) { node.entryPoint = true }
            return node
        }
        return copy
    }

    /// The tab bar's way home from every screen of `sampleMap` — the shape
    /// that leaves no screen without an incoming transition.
    private func homeEdges() -> [ExploreTransitionEdge] {
        sampleMap().nodes
            .map(\.id)
            .filter { $0 != "s-main" }
            .map { edge($0, "s-main", "Inicio") }
    }

    /// An app with a tab bar and nothing else: three features off a home
    /// screen, and a way home from each of their screens. No screen is without
    /// an incoming transition, so the map's shape names no opening — only what
    /// the crawl recorded does, and `opening: false` takes even that away.
    ///
    /// `s-alert` is the second screen at depth 0: a pass launched into it and a
    /// later tap found the way there too, which is how two screens come to
    /// share the shallowest depth in one store. Its id sorts before the home
    /// screen's, so a map hanging on whichever id sorts first hangs on it.
    private func tabBarMap(opening: Bool) -> ExploreGraph {
        let screens = [
            ("s-home", 0), ("s-alert", 0), ("s-cards", 1), ("s-limits", 2),
            ("s-pay", 1), ("s-amount", 2), ("s-invest", 1), ("s-detail", 2),
        ]
        return graph(
            nodes: screens.map { id, depth in
                node(id, depth: depth, entryPoint: opening && id == "s-home" ? true : nil)
            },
            edges: [
                edge("s-home", "s-cards", "Cards"),
                edge("s-cards", "s-limits", "Limits"),
                edge("s-home", "s-pay", "Pay"),
                edge("s-pay", "s-amount", "Amount"),
                edge("s-home", "s-invest", "Invest"),
                edge("s-invest", "s-detail", "Details"),
                edge("s-home", "s-alert", "Что нового"),
            ] + screens.map(\.0).filter { $0 != "s-home" }.map { edge($0, "s-home", "Inicio") }
        )
    }

    /// A tab bar as the crawl really records one: the pass launched into the
    /// home tab, and from there a tap on each of the bar's items opened that
    /// tab's own screen one tap deep. The bar is on every screen, so every
    /// screen has a way back to home.
    ///
    ///     s-home ─┬(tab)─ s-pay ──── s-amount
    ///             ├(tab)─ s-invest ─ s-detail
    ///             ├(tab)─ s-invite
    ///             └────── s-cards ── s-limits
    private func tabRootMap(
        extraNodes: [ExploreScreenNode] = [],
        extraEdges: [ExploreTransitionEdge] = []
    ) -> ExploreGraph {
        graph(
            nodes: [
                node("s-home", title: "MainScreenV2View", depth: 0, entryPoint: true),
                node("s-cards", title: "CardDetailsScreen", depth: 1),
                node("s-limits", title: "CardLimitsScreen", depth: 2),
                node("s-pay", title: "MainPaymentsScreen", depth: 1),
                node("s-amount", title: "AmountInputScreen", depth: 2),
                node("s-invest", title: "InvestMainScreen", depth: 1),
                node("s-detail", title: "PortfolioDetailScreen", depth: 2),
                node("s-invite", title: "BringAFriendMainScreen", depth: 1),
            ] + extraNodes,
            edges: [
                tabEdge("s-home", "s-pay", "platform_tabbar_payments"),
                tabEdge("s-home", "s-invest", "platform_tabbar_invest"),
                tabEdge("s-home", "s-invite", "platform_tabbar_invite"),
                edge("s-home", "s-cards", "Card"),
                edge("s-cards", "s-limits", "Limits"),
                edge("s-pay", "s-amount", "Transfer"),
                edge("s-invest", "s-detail", "Portfolio"),
            ] + ["s-cards", "s-limits", "s-pay", "s-amount", "s-invest", "s-detail", "s-invite"]
                .map { tabEdge($0, "s-home", "platform_tabbar_main") }
                + extraEdges
        )
    }

    /// The same map recorded by a crawl that could not tell a tab from any
    /// other button — a tab bar the app draws itself, or a store written before
    /// tabs were told apart.
    private func untabbing(_ map: ExploreGraph) -> ExploreGraph {
        var copy = map
        copy.edges = map.edges.map { edge in
            var edge = edge
            edge.action.tab = nil
            return edge
        }
        return copy
    }

    /// The same map with nothing marked as an opening — a store written before
    /// openings were marked, or one an agent pass wrote by hand.
    private func withoutOpenings(_ map: ExploreGraph) -> ExploreGraph {
        var copy = map
        copy.nodes = map.nodes.map { node in
            var node = node
            node.entryPoint = nil
            return node
        }
        return copy
    }

    /// The same map with one screen's id changed — what a screen's markup
    /// changing does, since an id is a prefix of its structural hash.
    private func renaming(_ id: String, to replacement: String, in map: ExploreGraph) -> ExploreGraph {
        ExploreGraph(
            schemaVersion: map.schemaVersion,
            run: map.run,
            stats: map.stats,
            nodes: map.nodes.map { node in
                guard node.id == id else { return node }
                var node = node
                node.id = replacement
                return node
            },
            edges: map.edges.map { edge in
                var edge = edge
                if edge.from == id { edge.from = replacement }
                if edge.to == id { edge.to = replacement }
                return edge
            }
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

    /// A transition a tap on a tab bar's item opened — what the crawl writes
    /// down when the tapped control carries the tab subrole.
    private func tabEdge(_ from: String, _ to: String, _ identifier: String) -> ExploreTransitionEdge {
        ExploreTransitionEdge(
            id: "\(from)->\(to)-\(identifier)",
            from: from,
            to: to,
            action: ExploreTransitionAction(kind: "tap", targetId: identifier, targetLabel: nil, tab: true),
            count: 1
        )
    }

    /// A transition whose button carries no accessibility label — only an
    /// identifier, the way an unlabelled design-system control reads.
    private func identifiedEdge(_ from: String, _ to: String, _ identifier: String) -> ExploreTransitionEdge {
        ExploreTransitionEdge(
            id: "\(from)->\(to)-\(identifier)",
            from: from,
            to: to,
            action: ExploreTransitionAction(kind: "tap", targetId: identifier, targetLabel: nil),
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
