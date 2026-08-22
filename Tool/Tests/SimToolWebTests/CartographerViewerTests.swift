import XCTest
@testable import SimToolWeb

final class CartographerViewerTests: XCTestCase {
    // The whole map is the first choice in the same row as the features, so
    // returning to it is the same gesture as switching between them — not a
    // mode with its own way out.
    func testCanvasOffersTheWholeMapAlongsideTheFeatures() {
        let html = CartographerViewer.html()

        XCTAssertTrue(html.contains("Вся карта"), "missing the whole-map choice")
        XCTAssertTrue(html.contains("group-chip"), "missing the feature switcher")
        XCTAssertTrue(html.contains("setActiveGroupKey(null)"), "the whole map must be reachable in one click")
        XCTAssertTrue(html.contains("group.displayable"), "one-screen groups must stay unlisted")
        XCTAssertTrue(html.contains("group.members.length"), "a chip must show how many screens it holds")
    }

    // Names are given by an agent and cannot be corrected by hand, so the key a
    // chip really filters by stays readable next to whatever it is called.
    func testChipShowsTheNameWithTheKeyBesideIt() {
        let html = CartographerViewer.html()

        XCTAssertTrue(html.contains("${group.label}"), "a chip shows the group's label")
        XCTAssertTrue(html.contains("group-key"), "the underlying key must stay visible")
        XCTAssertTrue(html.contains("group.staleName"), "a name given for a since-changed group must be marked")
    }

    // A feature is drawn as its connecting subtree: the screens of the group
    // plus the transit screens that hold the sequence together.
    func testFeatureViewDrawsTheConnectingSubtree() {
        let html = CartographerViewer.html()

        XCTAssertTrue(html.contains("function subtreeLayout"), "missing the feature layout")
        XCTAssertTrue(html.contains("activeGroup.bridges"), "bridges must be drawn with the group")
        XCTAssertTrue(
            html.contains("[...bridges, activeGroup.entry]"),
            "the doors lead the layout so the way into the flow reads left to right"
        )
        XCTAssertTrue(html.contains(".react-flow__node.bridge"), "bridges must be told apart from the group's own screens")
        XCTAssertTrue(html.contains("draggable: false"), "a derived view must not be rearranged by hand")
    }

    // Coming back must land where the user left the map, and a crawl filling an
    // open feature must not move the view out from under them.
    func testViewportIsPreservedAcrossSwitchingAndGrowth() {
        let html = CartographerViewer.html()

        XCTAssertTrue(html.contains("wholeMapViewport"), "missing the saved viewport")
        XCTAssertTrue(html.contains("instance.setViewport(wholeMapViewport.current"), "returning must restore, not re-fit")
        XCTAssertTrue(
            html.contains("if (activeGroupKey !== null && !switched) return undefined;"),
            "growth inside an open feature must leave the viewport alone"
        )
    }

    // Search keeps answering about what is on screen, but never swallows hits
    // that fell outside the open feature.
    func testSearchIsScopedToTheOpenViewAndReportsHitsOutsideIt() {
        let html = CartographerViewer.html()

        XCTAssertTrue(html.contains("const outsideMatches"), "hits outside the view must be counted")
        XCTAssertTrue(html.contains("вне фичи"), "hits outside the view must be offered, not hidden")
    }

    // A screen assembled from several features belongs to each of them, and the
    // drawer is where that stops being surprising.
    func testDrawerListsEveryFeatureAScreenBelongsTo() {
        let html = CartographerViewer.html()

        XCTAssertTrue(html.contains("Фичи"), "missing the feature list on a screen")
        XCTAssertTrue(html.contains("{ label: \"фичи\", pick: (node) => node.groups || [] }"), "groups must be searchable by key")
        XCTAssertTrue(html.contains("groupLabels.get(key) || key"), "a drawer chip reads by the flow's label, not its key")
    }
}
