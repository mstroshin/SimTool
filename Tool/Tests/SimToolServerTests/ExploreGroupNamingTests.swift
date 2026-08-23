import XCTest
@testable import SimToolServer
import SimToolCore

final class ExploreGroupNamingTests: XCTestCase {
    // MARK: staleness

    func testAddingOneScreenDoesNotStaleAName() {
        XCTAssertFalse(ExploreGroupNaming.isStale(recorded: ["a", "b"], current: ["a", "b", "c"]))
        XCTAssertFalse(ExploreGroupNaming.isStale(
            recorded: ["a", "b", "c", "d", "e", "f", "g", "h"],
            current: ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
        ))
    }

    func testAGroupThatIsMostlyNewScreensGoesStale() {
        XCTAssertTrue(ExploreGroupNaming.isStale(recorded: ["a", "b"], current: ["a", "x", "y", "z", "w", "v"]))
    }

    func testUnchangedMembershipIsNeverStale() {
        XCTAssertFalse(ExploreGroupNaming.isStale(recorded: ["a", "b"], current: ["b", "a"]))
    }

    // Losing nine screens out of ten changes what a name describes as much as
    // gaining nine does. Measured against the current membership alone, the
    // share only ever saw the second: a group that shrank to a single screen
    // kept its name at a serene 1.0.
    func testAGroupThatLostMostOfItsScreensGoesStale() {
        XCTAssertTrue(ExploreGroupNaming.isStale(
            recorded: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"],
            current: ["a"]
        ))
        XCTAssertFalse(
            ExploreGroupNaming.isStale(recorded: ["a", "b", "c", "d"], current: ["a", "b", "c"]),
            "one screen leaving is the map settling, not a different feature"
        )
    }

    func testANameRecordedWithoutAMembershipIsNotStale() {
        // Nothing was written down for it to have drifted from, and reporting
        // it stale asks a person to re-check a name that may be perfectly good.
        XCTAssertFalse(ExploreGroupNaming.isStale(recorded: [], current: ["a", "b"]))
    }

    // MARK: distinctness

    func testDistinctNamesPass() {
        XCTAssertEqual(ExploreGroupNaming.conflicts(in: ["a": "Bill pay", "b": "Transactions"]), [])
    }

    func testTwoGroupsMayNotShareALabel() {
        XCTAssertEqual(
            ExploreGroupNaming.conflicts(in: ["a": "Financial security", "b": "Financial security"]),
            ["a", "b"]
        )
    }

    func testCaseAndPaddingDoNotMakeANameDistinct() {
        XCTAssertEqual(ExploreGroupNaming.conflicts(in: ["a": "Bill pay", "b": "  bill PAY "]), ["a", "b"])
    }

    // A feature that shrinks to a single screen for one crawl drops off the
    // panel — and judging the clash over the flows the map shows *now* let its
    // name go unseen and be handed to a second flow. When the first came back,
    // two chips read «Депозит», and nothing outside the map could correct
    // either of them. The check has to see every name ever recorded.
    func testANameNoFlowShowsRightNowStillHoldsItsWord() {
        let recorded = ExploreGroupNames(names: [
            "s-topup": ExploreGroupName(name: "Депозит", members: ["s-topup", "s-amount"]),
            "s-portfolio": ExploreGroupName(name: " депозит ", members: ["s-portfolio", "s-buy"]),
        ])
        XCTAssertEqual(ExploreGroupNaming.conflicts(in: recorded), ["s-portfolio", "s-topup"])

        let distinct = ExploreGroupNames(names: [
            "s-topup": ExploreGroupName(name: "Депозит", members: ["s-topup"]),
            "s-portfolio": ExploreGroupName(name: "Портфель", members: ["s-portfolio"]),
        ])
        XCTAssertEqual(ExploreGroupNaming.conflicts(in: distinct), [])
    }

    // MARK: label degradation

    func testLabelPrefersTheNameThenTheCandidateThenTheKey() {
        XCTAssertEqual(
            ExploreGroupNaming.label(name: "Оплата счетов", candidates: ["Bill pay"], key: "s-bills"),
            "Оплата счетов"
        )
        XCTAssertEqual(
            ExploreGroupNaming.label(name: nil, candidates: ["Bill pay"], key: "s-bills"),
            "Bill pay"
        )
        XCTAssertEqual(ExploreGroupNaming.label(name: nil, candidates: [], key: "s-bills"), "s-bills")
        XCTAssertEqual(ExploreGroupNaming.label(name: "   ", candidates: [], key: "s-bills"), "s-bills")
    }

