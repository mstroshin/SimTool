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

    private func temporaryRoot(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("explore-\(name)-\(UUID().uuidString)")
    }

    /// The crawl task a `start` leaves behind is cancelled at once, but it still
    /// has a closing write to make; waiting for it keeps the test from pulling
    /// the store out from under it.
    private func waitUntilIdle(_ controller: ExploreController, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.status().running, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func brokenFiles(in root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.contains(".broken-") }
    }


    /// A map with the depths the crawl recorded, for the questions about what
    /// reaches the file.
    private func graph(nodes: [(String, Int)], edges: [(String, String)]) -> ExploreGraph {
        ExploreGraph(
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
            nodes: nodes.map { id, depth in
                ExploreScreenNode(
                    id: id,
                    title: id,
                    fingerprint: id,
                    key: id,
                    screenshot: "shots/\(id).png",
                    depth: depth,
                    visits: 1,
                    states: 1,
                    actionsTotal: 1,
                    actionsTried: 1,
                    firstSeenAt: "2026-08-19T10:00:00Z",
                    triedActionKeys: ["a"],
                    actionKeys: ["a"]
                )
            },
            edges: edges.map { from, to in
                ExploreTransitionEdge(
                    id: "e-\(from)-\(to)",
                    from: from,
                    to: to,
                    action: ExploreTransitionAction(kind: "tap", targetId: nil, targetLabel: "go"),
                    count: 1
                )
            }
        )
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

    // MARK: files this build must not lose

    // A `layout.json` that will not decode still holds every card a person
    // dragged. The reader used to walk away from it in silence, and the next
    // save wrote an empty arrangement over it — the placements were gone and
    // nobody had been told.
    func testUnreadableLayoutIsSetAsideAndReported() throws {
        let root = temporaryRoot("layout-broken")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(at: root, nodeIds: ["s-a", "s-b"])
        try Data("{ not json".utf8).write(to: root.appendingPathComponent("layout.json"))

        let controller = makeController(root: root)
        let status = controller.status()

        XCTAssertTrue(status.error?.contains("layout.json") ?? false, "the person has to learn of it")
        XCTAssertEqual(brokenFiles(in: root).count, 1, "the file itself is kept, under a new name")
        XCTAssertTrue(status.layout?.positions.isEmpty ?? false)
        // And the canvas keeps working: a save after the rescue is an ordinary
        // save into a fresh file.
        let saved = try controller.saveLayout(["s-a": ExploreNodePosition(x: 1, y: 2)])
        XCTAssertEqual(saved.positions["s-a"], ExploreNodePosition(x: 1, y: 2))
    }

    // A file from a newer simtool is read for what this build understands and
    // never written back: our view of the arrangement does not carry whatever
    // the newer schema added, and saving it would drop that silently.
    func testALayoutFromANewerSimtoolIsShownButNotOverwritten() throws {
        let root = temporaryRoot("layout-future")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(at: root, nodeIds: ["s-a"])
        let future = """
        { "schemaVersion": 99, "positions": { "s-a": { "x": 7, "y": 8 } } }
        """
        let file = root.appendingPathComponent("layout.json")
        try Data(future.utf8).write(to: file)

        let controller = makeController(root: root)
        let status = controller.status()
        XCTAssertEqual(status.layout?.positions["s-a"], ExploreNodePosition(x: 7, y: 8))
        XCTAssertTrue(status.error?.contains("schemaVersion 99") ?? false)

        XCTAssertThrowsError(try controller.saveLayout(["s-a": ExploreNodePosition(x: 0, y: 0)])) { error in
            guard case ExploreRequestError.conflict = error else {
                return XCTFail("expected a conflict, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data(future.utf8), "the file is untouched")
        XCTAssertTrue(brokenFiles(in: root).isEmpty, "and not set aside either — it decodes")
    }

    // Doing what the notice asks — moving the newer file aside — has to retire
    // it. Only a save used to, so the page went on reporting a refusal that no
    // longer applied, in red, until somebody happened to drag a card.
    func testMovingTheNewerFileAsideRetiresItsNotice() throws {
        let root = temporaryRoot("layout-future-fixed")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(at: root, nodeIds: ["s-a"])
        let file = root.appendingPathComponent("layout.json")
        let names = root.appendingPathComponent("groups.json")
        try Data(#"{ "schemaVersion": 99, "positions": {} }"#.utf8).write(to: file)
        try Data(#"{ "schemaVersion": 99, "names": {} }"#.utf8).write(to: names)

        let controller = makeController(root: root)
        XCTAssertTrue(controller.status().error?.contains("schemaVersion 99") ?? false)

        // What a person is told to do: put a file this build can write in their
        // place. Written, not deleted — a deleted one leaves nothing to read,
        // and the notice is meant to outlive that.
        try Data(#"{ "schemaVersion": 1, "positions": {} }"#.utf8).write(to: file)
        try Data(#"{ "schemaVersion": 1, "names": {} }"#.utf8).write(to: names)
        // `layout.json` is re-read when its timestamp moves, and two writes in
        // one millisecond can share one. The replacement is a second newer here
        // so the test asks about the notice and not about clock resolution.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: file.path
        )
        XCTAssertNil(controller.status().error, "the notice describes nothing any more")

        // And the writes it was refusing go through.
        XCTAssertNoThrow(try controller.saveLayout(["s-a": ExploreNodePosition(x: 1, y: 2)]))
    }

    // Same for the names: `groups.json` is the only place a human name for a
    // feature exists, so an unreadable one is set aside rather than replaced.
    func testUnreadableGroupNamesAreSetAsideAndReported() throws {
        let root = temporaryRoot("names-broken")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(at: root, nodeIds: ["s-a", "s-b"], edges: [("s-a", "s-b", "Bills")])
        try Data("}{".utf8).write(to: root.appendingPathComponent("groups.json"))

        let controller = makeController(root: root)
        let status = controller.status()

        XCTAssertTrue(status.error?.contains("groups.json") ?? false)
        XCTAssertEqual(brokenFiles(in: root).count, 1)
        // Naming still works, from an empty set of names.
        XCTAssertNoThrow(try controller.saveGroupNames([:]))
    }

    // Setting a file aside is reported once and cannot be reported again — the
    // next read of a quarantined file just finds it missing, which is the
    // ordinary state of a store nobody has written yet. So the notice had to
    // outlive the poll that raised it, and one shared slot meant the first
    // unrelated success wiped it: a card dragged, `layout.json` written, and
    // the banner saying every feature name had been set aside was gone for
    // good. Nobody would ever have learned it happened.
    func testASuccessfulSaveOnlyRetiresItsOwnFilesNotice() throws {
        let root = temporaryRoot("warning-per-file")
        defer { try? FileManager.default.removeItem(at: root) }
        // A fork, so the map has a flow there is a name to record for.
        try makeStore(
            at: root,
            nodeIds: ["s-a", "s-b", "s-c"],
            edges: [("s-a", "s-b", "Bills"), ("s-a", "s-c", "Invest")]
        )
        try Data("}{".utf8).write(to: root.appendingPathComponent("groups.json"))

        let controller = makeController(root: root)
        XCTAssertTrue(controller.status().error?.contains("groups.json") ?? false)

        try controller.saveLayout(["s-a": ExploreNodePosition(x: 8, y: 8)])
        XCTAssertTrue(
            controller.status().error?.contains("groups.json") ?? false,
            "dragging a card says nothing about the names that were set aside"
        )

        // Recording names is news about that file, and retires its notice.
        try controller.saveGroupNames(["s-b": "Bills"])
        XCTAssertNil(controller.status().error)
    }

    func testGroupNamesFromANewerSimtoolAreNotOverwritten() throws {
        let root = temporaryRoot("names-future")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(at: root, nodeIds: ["s-a", "s-b"], edges: [("s-a", "s-b", "Bills")])
        let future = """
        { "schemaVersion": 99, "names": {} }
        """
        let file = root.appendingPathComponent("groups.json")
        try Data(future.utf8).write(to: file)

        let controller = makeController(root: root)
        XCTAssertTrue(controller.status().error?.contains("schemaVersion 99") ?? false)
        XCTAssertThrowsError(try controller.saveGroupNames([:])) { error in
            guard case ExploreRequestError.conflict = error else {
                return XCTFail("expected a conflict, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data(future.utf8))
    }

    // The cartograph.md pass is told to delete the store when the map has to be
    // started over. The decoded copy used to outlive it: `/status` kept
    // answering with twelve screens nobody could see, and the next save built
    // the directory back around them.
    func testAStoreDeletedFromDiskStopsBeingServed() throws {
        let root = temporaryRoot("deleted")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(at: root, nodeIds: ["s-a", "s-b"], edges: [("s-a", "s-b", "Bills")])
        let controller = makeController(root: root)
        XCTAssertEqual(controller.status().graph?.nodes.count, 2)

        try FileManager.default.removeItem(at: root)

        let after = controller.status()
        XCTAssertNil(after.graph)
        XCTAssertTrue(after.groups?.isEmpty ?? true)
        XCTAssertNil(controller.shotData(node: "s-a"))
        XCTAssertTrue(controller.namingGroups().isEmpty)
    }

    // A write that failed is nothing the caller can fix by sending something
    // else, and both routes answered it as "bad request".
    // A write the store's own shape refuses is settled, not passing: the tab
    // stops repeating a refusal it reads as final, and keeps trying one it
    // reads as the disk having a bad moment. Answering "server error" for a
    // directory that will sit there until someone moves it had the page
    // promising to retry an arrangement that was already lost.
    func testAWriteTheStoresShapeRefusesIsSettledNotPassing() throws {
        let root = temporaryRoot("unwritable-files")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(at: root, nodeIds: ["s-a", "s-b"], edges: [("s-a", "s-b", "Bills")])
        // Directories where the files belong: nothing can be written over them.
        for name in ["layout.json", "groups.json"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        let controller = makeController(root: root)

        for (what, save) in [
            ("layout.json", { try controller.saveLayout(["s-a": ExploreNodePosition(x: 1, y: 1)]) as Any }),
            ("groups.json", { try controller.saveGroupNames([:]) as Any }),
        ] {
            XCTAssertThrowsError(try save()) { error in
                guard case let ExploreRequestError.conflict(message) = error else {
                    return XCTFail("\(what): expected a settled conflict, got \(error)")
                }
                XCTAssertTrue(message.contains(what), message)
            }
            // And it is not only in the answer to the call that hit it: someone
            // who reloads the page still learns why nothing is being recorded.
            XCTAssertTrue(
                (controller.status().error ?? "").contains(what),
                "\(what) should be named in the status: \(controller.status().error ?? "nil")"
            )
        }
    }


    // MARK: the store as it is written

    // `depth` in the store is the shortest distance the crawl observed. The
    // measured one belongs to whoever draws the map: written back, it would be
    // read as an observation by the next run, and a screen that lost its last
    // incoming arrow would keep the zero that loss handed it.
    func testTheWrittenStoreKeepsTheDepthTheCrawlRecorded() throws {
        let root = temporaryRoot("written-depth")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // `s-deep` was found three taps in on an earlier run; this map reaches
        // it in one, so the measured distance and the recorded one differ.
        let crawled = graph(nodes: [("s-main", 0), ("s-deep", 3)], edges: [("s-main", "s-deep")])

        try ExploreController.writeStore(ExploreController.storeSnapshot(crawled), to: root)

        let stored = try JSON.decoder.decode(
            ExploreGraph.self,
            from: try Data(contentsOf: root.appendingPathComponent("graph.json"))
        )
        XCTAssertEqual(stored.nodes.first { $0.id == "s-deep" }?.depth, 3)
        XCTAssertEqual(stored.nodes.first { $0.id == "s-main" }?.depth, 0)
        // What the annotation is there for does reach the file. Where the map
        // opens does not: nothing marked this map, and the writer does not get
        // to decide — see `testTheWrittenStoreInventsNoOpening`.
        XCTAssertEqual(stored.nodes.first { $0.id == "s-main" }?.groups, nil)
        XCTAssertNil(stored.nodes.first { $0.id == "s-main" }?.entryPoint)
        XCTAssertNil(stored.nodes.first { $0.id == "s-deep" }?.entryPoint)
    }

    // The writer used to answer "where does this app open" for a store that
    // said nothing about it — the shallowest screens nothing leads into, which
    // is a fair reading and a terrible thing to write down. The next read took
    // it for the crawl's own note, and a screen that had merely never been
    // tapped into yet was an opening for good: when a later pass did find the
    // tap, the arrow it recorded could not descend into a screen already at
    // level zero, and it never appeared on the map.
    func testTheWrittenStoreInventsNoOpening() throws {
        let root = temporaryRoot("invented-opening")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Two screens nothing leads into, both at the shallowest depth the
        // crawl recorded. Only one of them is where the app opens; the crawl
        // has not been anywhere near the other yet.
        let crawled = graph(
            nodes: [("s-main", 0), ("s-island", 0), ("s-leaf", 1)],
            edges: [("s-main", "s-leaf")]
        )

        try ExploreController.writeStore(ExploreController.storeSnapshot(crawled), to: root)
        let stored = try JSON.decoder.decode(
            ExploreGraph.self,
            from: try Data(contentsOf: root.appendingPathComponent("graph.json"))
        )
        XCTAssertEqual(stored.nodes.compactMap { $0.entryPoint == true ? $0.id : nil }, [])

        // The next pass finds the tap that leads to the island. Reading the
        // store back, that arrow has to be on the map.
        var next = stored
        next.edges.append(contentsOf: graph(nodes: [], edges: [("s-leaf", "s-island")]).edges)
        XCTAssertEqual(
            ExploreGrouping.descending(next).edges.map { "\($0.from)→\($0.to)" },
            ["s-main→s-leaf", "s-leaf→s-island"]
        )
    }

    // The write was a `try?`, so a run whose store could not be written still
    // finished with "Готово: N экранов" over a file that was not there.
    func testWritingTheStoreReportsAFailureInsteadOfSwallowingIt() throws {
        let root = temporaryRoot("unwritable")
        defer { try? FileManager.default.removeItem(at: root) }
        // A directory where the file belongs: nothing can be written over it.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("graph.json"),
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(try ExploreController.writeStore(
            ExploreController.storeSnapshot(graph(nodes: [("s-main", 0)], edges: [])),
            to: root
        ))
    }

    // MARK: a run of another app

    // Switching apps zeroed the map and left everything around it: the previous
    // app's screenshots grew `.simtool/explore/` without bound, and the name
    // someone gave one of its features waited for a matching id to latch onto.
    func testStartingOnADifferentAppTakesTheOldAppsLeftoversWithIt() async throws {
        let root = temporaryRoot("app-switch")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(at: root, nodeIds: ["s-a"])
        let shot = root.appendingPathComponent("shots/s-a.png")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("shots"),
            withIntermediateDirectories: true
        )
        try Data("png".utf8).write(to: shot)
        let controller = makeController(root: root)
        try controller.saveLayout(["s-a": ExploreNodePosition(x: 5, y: 5)])
        try Data(#"{"schemaVersion":1,"names":{"s-a":{"name":"Счета","members":["s-a"]}}}"#.utf8)
            .write(to: root.appendingPathComponent("groups.json"))

        let status = try controller.start(ExploreStartRequest(app: "com.other.app", maxSteps: 1))
        defer { _ = controller.stop() }

        XCTAssertEqual(status.graph?.run.app, "com.other.app")
        XCTAssertEqual(status.graph?.nodes.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shot.path), "the old app's shots go")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("groups.json").path),
            "and so do its feature names"
        )
        XCTAssertTrue(status.layout?.positions.isEmpty ?? false)

        _ = controller.stop()
        await waitUntilIdle(controller)
    }

    // A second run continues the first: the nodes, the tried keys and the
    // cumulative counters are what it starts from, and nothing about them is
    // reset on the way in. The run below is cancelled before it takes a step,
    // so what the store holds afterwards is exactly what it brought.
    func testASecondRunResumesTheStoredMapInsteadOfReplacingIt() async throws {
        let root = temporaryRoot("resume")
        defer { try? FileManager.default.removeItem(at: root) }
        var stored = graph(nodes: [("s-main", 0), ("s-cards", 1)], edges: [("s-main", "s-cards")])
        stored.stats = ExploreStats(screens: 2, transitions: 1, steps: 7, relaunches: 2)
        stored.nodes[0].triedActionKeys = ["tab", "profile"]
        stored.nodes[0].actionKeys = ["card", "profile", "tab"]
        stored.nodes[0].actionsTried = 2
        stored.nodes[0].actionsTotal = 3
        stored.nodes[0].states = 2
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ExploreController.writeStore(stored, to: root)
        let controller = makeController(root: root)

        let status = try controller.start(ExploreStartRequest(maxSteps: 1))
        defer { _ = controller.stop() }

        XCTAssertEqual(status.graph?.nodes.count, 2)
        XCTAssertEqual(status.graph?.stats.steps, 7, "steps are cumulative across runs")
        XCTAssertEqual(status.graph?.stats.relaunches, 2)
        XCTAssertNotEqual(status.graph?.run.id, "2026-08-19T10-00-00", "and it is a new run all the same")

        _ = controller.stop()
        await waitUntilIdle(controller)

        let onDisk = try JSON.decoder.decode(
            ExploreGraph.self,
            from: try Data(contentsOf: root.appendingPathComponent("graph.json"))
        )
        let main = try XCTUnwrap(onDisk.nodes.first { $0.id == "s-main" })
        XCTAssertEqual(main.triedActionKeys, ["tab", "profile"])
        XCTAssertEqual(main.actionKeys, ["card", "profile", "tab"])
        XCTAssertEqual(main.states, 2)
        XCTAssertEqual(main.depth, 0)
        XCTAssertEqual(onDisk.stats.steps, 7)
        XCTAssertEqual(onDisk.edges.count, 1, "and the transition it recorded is still there")
    }


    // The two writers used to answer this differently — the closing one
    // swallowed its failure, the per-step one grew its own recovery — so the
    // answer lives in one place and both directions are asked of it here. Real
    // I/O, because the whole question is what the disk did.
    func testTheStoreNoteFollowsTheWriteInBothDirections() throws {
        let root = temporaryRoot("store-note")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let map = graph(nodes: [("s-main", 0)], edges: [])

        XCTAssertNil(ExploreController.writeStoreReportingFailure(map, to: root))

        // A directory where the file belongs: nothing can be written over it.
        try FileManager.default.removeItem(at: root.appendingPathComponent("graph.json"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("graph.json"),
            withIntermediateDirectories: true
        )
        let failure = ExploreController.writeStoreReportingFailure(map, to: root)
        XCTAssertTrue(failure?.hasPrefix("Карта не сохранена") ?? false, failure ?? "nil")

        // And once the way is clear again the complaint goes with it: a run that
        // keeps it sends someone hunting for a map that is on disk after all.
        try FileManager.default.removeItem(at: root.appendingPathComponent("graph.json"))
        XCTAssertNil(ExploreController.writeStoreReportingFailure(map, to: root))
    }

    // The closing write, through a real run: the map could not be written, so
    // the run must not sign off with "Готово: N экранов" over a file that is
    // not there.
    func testARunWhoseClosingWriteFailsSaysSoInsteadOfSigningOff() async throws {
        let root = temporaryRoot("closing-write")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Read-only: the run cannot create its `shots/` and cannot write the
        // store either, which is the pair of failures a full disk produces.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = makeController(root: root)

        _ = try controller.start(ExploreStartRequest(maxSteps: 1))
        await waitUntilIdle(controller)

        let status = controller.status()
        XCTAssertFalse(status.running)
        XCTAssertTrue(status.error?.contains("Карта не сохранена") ?? false, status.error ?? "nil")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("graph.json").path),
            "which is the point: there is no file the run could have signed off over"
        )
    }

    // A `graph.json` that will not decode is a map, not an absence of one:
    // starting fresh on top of it replaced it at the first publish.
    func testAnUnreadableMapIsSetAsideWhenARunStarts() async throws {
        let root = temporaryRoot("graph-broken")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{ half a map".utf8).write(to: root.appendingPathComponent("graph.json"))
        let controller = makeController(root: root)

        let status = try controller.start(ExploreStartRequest(maxSteps: 1))
        defer { _ = controller.stop() }

        XCTAssertTrue(status.error?.contains("graph.json") ?? false)
        XCTAssertEqual(brokenFiles(in: root).count, 1)

        _ = controller.stop()
        await waitUntilIdle(controller)
    }

    // MARK: runs from before the store was one directory

    func testTheNewestLegacyRunIsAdoptedAndTheRestDropped() throws {
        let root = temporaryRoot("legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        for run in ["2026-08-18T10-00-00", "2026-08-19T10-00-00"] {
            let directory = root.appendingPathComponent(run)
            try makeStore(at: directory, nodeIds: ["s-\(run.suffix(2))"])
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("shots"),
                withIntermediateDirectories: true
            )
            try Data("png".utf8).write(to: directory.appendingPathComponent("shots/s-x.png"))
        }

        let status = makeController(root: root).status()

        XCTAssertEqual(status.graph?.nodes.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("graph.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("shots/s-x.png").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-08-19T10-00-00").path),
            "an adopted run leaves nothing behind"
        )
    }

    // Legacy runs are looked for once. The walk answers a question whose answer
    // cannot change after the first pass, and the tab asks for the status every
    // three seconds — but the sweep also *deletes* every directory it finds, so
    // running it again is not merely wasted work: a directory that arrives later
    // and has nothing to do with the migration is swept away with the rest.
    func testLegacyRunsAreLookedForOnceAndNotOnEveryPoll() throws {
        let root = temporaryRoot("legacy-once")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(at: root.appendingPathComponent("2026-08-19T10-00-00"), nodeIds: ["s-a"])

        let controller = makeController(root: root)
        XCTAssertEqual(controller.status().graph?.nodes.count, 1, "the legacy run was adopted")

        // Something else puts a directory with a map in it beside the store —
        // another checkout's run copied in, a hand-made map to look at.
        let later = root.appendingPathComponent("2026-08-20T10-00-00")
        try makeStore(at: later, nodeIds: ["s-b"])
        _ = controller.status()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: later.appendingPathComponent("graph.json").path),
            "the migration already ran; a later directory is not its business"
        )
    }

    // The move was a `try?` and the delete was unconditional, so a `shots`
    // already sitting at the root — the exact case this migration runs into —
    // took the legacy run's screenshots down with it.
    func testALegacyRunWhoseMoveFailsIsLeftWhereItIs() throws {
        let root = temporaryRoot("legacy-collision")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("2026-08-19T10-00-00")
        try makeStore(at: legacy, nodeIds: ["s-a"])
        try FileManager.default.createDirectory(
            at: legacy.appendingPathComponent("shots"),
            withIntermediateDirectories: true
        )
        try Data("png".utf8).write(to: legacy.appendingPathComponent("shots/s-a.png"))
        // The destination is taken, which is what makes the move fail.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("shots"),
            withIntermediateDirectories: true
        )

        let status = makeController(root: root).status()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacy.appendingPathComponent("shots/s-a.png").path),
            "the screenshots are still there"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("graph.json").path))
        XCTAssertTrue(status.error?.contains("2026-08-19T10-00-00") ?? false)
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
        // Which screen this map is measured from is a reading of it, and the
        // map the tab sees is the same file the agent pass reads: a reading
        // stamped onto a node there comes back as the crawl's own note.
        XCTAssertNil(bills.entryPoint)
        XCTAssertNil(status.graph?.nodes.first { $0.id == "s-main" }?.entryPoint)
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
