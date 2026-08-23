import XCTest
@testable import SimToolWeb

/// The tab is a single served page: markup, styles and the module script arrive
/// in one response, so what these tests read is exactly what a browser gets.
///
/// They assert properties the page must not lose, not the lines it happens to be
/// written in — a rename or a reformat that keeps the property keeps the test
/// green.
///
/// What they cannot do is run the page. A property with no textual shadow at all
/// — does a poll hand the canvas the same card objects it already has? does a
/// refused save stop being re-sent? — is checked in a browser against a running
/// server, by hand: this repository carries no browser runner, so nothing here
/// covers it. Where a fix did leave a shadow, the shadow is asserted below and
/// the behaviour behind it is still only as good as that last browser run.
final class CartographerViewerTests: XCTestCase {
    private var page: String { CartographerViewer.html() }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The source between two landmarks, so an assertion can be about one
    /// decision instead of about the whole file.
    private func region(from opening: String, to closing: String, in text: String) -> String {
        guard let start = text.range(of: opening), let end = text.range(of: closing),
              start.lowerBound < end.lowerBound else { return "" }
        return String(text[start.lowerBound..<end.lowerBound])
    }

    // Everything on the canvas is data the crawl read off a screen: a feature
    // called `<img src=x onerror=alert(1)>` must stay a name. The page has no
    // way to build markup out of a string, and that is the whole defence.
    func testNothingTurnsGraphDataIntoMarkup() {
        for escape in ["innerHTML", "dangerouslySetInnerHTML", "document.write", "insertAdjacentHTML", "eval(", "new Function("] {
            XCTAssertFalse(page.contains(escape), "\(escape) can turn a screen's name into markup")
        }
    }

