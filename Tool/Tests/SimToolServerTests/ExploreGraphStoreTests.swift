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

    private func makeStore(at root: URL, nodeIds: [String]) throws {
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
                localizationKeys: nil
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
            stats: ExploreStats(screens: nodes.count, transitions: 0, steps: 0, relaunches: 0),
            nodes: nodes,
            edges: []
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
}
