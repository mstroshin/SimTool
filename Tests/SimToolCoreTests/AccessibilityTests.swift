import XCTest
@testable import SimToolCore

final class AccessibilityTests: XCTestCase {
    // The raw AXe payload repeats each node's entire subtree, so carrying it on
    // every normalized node makes the tree O(nodes x depth) — megabytes for one
    // screen. Agents get the lean tree; `includeRaw` is the explicit opt-in.
    func testParseTreeOmitsRawByDefault() throws {
        let tree = try SimulatorAccessibilityClient.parseTree(sampleJSON)

        XCTAssertNil(tree.roots[0].raw)
        XCTAssertNil(tree.roots[0].children[0].raw)
        let encoded = try JSON.string(tree)
        XCTAssertFalse(encoded.contains("\"raw\""))
    }

    func testParseTreeIncludesRawOnRequest() throws {
        let tree = try SimulatorAccessibilityClient.parseTree(sampleJSON, includeRaw: true)

        XCTAssertNotNil(tree.roots[0].raw)
        XCTAssertNotNil(tree.roots[0].children[0].raw)
    }

    func testFlattenProducesCompactNodesInDocumentOrder() throws {
        let tree = try SimulatorAccessibilityClient.parseTree(sampleJSON)
        let flat = SimulatorAccessibilityClient.flatten(tree)

        XCTAssertEqual(flat.nodeCount, 3)
        XCTAssertEqual(flat.nodes.count, 3)

        let root = flat.nodes[0]
        XCTAssertEqual(root.id, "root")
        XCTAssertEqual(root.label, "App")
        XCTAssertEqual(root.type, "Application")
        XCTAssertEqual(root.depth, 0)
        XCTAssertEqual(root.frame, [0, 0, 390, 844])
        XCTAssertNil(root.enabled, "enabled is only present when false")

        let group = flat.nodes[1]
        XCTAssertNil(group.id)
        XCTAssertEqual(group.depth, 1)

        let button = flat.nodes[2]
        XCTAssertEqual(button.id, "continueButton")
        XCTAssertEqual(button.label, "Continue")
        XCTAssertEqual(button.depth, 2)
        // Fractional point coordinates round to integers; sub-point precision
        // is noise for tapping.
        XCTAssertEqual(button.frame, [20, 705, 350, 44])
        XCTAssertEqual(button.enabled, false)

        // Null fields are omitted entirely from the encoded payload.
        let encoded = try JSON.string(flat)
        XCTAssertFalse(encoded.contains("null"))
        XCTAssertFalse(encoded.contains("\"raw\""))
    }

    func testFlattenLabeledOnlyDropsAnonymousNodes() throws {
        let tree = try SimulatorAccessibilityClient.parseTree(sampleJSON)
        let flat = SimulatorAccessibilityClient.flatten(tree, labeledOnly: true)

        // The anonymous wrapper group disappears; nodeCount still reports the
        // full tree so the caller can tell filtering happened.
        XCTAssertEqual(flat.nodeCount, 3)
        XCTAssertEqual(flat.nodes.map(\.label), ["App", "Continue"])
        XCTAssertEqual(flat.nodes.map(\.depth), [0, 2])
    }

    private var sampleJSON: Data {
        #"""
        [
          {
            "AXUniqueId": "root",
            "AXLabel": "App",
            "AXValue": null,
            "role": "AXApplication",
            "role_description": "application",
            "type": "Application",
            "enabled": true,
            "frame": { "x": 0, "y": 0, "width": 390, "height": 844 },
            "children": [
              {
                "AXUniqueId": null,
                "AXLabel": null,
                "role": "AXGroup",
                "type": "Group",
                "enabled": true,
                "frame": { "x": 0, "y": 100, "width": 390, "height": 700 },
                "children": [
                  {
                    "AXUniqueId": "continueButton",
                    "AXLabel": "Continue",
                    "role": "AXButton",
                    "type": "Button",
                    "enabled": false,
                    "pid": 123,
                    "frame": { "x": 20.333333, "y": 704.666666, "width": 349.99999, "height": 44.0 },
                    "children": []
                  }
                ]
              }
            ]
          }
        ]
        """#.data(using: .utf8)!
    }
}