    // MARK: label disambiguation

    // Several features hanging off one hub is the normal shape of an app, and
    // they all draw the same candidate from it. Identical chips would say
    // nothing about what they filter.
    func testGroupsSharingACandidateMoveOnToTheNextName() {
        // The screens' own names follow the buttons' words in the candidates,
        // and those tell the two flows apart where "Deposit" cannot.
        let groups = [
            ExploreGroup(
                key: "s-topup", level: 1, members: ["a", "b"],
                candidates: ["Deposit", "TopUpBottomSheet"], displayable: true
            ),
            ExploreGroup(
                key: "s-portfolio-topup", level: 1, members: ["c", "d"],
                candidates: ["Deposit", "PortfolioTopUpOptionsBottomSheet"], displayable: true
            ),
            ExploreGroup(
                key: "s-invest", level: 1, members: ["e", "f"],
                candidates: ["Portfolio"], displayable: true
            ),
        ]
        let resolved = ExploreGroupNaming.disambiguateLabels(groups)

        XCTAssertEqual(resolved[0].label, "TopUpBottomSheet")
        XCTAssertEqual(resolved[1].label, "PortfolioTopUpOptionsBottomSheet")
        XCTAssertEqual(resolved[2].label, "Portfolio", "a candidate nobody else shares still reads best")
    }

    // The key is the last resort, not the first: it only shows when the map
    // offers no other word for the flow.
    func testAGroupWithNoDistinctCandidateFallsBackToItsKey() {
        let groups = [
            ExploreGroup(key: "s-one", level: 1, members: ["a", "b"], candidates: ["Deposit"], displayable: true),
            ExploreGroup(key: "s-two", level: 1, members: ["c", "d"], candidates: ["Deposit"], displayable: true),
        ]
        let resolved = ExploreGroupNaming.disambiguateLabels(groups)

        XCTAssertEqual(resolved[0].label, "s-one")
        XCTAssertEqual(resolved[1].label, "s-two", "neither chip keeps a word that says nothing about it")
    }

    // A name that was posted has already been checked for collisions. Quietly
    // swapping it for a key would hide the clash instead of showing it.
    func testAPostedNameIsNeverReplacedByItsKey() {
        let groups = [
            ExploreGroup(key: "billing", level: 1, members: ["a", "b"], candidates: ["MainScreen"], displayable: true, name: "Bill pay"),
            ExploreGroup(key: "profile", level: 1, members: ["c", "d"], candidates: ["MainScreen"], displayable: true),
        ]
        let resolved = ExploreGroupNaming.disambiguateLabels(groups)

        XCTAssertEqual(resolved[0].label, "Bill pay")
        // Only one chip is left reading "MainScreen", so nothing is ambiguous
        // and the candidate still reads better than the key.
        XCTAssertEqual(resolved[1].label, "MainScreen")
    }

    // The walk down the candidates is also what keeps a replacement as good as
    // the label it replaces: candidates arrive ranked, the names of components
    // and id namespaces last, so stepping forward never steps down. The first
    // choice used to skip a component name where the replacement did not, and
    // two flows sharing one word ended up named after the sheet both open.
    func testAReplacementIsNoWorseThanTheLabelItReplaces() {
        let groups = [
            ExploreGroup(
                key: "s-pay-topup", level: 2, members: ["a", "b"],
                candidates: ["Deposit", "PayAmountScreen", "HolaBottomSheet"], displayable: true
            ),
            ExploreGroup(
                key: "s-inv-topup", level: 2, members: ["c", "d"],
                candidates: ["Deposit", "InvestAmountScreen", "HolaBottomSheet"], displayable: true
            ),
        ]
        let resolved = ExploreGroupNaming.disambiguateLabels(groups)

        XCTAssertEqual(resolved[0].label, "PayAmountScreen")
        XCTAssertEqual(resolved[1].label, "InvestAmountScreen")
    }

    // MARK: a key that slid off its flow

    func testAnOrphanedNameMovesOntoTheFlowItStillDescribes() {
        let names = ExploreGroupNames(names: [
            "s-bills": ExploreGroupName(name: "Оплата счетов", members: ["s-bills", "s-reference"]),
        ])
        // The loading screen the tap really opens first took over the key.
        let groups = [
            ExploreGroup(key: "s-load", level: 1, members: ["s-load", "s-bills", "s-reference"]),
            ExploreGroup(key: "s-profile", level: 1, members: ["s-profile", "s-personal"]),
        ]
        let matched = ExploreGroupNaming.matched(names, to: groups)

        XCTAssertEqual(matched["s-load"]?.name, "Оплата счетов")
        XCTAssertNil(matched["s-profile"])
    }

