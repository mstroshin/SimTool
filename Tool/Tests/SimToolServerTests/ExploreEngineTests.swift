import XCTest
@testable import SimToolServer
import SimToolCore

final class ExploreEngineTests: XCTestCase {
    // MARK: fingerprint

    // List indices are content, not structure: cell-3 today is cell-17
    // tomorrow, and a screen must not multiply because its list scrolled.
    func testNormalizeIdentifierCollapsesDigitRuns() {
        XCTAssertEqual(ExploreEngine.normalizeIdentifier("Ids.cell-3"), "Ids.cell-N")
        XCTAssertEqual(ExploreEngine.normalizeIdentifier("row12.item345"), "rowN.itemN")
        XCTAssertEqual(ExploreEngine.normalizeIdentifier("plain"), "plain")
    }

    func testFingerprintIgnoresLabelsValuesAndCellIndices() {
        let morning = [
            node(id: "MainScreen-Balance", label: "1 234 ₽", type: "StaticText", depth: 3),
            node(id: "Ids.cell-0", label: "Кофе", type: "Cell", depth: 4),
            node(id: "Ids.cell-1", label: "Метро", type: "Cell", depth: 4),
        ]
        let evening = [
            node(id: "MainScreen-Balance", label: "9 ₽", type: "StaticText", depth: 3),
            node(id: "Ids.cell-7", label: "Аренда", type: "Cell", depth: 4),
        ]
        XCTAssertEqual(ExploreEngine.fingerprint(of: morning), ExploreEngine.fingerprint(of: evening))
    }

    func testFingerprintSeparatesScreensWithDifferentIdentifiers() {
        let main = [node(id: "MainScreen-TransferButton", type: "Button", depth: 3)]
        let settings = [node(id: "Settings-LanguageCell", type: "Cell", depth: 3)]
        XCTAssertNotEqual(ExploreEngine.fingerprint(of: main), ExploreEngine.fingerprint(of: settings))
    }

    // MARK: action catalog

    func testActionsKeepTappablesAndDropDisabledAndDenylisted() {
        let snapshot = [
            node(id: nil, type: "Other", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "MainScreen-TransferButton", label: "Перевести", type: "Button", depth: 3, frame: [20, 300, 100, 44]),
            node(id: "MainScreen-DisabledButton", type: "Button", depth: 3, frame: [20, 360, 100, 44], enabled: false),
            node(id: "Settings-LogoutButton", label: "Выйти", type: "Button", depth: 3, frame: [20, 420, 100, 44]),
            node(id: "MainScreen-Header", label: "Главная", type: "StaticText", depth: 2, frame: [0, 60, 402, 30]),
            node(id: "MainScreen-Offscreen", type: "Button", depth: 3, frame: [500, 300, 100, 44]),
        ]
        let actions = ExploreEngine.actions(from: snapshot)
        XCTAssertEqual(actions.map(\.targetId), ["MainScreen-TransferButton"])
        // Tap lands on the frame center, in points.
        XCTAssertEqual(actions[0].x, 70)
        XCTAssertEqual(actions[0].y, 322)
    }

    // A list of N same-template cells is one design, not N screens to probe:
    // only its first and last cells survive.
    func testActionsLimitRepeatedCellTemplatesToFirstAndLast() {
        var snapshot = [node(id: nil, type: "Other", depth: 0, frame: [0, 0, 402, 874])]
        for index in 0..<8 {
            snapshot.append(node(id: "Ids.cell-\(index)", type: "Cell", depth: 4, frame: [0, 100 + index * 60, 402, 56]))
        }
        let actions = ExploreEngine.actions(from: snapshot)
        XCTAssertEqual(actions.map(\.targetId), ["Ids.cell-0", "Ids.cell-7"])
    }

    // Back/dismiss vocabulary matters twice: those taps run last, and the
    // transitions they cause never become edges — the map draws only forward.
    func testBackActionsAreRecognizedAndDeprioritized() {
        XCTAssertTrue(ExploreEngine.isBack(id: "navbar.close", label: nil))
        XCTAssertTrue(ExploreEngine.isBack(id: nil, label: "Назад"))
        XCTAssertTrue(ExploreEngine.isBack(id: nil, label: "Cancel"))
        XCTAssertTrue(ExploreEngine.isBack(id: nil, label: "Отмена"))
        XCTAssertFalse(ExploreEngine.isBack(id: "MainScreen-TransferButton", label: "Перевести"))
    }

    // The navigation-bar back button is titled after the previous screen
    // ("< Settings"), so it can only be recognized by where it sits.
    func testTopLeftNavbarButtonCountsAsBackWhateverItsLabel() {
        let snapshot = [
            node(id: nil, type: "Other", depth: 0, frame: [0, 0, 402, 874]),
            node(id: nil, label: "Settings", type: "Button", depth: 2, frame: [10, 56, 70, 40]),
            node(id: "MainScreen-SettingsButton", label: "Settings", type: "Button", depth: 3, frame: [150, 400, 100, 44]),
        ]
        let actions = ExploreEngine.actions(from: snapshot)
        XCTAssertEqual(actions.map(\.isBack), [true, false])
    }

    // MARK: naming

    func testTitlePrefersTheDominantIdentifierPrefix() {
        let snapshot = [
            node(id: "MainScreen-Balance", type: "StaticText", depth: 3),
            node(id: "MainScreen-TransferButton", type: "Button", depth: 3),
            node(id: "MainScreen-HistoryCell", type: "Cell", depth: 4),
            node(id: "navbar.title", label: "Главная", type: "StaticText", depth: 2),
        ]
        XCTAssertEqual(ExploreEngine.title(for: snapshot, fallback: "x"), "MainScreen")
    }

    func testTitleFallsBackToNavbarTextThenToCallerFallback() {
        let withNavbar = [
            node(id: nil, label: "Настройки", type: "StaticText", depth: 2, frame: [140, 56, 120, 24]),
        ]
        XCTAssertEqual(ExploreEngine.title(for: withNavbar, fallback: "x"), "Настройки")
        XCTAssertEqual(ExploreEngine.title(for: [], fallback: "Экран ab12"), "Экран ab12")
    }

    // Settings-app reality check: reverse-DNS identifiers ("com.apple.…"),
    // SF Symbols ("chevron.right") and the status-bar clock are conventions,
    // not screen names.
    func testTitleSkipsReverseDNSPrefixesSymbolsAndStatusBarText() {
        let snapshot = [
            node(id: "com.apple.settings.general", type: "Cell", depth: 3),
            node(id: "com.apple.settings.display", type: "Cell", depth: 3),
            node(id: "com.apple.settings.sound", type: "Cell", depth: 3),
            node(id: "chevron.right", type: "Image", depth: 4),
            node(id: "chevron.right", type: "Image", depth: 4),
            node(id: "chevron.right", type: "Image", depth: 4),
            node(id: nil, label: "19:22", type: "StaticText", depth: 1, frame: [30, 14, 60, 20]),
            node(id: nil, label: "General", type: "StaticText", depth: 2, frame: [150, 60, 100, 24]),
        ]
        XCTAssertEqual(ExploreEngine.title(for: snapshot, fallback: "x"), "General")
    }

    // MARK: helpers

    private func node(
        id: String?,
        label: String? = nil,
        type: String?,
        depth: Int,
        frame: [Int]? = nil,
        enabled: Bool? = nil
    ) -> AccessibilityFlatNode {
        AccessibilityFlatNode(id: id, label: label, value: nil, title: nil, type: type, depth: depth, frame: frame, enabled: enabled)
    }
}
