import XCTest
@testable import SimToolServer
import SimToolCore

final class ExploreGraphStoreTests: XCTestCase {
    // Stores written before runs merged into one (schema 1) carry no `key` /
    // `triedActionKeys`; resuming from them must decode, not start over.
    func testDecodesSchemaVersion1Graph() throws {
        let json = """
        {
          "schemaVersion": 1,
          "run": {
            "id": "2026-08-18T22-21-54",
            "app": "com.example.app",
            "device": "iPhone 16",
            "startedAt": "2026-08-18T19:21:54Z"
          },
          "stats": { "screens": 1, "transitions": 0, "steps": 7, "relaunches": 1 },
          "nodes": [
            {
              "id": "s-ab12cd34ef",
              "title": "MainScreen",
              "fingerprint": "ab12cd34ef56",
              "screenshot": "shots/s-ab12cd34ef.png",
              "depth": 0,
              "visits": 3,
              "actionsTotal": 8,
              "actionsTried": 5,
              "firstSeenAt": "2026-08-18T19:22:10Z"
            }
          ],
          "edges": []
        }
        """
        let graph = try JSONDecoder().decode(ExploreGraph.self, from: Data(json.utf8))

        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertNil(graph.nodes[0].key)
        XCTAssertNil(graph.nodes[0].triedActionKeys)
        XCTAssertEqual(graph.stats.steps, 7)
    }

    func testRoundTripsSchemaVersion2Fields() throws {
        let node = ExploreScreenNode(
            id: "s-1",
            title: "Screen",
            fingerprint: "fp",
            key: "key",
            screenshot: "shots/s-1.png",
            depth: 1,
            visits: 2,
            states: 1,
            actionsTotal: 4,
            actionsTried: 2,
            firstSeenAt: "2026-08-19T10:00:00Z",
            triedActionKeys: ["a", "b"],
            deeplinks: nil,
            localizationKeys: nil
        )
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(ExploreScreenNode.self, from: data)

        XCTAssertEqual(decoded.key, "key")
        XCTAssertEqual(decoded.triedActionKeys, ["a", "b"])
    }

    // MARK: canvas layout

    private func makeController(root: URL) -> ExploreController {
        ExploreController(configuration: ExploreController.Configuration(
            device: SimulatorDevice(udid: "TEST-UDID", name: "iPhone 16 Pro", runtime: "iOS", state: "Booted", isAvailable: true),
            defaultApp: "com.example.app",
            profiles: [],
            appFacingServerURL: nil,
            root: root
        ))
    }

    private func makeStore(
        at root: URL,
        nodeIds: [String],
        keys: [String: [String]] = [:],
        edges: [(String, String, String)] = []
    ) throws {
        let nodes = nodeIds.map { id in
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
                localizationKeys: keys[id]
            )
        }
        let transitions = edges.map { from, to, label in
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
            stats: ExploreStats(screens: nodes.count, transitions: transitions.count, steps: 0, relaunches: 0),
            nodes: nodes,
            edges: transitions
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSON.encoder.encode(graph).write(to: root.appendingPathComponent("graph.json"))
    }

    // A card dragged in one session must come back where the user left it, and
    // the tab reads the arrangement straight off `status`.
    func testSavedLayoutSurvivesAndSurfacesInStatus() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("explore-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(at: root, nodeIds: ["s-a", "s-b"])

        try makeController(root: root).saveLayout(["s-a": ExploreNodePosition(x: 120, y: -40)])

        let reopened = makeController(root: root).status()
        XCTAssertEqual(reopened.layout?.positions["s-a"], ExploreNodePosition(x: 120, y: -40))
        XCTAssertNil(reopened.layout?.positions["s-b"])
    }

    // Only the cards that moved are sent, so a save merges; and placements of
    // screens the store no longer knows are not kept forever.
    func testSaveLayoutMergesAndDropsUnknownNodes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("explore-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(at: root, nodeIds: ["s-a", "s-b"])
        let controller = makeController(root: root)

        try controller.saveLayout(["s-a": ExploreNodePosition(x: 10, y: 20), "s-gone": ExploreNodePosition(x: 0, y: 0)])
        let merged = try controller.saveLayout(["s-b": ExploreNodePosition(x: 30, y: 40)])

        XCTAssertEqual(merged.positions["s-a"], ExploreNodePosition(x: 10, y: 20))
        XCTAssertEqual(merged.positions["s-b"], ExploreNodePosition(x: 30, y: 40))
        XCTAssertNil(merged.positions["s-gone"])
    }