    func testAnOrphanedNameStaysPutWhenTwoFlowsMatchItEquallyWell() {
        let names = ExploreGroupNames(names: [
            "s-gone": ExploreGroupName(name: "Bill pay", members: ["s-bills", "s-reference"]),
        ])
        let groups = [
            ExploreGroup(key: "s-one", level: 1, members: ["s-bills", "s-reference"]),
            ExploreGroup(key: "s-two", level: 1, members: ["s-bills", "s-reference"]),
        ]
        XCTAssertTrue(
            ExploreGroupNaming.matched(names, to: groups).isEmpty,
            "a wrong transfer puts a person's word on a feature they never named"
        )
    }

    func testAnOrphanedNameDoesNotDisplaceAFlowsOwnNameOrRepeatIt() {
        let names = ExploreGroupNames(names: [
            "s-gone": ExploreGroupName(name: "Bill pay", members: ["s-bills", "s-reference"]),
            "s-load": ExploreGroupName(name: "Facturas", members: ["s-load", "s-bills"]),
        ])
        let groups = [ExploreGroup(key: "s-load", level: 1, members: ["s-load", "s-bills", "s-reference"])]
        let matched = ExploreGroupNaming.matched(names, to: groups)

        XCTAssertEqual(matched["s-load"]?.name, "Facturas", "the flow's own record wins")
        XCTAssertEqual(matched.count, 1)
    }

    func testANameDoesNotMoveOntoAFlowItBarelyOverlaps() {
        let names = ExploreGroupNames(names: [
            "s-gone": ExploreGroupName(name: "Bill pay", members: ["s-bills", "s-reference"]),
        ])
        let groups = [ExploreGroup(key: "s-invest", level: 1, members: ["s-invest", "s-analytics", "s-bills"])]
        XCTAssertTrue(ExploreGroupNaming.matched(names, to: groups).isEmpty)
    }

    // MARK: store

    func testNamesSurviveAMapRewriteAndARestart() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMap(at: root)

        try makeController(root: root).saveGroupNames(["s-bills": "Bill pay"])