    // A card leaves the map only when the graph does. React Flow deletes the
    // selected node on Backspace by default, and a card vanishing off the canvas
    // reads as «этот экран удалён из карты».
    func testACardIsNeverRemovedFromTheCanvas() {
        XCTAssertTrue(
            matches(#"deleteKeyCode\s*=\s*\$\{\s*null\s*\}"#, page),
            "the delete key must be disarmed"
        )
        XCTAssertTrue(
            page.contains(#"change.type !== "remove""#),
            "a removal reported by the canvas must not be applied"
        )
    }

    // A card is dragged, never wired to another one: the map draws what the
    // crawl found. An invisible handle is not an inert one — it still won the
    // mousedown, and the drag drew a connection instead of moving the card.
    func testCardsAreDraggedNotWired() {
        XCTAssertTrue(matches(#"nodesConnectable\s*=\s*\$\{\s*false\s*\}"#, page), "connecting must be off")
        XCTAssertTrue(page.contains(#"pointerEvents: "none""#), "a hidden handle must not take the pointer")
    }

    // The haystack holds what a person can be looking for, and nothing else.
    // Sweeping the whole record in — depth, visit counts, `firstSeenAt`, the
    // screenshot path — made «png», «2026» and «0» match every card there is.
    func testSearchLooksOnlyAtWhatAPersonCanLookFor() {
        let groups = region(from: "const SEARCH_GROUPS", to: "function searchEntry", in: page)
        XCTAssertFalse(groups.isEmpty, "the searchable fields must be declared in one place")

        for bookkeeping in ["firstSeenAt", "screenshot", "visits", "depth", "states", "fingerprint",
                            "Object.entries", "Object.values"] {
            XCTAssertFalse(groups.contains(bookkeeping), "\(bookkeeping) is bookkeeping, not something to search by")
        }
        for searchable in ["node.title", "node.key", "node.id", "node.groups", "node.deeplinks",
                           "node.localizationKeys", "node.triedActionKeys", "node.actionKeys"] {
            XCTAssertTrue(groups.contains(searchable), "\(searchable) is what a person searches by")
        }
        XCTAssertFalse(page.contains("прочее"), "every match must be filed under a group that names it")
    }

    // The cursor into the results names a card. As a place in the list it walked
    // off on its own: the crawl inserts a new match ahead of the parked one and
    // the viewport jumps to a screen nobody asked for.
    func testTheSearchCursorIsACardNotAPosition() {
        XCTAssertTrue(page.contains("matchCursor"), "the cursor must be held as a node id")
        XCTAssertFalse(page.contains("matchIndex"), "a positional cursor is reshuffled under the user")
    }

    // Both requests read what came back. `fetch` rejects on a broken wire and
    // not on a refusal, so an error envelope parsed as a status empties the
    // canvas, and a 400 from an unwritable .simtool/explore/ passes for a save.
    func testEveryRequestChecksWhatCameBack() {
        XCTAssertEqual(
            count("await fetch(", in: page), count("!response.ok", in: page),
            "every request must check the status it got"
        )
        XCTAssertTrue(page.contains("setError(null)"), "a poll that succeeded must clear the banner")
        XCTAssertTrue(page.contains("setLayoutError("), "a refused save must say so")
        XCTAssertTrue(page.contains("Number.isFinite"), "a NaN position must not be sent for the server to reject")
    }

    // A refusal the same body will collect again — a layout.json a newer
    // simtool wrote (409), a position the server will not take (400) — must not
    // be re-sent every five seconds for the life of the tab.
    func testARefusedSaveIsNotRetriedForever() {
        XCTAssertTrue(page.contains("SAVE_ATTEMPTS"), "the retries must be bounded")
        XCTAssertTrue(
            matches(#"response\.status >= 400 && response\.status < 500"#, page),
            "a refusal about this very body must not be retried at all"
        )
        XCTAssertTrue(page.contains("saveAttempts.current = 0"), "a fresh drag must get the attempts back")
    }

    // The map and the arrangement of it are two subjects. A save that was
    // refused used to lead the one header line, which put «повторяю» over the
    // crawl's progress — and over the server's own error — for good.
    func testAnUnsavedArrangementDoesNotSilenceTheRestOfTheHeader() {
        XCTAssertTrue(page.contains(#"id="layout""#), "the arrangement needs a line of its own")
        XCTAssertTrue(page.contains(#"getElementById("layout")"#), "…that something writes to")
        XCTAssertFalse(page.contains("error || layoutError"), "a refused save must not outrank what the server reports")
        XCTAssertTrue(page.contains(".msg.warn"), "an unsaved arrangement is not a map that failed to load")
    }

    // The canvas folds the parallel transitions between a pair of screens into
    // one arrow. A header saying «19 переходов» over 11 arrows is a bug report
    // waiting to happen — the server keeps the same invariant on its side.
    func testTheHeaderCountsTheArrowsTheCanvasDraws() {
        XCTAssertTrue(page.contains("counted(flow.edges.length"), "the count must come from what is drawn")
        XCTAssertFalse(page.contains("graph.stats.transitions"), "the server's edge count is not the arrow count")
        XCTAssertTrue(page.contains("parallel.length - 1"), "a fold must be visible even when the labels read alike")
    }

    // The crawl overwrites a screen's PNG as it walks the screen again, and the
    // id is the only piece of graph data that reaches a URL at all.
    func testTheScreenshotURLIsVersionedAndEscaped() {
        XCTAssertEqual(count("/api/v1/explore/shot", in: page), 1, "one place builds the URL, so one place escapes it")
        let shot = region(from: "function shotUrl", to: "function Shot", in: page)
        XCTAssertTrue(shot.contains("encodeURIComponent(node.id)"), "the id must be escaped into the query string")
        XCTAssertTrue(shot.contains("&v="), "an unversioned URL is answered from the browser cache forever")
        XCTAssertTrue(page.contains("нет скриншота"), "a screen with no PNG must say so instead of showing a broken image")
    }

    // Three reasons for an empty canvas, and «Карта пуста» is right about one.
    func testAnEmptyCanvasSaysWhichKindOfEmpty() {
        XCTAssertTrue(page.contains("Загружаю карту"), "the first status in flight is not an empty map")
        XCTAssertTrue(page.contains("Карта пуста"), "an actually empty map must still say what to do")
        XCTAssertTrue(page.contains("!loaded"), "the two must be told apart by whether a status has arrived")
    }

    // React, React Flow and its stylesheet come off the network: a deliberate
    // trade for having no build step. What must not happen is the page going
    // black about it, or an exception in the render taking the tab with it.
    func testThePageDiagnosesItsOwnFailureToLoad() {
        XCTAssertTrue(page.contains("__cartographerBoot"), "missing dependencies must be reported by the page itself")
        XCTAssertTrue(page.contains(#"id="boot""#), "the diagnostic needs somewhere to be shown")
        XCTAssertTrue(page.contains("<noscript"), "a page that needs JavaScript must say so without it")
        XCTAssertTrue(page.contains("getDerivedStateFromError"), "a render exception must not unmount the whole tab")
        XCTAssertTrue(page.contains(#"rel="icon""#), "an inline icon keeps the tab from asking the server for a favicon")
    }

    // The whole map is the first choice in the same row as the features, so
    // returning to it is the same gesture as switching between them — not a
    // mode with its own way out.
    func testCanvasOffersTheWholeMapAlongsideTheFeatures() {
        XCTAssertTrue(page.contains("Вся карта"), "missing the whole-map choice")
        XCTAssertTrue(page.contains("group-chip"), "missing the feature switcher")
        XCTAssertTrue(page.contains("setActiveGroupKey(null)"), "the whole map must be reachable in one click")
        XCTAssertTrue(page.contains("group.displayable"), "one-screen groups must stay unlisted")
        XCTAssertTrue(page.contains("group.members.length"), "a chip must show how many screens it holds")
    }

    // Names are given by an agent and cannot be corrected by hand, so the key a
    // chip really filters by stays readable next to whatever it is called.
    func testChipShowsTheNameWithTheKeyBesideIt() {
        XCTAssertTrue(page.contains("${group.label}"), "a chip shows the group's label")
        XCTAssertTrue(page.contains("group-key"), "the underlying key must stay visible")
        XCTAssertTrue(page.contains("group.staleName"), "a name given for a since-changed group must be marked")
    }

    // A feature is drawn as its connecting subtree: the screens of the group
    // plus the transit screens that hold the sequence together.
    func testFeatureViewDrawsTheConnectingSubtree() {
        XCTAssertTrue(page.contains("function subtreeLayout"), "missing the feature layout")
        XCTAssertTrue(page.contains("activeGroup.bridges"), "bridges must be drawn with the group")
        XCTAssertTrue(
            page.contains("[...bridges, activeGroup.entry]"),
            "the doors lead the layout so the way into the flow reads left to right"
        )
        XCTAssertTrue(page.contains(".react-flow__node.bridge"), "bridges must be told apart from the group's own screens")
        XCTAssertTrue(page.contains("draggable: false"), "a derived view must not be rearranged by hand")
        // Derived, but not re-derived: `flow` is a new object on every poll, so
        // both derivations below it must hand the canvas back the cards it
        // already has — the whole map is not the only view someone watches a
        // crawl in. Whether they really do is a browser question (see above).
        XCTAssertTrue(
            count("keptCard(", in: page) >= 3,
            "the derived view and the query decoration must both keep the cards they built"
        )
    }

    // Coming back must land where the user left the map — including when a query
    // was owning the viewport at the moment they asked to come back — and a
    // crawl filling an open feature must not move the view out from under them.
    func testViewportIsPreservedAcrossSwitchingAndGrowth() {
        XCTAssertTrue(page.contains("wholeMapViewport"), "missing the saved viewport")
        XCTAssertTrue(page.contains("instance.setViewport(wholeMapViewport.current"), "returning must restore, not re-fit")
        XCTAssertTrue(page.contains("restorePending"), "a restore deferred by an active query must not be dropped")
        XCTAssertTrue(
            matches(#"activeGroupKey !== null && !switched"#, page),
            "growth inside an open feature must leave the viewport alone"
        )
    }

    // Search keeps answering about what is on screen, but never swallows hits
    // that fell outside the open feature.
    func testSearchIsScopedToTheOpenViewAndReportsHitsOutsideIt() {
        XCTAssertTrue(page.contains("const outsideMatches"), "hits outside the view must be counted")
        XCTAssertTrue(page.contains("вне фичи"), "hits outside the view must be offered, not hidden")
    }

    // A screen assembled from several features belongs to each of them, and the
    // drawer is where that stops being surprising.
    func testDrawerListsEveryFeatureAScreenBelongsTo() {
        XCTAssertTrue(page.contains("Фичи"), "missing the feature list on a screen")
        XCTAssertTrue(page.contains("groupLabels.get(key) || key"), "a drawer chip reads by the flow's label, not its key")
    }
}