    // MARK: feature groups

    // A map recorded before grouping existed carries no group fields; reading
    // it must not fail, and screens whose keys say nothing stay ungrouped.
    func testMapWithoutGroupInformationReadsWithoutError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("explore-groups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(at: root, nodeIds: ["s-a", "s-b"])

        let status = makeController(root: root).status()
        XCTAssertEqual(status.graph?.nodes.count, 2)
        XCTAssertTrue(status.groups?.isEmpty ?? true)
        XCTAssertNil(status.graph?.nodes.first?.groups)
    }

    func testGroupFieldsSurviveARoundTrip() throws {
        var node = ExploreScreenNode(
            id: "s-1",
            title: "Screen",
            fingerprint: "fp",
            key: "key",
            screenshot: "shots/s-1.png",
            depth: 1,
            visits: 2,
            states: 1,
            actionsTotal: 4,
            actionsTried: 2,
            firstSeenAt: "2026-08-19T10:00:00Z",
            triedActionKeys: nil,
            deeplinks: nil,
            localizationKeys: ["billing_invoices_title"]
        )
        node.groups = ["s-bills"]
        node.entryPoint = true

        let decoded = try JSONDecoder().decode(
            ExploreScreenNode.self,
            from: try JSONEncoder().encode(node)
        )
        XCTAssertEqual(decoded.groups, ["s-bills"])
        XCTAssertEqual(decoded.entryPoint, true)
    }

    // Grouping is derived on read, so a store written by an earlier version
    // gains its groups on the next poll rather than needing a fresh crawl.
    func testStatusDerivesGroupsFromAStoreThatHasNone() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("explore-groups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(
            at: root,
            nodeIds: ["s-main", "s-bills", "s-reference", "s-profile"],
            keys: [
                "s-main": ["profile_menu_greeting"],
                "s-bills": ["billing_invoices_category"],
                "s-reference": ["billing_invoices_reference"],
                "s-profile": ["profile_menu_details"],
            ],
            edges: [
                ("s-main", "s-bills", "Bill pay"),
                ("s-bills", "s-reference", "Recarga"),
                ("s-main", "s-profile", "Profile"),
            ]
        )

        let status = makeController(root: root).status()
        let billing = try XCTUnwrap(status.groups?.first { $0.key == "s-bills" })
        XCTAssertEqual(billing.members, ["s-bills", "s-reference"])
        XCTAssertEqual(billing.entry, "s-bills")
        XCTAssertEqual(billing.candidates.first, "Bill pay")
        XCTAssertTrue(billing.displayable)
        // The nodes themselves carry their groups, which is what makes the
        // canvas search find a screen by the feature it belongs to.
        let bills = try XCTUnwrap(status.graph?.nodes.first { $0.id == "s-bills" })
        XCTAssertEqual(bills.groups, ["s-bills"])
        XCTAssertNil(bills.entryPoint)
        XCTAssertEqual(status.graph?.nodes.first { $0.id == "s-main" }?.entryPoint, true)
    }

    // The store on disk is the artifact the agent pass reads, so what the tab
    // sees and what the file says must not drift apart.
    func testAnnotationIsIdempotent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("explore-groups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(
            at: root,
            nodeIds: ["s-main", "s-bills", "s-reference"],
            keys: [
                "s-main": ["profile_menu_greeting"],
                "s-bills": ["billing_invoices_category"],
                "s-reference": ["billing_invoices_reference"],
            ],
            edges: [("s-main", "s-bills", "Bill pay"), ("s-bills", "s-reference", "Recarga")]
        )
        let once = try XCTUnwrap(makeController(root: root).status().graph)
        let twice = ExploreGrouping.annotated(once)
        XCTAssertEqual(once.nodes.map(\.groups), twice.nodes.map(\.groups))
        XCTAssertEqual(once.nodes.map(\.depth), twice.nodes.map(\.depth))
        XCTAssertEqual(once.nodes.map(\.entryPoint), twice.nodes.map(\.entryPoint))
    }
}