        // The crawler rewrites the graph after every step; names live beside it.
        try writeMap(at: root, extraScreen: true)
        let reopened = makeController(root: root).namingGroups()
        let billing = try XCTUnwrap(reopened.first { $0.key == "s-bills" })
        XCTAssertEqual(billing.name, "Bill pay")
        XCTAssertEqual(billing.label, "Bill pay")
        XCTAssertFalse(billing.staleName, "one screen joining must not stale the name")
    }

    func testAGroupThatDisappearsKeepsItsNameForWhenItReturns() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMap(at: root)
        try makeController(root: root).saveGroupNames(["s-bills": "Bill pay"])

        // A map without that feature at all.
        try writeMap(at: root, dropBilling: true)
        XCTAssertNil(makeController(root: root).namingGroups().first { $0.key == "s-bills" })

        try writeMap(at: root)
        let returned = try XCTUnwrap(makeController(root: root).namingGroups().first { $0.key == "s-bills" })
        XCTAssertEqual(returned.name, "Bill pay")
    }

    // A group is keyed by the screen it opens at, and that is only as stable as
    // the screen the button really opens first: let one crawl catch the loading
    // screen that flashes before it and the key moves one screen forward. The
    // name then pointed at a flow that no longer existed — silently, because a
    // group that is gone reports nothing at all.
    func testANameFollowsItsFlowWhenALoadingScreenTakesOverItsKey() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMap(at: root)
        try makeController(root: root).saveGroupNames(["s-bills": "Оплата счетов"])

        try writeMap(at: root, interstitial: true)
        let groups = makeController(root: root).namingGroups()

        XCTAssertNil(groups.first { $0.key == "s-bills" }, "the flow now opens at the loading screen")
        let moved = try XCTUnwrap(groups.first { $0.key == "s-load" })
        XCTAssertEqual(moved.name, "Оплата счетов")
        XCTAssertEqual(moved.label, "Оплата счетов")
        XCTAssertFalse(moved.staleName, "the same screens, with one in front of them")

        // The record itself stays under the key it was written for, so the flow
        // finds its own name again if the loading screen stops being caught.
        try writeMap(at: root)
        XCTAssertEqual(
            makeController(root: root).namingGroups().first { $0.key == "s-bills" }?.name,
            "Оплата счетов"
        )
    }

    // Where that story stopped: the flow shows the name, the record lives under
    // a key nothing names any more, and there was no way out of it. Recording
    // the name for the key it moved to was refused as a clash with the record
    // it came from; clearing that record was refused because a key that names
    // no flow is not one this route accepts. `groups.json` had to be edited by
    // hand — for a feature the map itself had already worked out.
    func testANameCanBePinnedOnTheKeyItsFlowMovedTo() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMap(at: root)
        try makeController(root: root).saveGroupNames(["s-bills": "Оплата счетов"])

        try writeMap(at: root, interstitial: true)
        let pinned = try makeController(root: root).saveGroupNames(["s-load": "Оплата счетов"])
        XCTAssertEqual(pinned.first { $0.key == "s-load" }?.name, "Оплата счетов")

        // One key holds the name now — the live one. Two would be the clash the
        // whole recording path exists to refuse.
        XCTAssertEqual(try storedNames(at: root).names.keys.sorted(), ["s-load"])
        let reopened = try XCTUnwrap(makeController(root: root).namingGroups().first { $0.key == "s-load" })
        XCTAssertEqual(reopened.name, "Оплата счетов")
        XCTAssertFalse(reopened.staleName, "the membership was re-recorded with the name")

        // And pinning it does not close the door behind it: a crawl that stops
        // catching the loading screen puts the key back, and the record — now
        // the orphan — follows its flow the same way it did on the way here.
        try writeMap(at: root)
        XCTAssertEqual(
            makeController(root: root).namingGroups().first { $0.key == "s-bills" }?.name,
            "Оплата счетов"
        )
    }

    // And the other way out: a record whose feature is gone from the app, not
    // merely re-keyed. Nothing shows it, so nothing can correct it — clearing
    // it is the only thing left to do with it, and an empty name is how
    // clearing is spelled.
    func testARecordWithNoFlowLeftToNameCanBeCleared() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMap(at: root)
        try makeController(root: root).saveGroupNames(["s-bills": "Оплата счетов"])

        try writeMap(at: root, dropBilling: true)
        XCTAssertNil(makeController(root: root).namingGroups().first { $0.key == "s-bills" })
        try makeController(root: root).saveGroupNames(["s-bills": ""])
        XCTAssertTrue(try storedNames(at: root).names.isEmpty)

        // Naming a flow that does not exist is still a mistake worth refusing:
        // a name has to describe something the map has.
        XCTAssertThrowsError(try makeController(root: root).saveGroupNames(["s-bills": "Оплата счетов"])) { error in
            XCTAssertTrue("\(error)".contains("s-bills"), "\(error)")
        }
    }

    // A record that is only off the panel for a run is not a dead key: it names
    // a flow the map still has, and handing its name to another flow is the
    // clash `conflicts` is judged over the whole file to prevent.
    func testAFlowThatIsMerelyOffThePanelKeepsItsNameAgainstANewOne() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMap(at: root)
        try makeController(root: root).saveGroupNames(["s-bills": "Bill pay"])

        XCTAssertThrowsError(try makeController(root: root).saveGroupNames(["s-profile": "Bill pay"]))
        XCTAssertEqual(try storedNames(at: root).names["s-bills"]?.name, "Bill pay")
        XCTAssertNil(try storedNames(at: root).names["s-profile"])
    }

    func testASetWithARepeatedNameIsRejectedAndChangesNothing() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMap(at: root)
        let controller = makeController(root: root)
        try controller.saveGroupNames(["s-bills": "Bill pay"])

        XCTAssertThrowsError(
            try controller.saveGroupNames(["s-profile": "Bill pay"])
        ) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("s-bills"), message)
            XCTAssertTrue(message.contains("s-profile"), message)
        }

        let after = makeController(root: root).namingGroups()
        XCTAssertEqual(after.first { $0.key == "s-bills" }?.name, "Bill pay")
        XCTAssertNil(after.first { $0.key == "s-profile" }?.name)
    }

    func testNamingNeedsNeitherACrawlNorASimulator() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMap(at: root)

        // Nothing is started; the controller only ever reads the stored map.
        let groups = makeController(root: root).namingGroups()
        XCTAssertFalse(groups.isEmpty)
        XCTAssertTrue(groups.allSatisfy(\.displayable), "only groups a person can pick are offered for naming")
        let billing = try XCTUnwrap(groups.first { $0.key == "s-bills" })
        XCTAssertEqual(billing.candidates.first, "Bill pay", "the map's own wording leads the candidates")
        XCTAssertNotNil(billing.entry)
    }

    func testNamingAnUnknownGroupIsRefused() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMap(at: root)
        XCTAssertThrowsError(try makeController(root: root).saveGroupNames(["nope": "Something"]))
    }

    func testAnEmptyNameClearsTheStoredName() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMap(at: root)
        let controller = makeController(root: root)
        try controller.saveGroupNames(["s-bills": "Оплата счетов"])
        XCTAssertEqual(makeController(root: root).namingGroups().first { $0.key == "s-bills" }?.name, "Оплата счетов")

        try controller.saveGroupNames(["s-bills": ""])

        let billing = try XCTUnwrap(makeController(root: root).namingGroups().first { $0.key == "s-bills" })
        XCTAssertNil(billing.name)
        XCTAssertNotEqual(billing.label, "Оплата счетов", "the cleared name must stop being shown")
        XCTAssertEqual(billing.label, "Bill pay", "the map's own wording is what falls back in")
    }

    // MARK: helpers

    private func makeRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("explore-names-\(UUID().uuidString)")
    }

    /// `groups.json` as it is on disk — the question "which keys hold a name"
    /// is about the file, not about what the panel happens to show.
    private func storedNames(at root: URL) throws -> ExploreGroupNames {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("groups.json")) else {
            return ExploreGroupNames()
        }
        return try JSON.decoder.decode(ExploreGroupNames.self, from: data)
    }

    private func makeController(root: URL) -> ExploreController {
        ExploreController(configuration: ExploreController.Configuration(
            device: SimulatorDevice(udid: "TEST-UDID", name: "iPhone 16 Pro", runtime: "iOS", state: "Booted", isAvailable: true),
            defaultApp: "com.example.app",
            profiles: [],
            appFacingServerURL: nil,
            root: root
        ))
    }

    /// `interstitial` puts a loading screen in front of the billing flow — the
    /// screen the tap really opens first, which the next crawl may well catch.
    private func writeMap(
        at root: URL,
        extraScreen: Bool = false,
        dropBilling: Bool = false,
        interstitial: Bool = false
    ) throws {
        var keys: [(String, [String])] = [
            ("s-main", ["profile_menu_greeting"]),
            ("s-profile", ["profile_menu_details"]),
            ("s-personal", ["profile_menu_personal"]),
        ]
        var links: [(String, String, String)] = [
            ("s-main", "s-profile", "Profile"),
            ("s-profile", "s-personal", "Personal details"),
        ]
        if !dropBilling {
            keys += [("s-bills", ["billing_invoices_category"]), ("s-reference", ["billing_invoices_reference"])]
            links.append(("s-bills", "s-reference", "Recarga"))
            if interstitial {
                keys.append(("s-load", ["billing_invoices_loading"]))
                links += [("s-main", "s-load", "Bill pay"), ("s-load", "s-bills", "")]
            } else {
                links.append(("s-main", "s-bills", "Bill pay"))
            }
            if extraScreen {
                keys.append(("s-receipt", ["billing_invoices_receipt"]))
                links.append(("s-reference", "s-receipt", "Receipt"))
            }
        } else {
            keys.append(("s-invest", ["invest_widget_portfolio"]))
            keys.append(("s-analytics", ["invest_widget_analytics"]))
            links.append(("s-main", "s-invest", "Portfolio"))
            links.append(("s-invest", "s-analytics", "Analyze"))
        }

        let nodes = keys.map { id, localizationKeys in
            ExploreScreenNode(
                id: id,
                title: id,
                fingerprint: id,
                key: id,
                screenshot: "shots/\(id).png",
                depth: 0,
                visits: 1,
                states: 1,
                actionsTotal: 1,
                actionsTried: 1,
                firstSeenAt: "2026-08-19T10:00:00Z",
                triedActionKeys: nil,
                deeplinks: nil,
                localizationKeys: localizationKeys
            )
        }
        let edges = links.map { from, to, label in
            ExploreTransitionEdge(
                id: "\(from)->\(to)",
                from: from,
                to: to,
                action: ExploreTransitionAction(kind: "tap", targetId: nil, targetLabel: label),
                count: 1
            )
        }
        let graph = ExploreGraph(
            schemaVersion: 2,
            run: ExploreRunMeta(
                id: "2026-08-19T10-00-00",
                app: "com.example.app",
                device: "iPhone 16 Pro",
                profile: nil,
                startedAt: "2026-08-19T10:00:00Z",
                finishedAt: nil
            ),
            stats: ExploreStats(screens: nodes.count, transitions: edges.count, steps: 0, relaunches: 0),
            nodes: nodes,
            edges: edges
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSON.encoder.encode(graph).write(to: root.appendingPathComponent("graph.json"))
    }
}
