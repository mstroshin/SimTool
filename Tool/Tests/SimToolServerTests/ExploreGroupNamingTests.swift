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

    private func makeController(root: URL) -> ExploreController {
        ExploreController(configuration: ExploreController.Configuration(
            device: SimulatorDevice(udid: "TEST-UDID", name: "iPhone 16 Pro", runtime: "iOS", state: "Booted", isAvailable: true),
            defaultApp: "com.example.app",
            profiles: [],
            appFacingServerURL: nil,
            root: root
        ))
    }

    private func writeMap(at root: URL, extraScreen: Bool = false, dropBilling: Bool = false) throws {
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
            links += [("s-main", "s-bills", "Bill pay"), ("s-bills", "s-reference", "Recarga")]
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
