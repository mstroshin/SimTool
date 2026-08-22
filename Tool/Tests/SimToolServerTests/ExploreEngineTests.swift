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

    // MARK: screen identity across states

    // One screen in different states (spinner, loaded list) changes its
    // structural fingerprint but keeps its dominant prefix — the key that
    // holds the canvas at one card per screen.
    func testScreenKeyIsStableAcrossStatesOfOneScreen() {
        let loading = [
            node(id: "MainScreen-Spinner", type: "Other", depth: 3),
            node(id: "MainScreen-Balance", type: "StaticText", depth: 3),
            node(id: "MainScreen-TransferButton", type: "Button", depth: 3),
        ]
        let loaded = [
            node(id: "MainScreen-Balance", type: "StaticText", depth: 3),
            node(id: "MainScreen-TransferButton", type: "Button", depth: 3),
            node(id: "MainScreen-HistoryCell", type: "Cell", depth: 4),
        ]
        XCTAssertNotEqual(ExploreEngine.fingerprint(of: loading), ExploreEngine.fingerprint(of: loaded))
        XCTAssertEqual(ExploreEngine.screenKey(of: loading), "MainScreen")
        XCTAssertEqual(ExploreEngine.screenKey(of: loaded), "MainScreen")
    }

    // Without a dominant prefix there is no safe way to say "same screen",
    // so the caller falls back to the fingerprint and nothing merges.
    func testScreenKeyIsNilWithoutADominantPrefix() {
        XCTAssertNil(ExploreEngine.screenKey(of: [
            node(id: "com.apple.settings.general", type: "Cell", depth: 3),
            node(id: "chevron.right", type: "Image", depth: 4),
            node(id: "OneOff-Button", type: "Button", depth: 3),
        ]))
        XCTAssertNil(ExploreEngine.screenKey(of: []))
    }

    // A unique near-full-screen identifier is the screen's own container and
    // beats every other heuristic: the passcode screen has no dominant prefix
    // (Digit1…Digit0 share nothing), yet must be one node in every state.
    func testScreenKeyPrefersTheUniqueRootContainerId() {
        var snapshot = [
            node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "MSMCheckPasscodeScreen", type: "Group", depth: 6, frame: [0, 0, 402, 874]),
        ]
        for digit in 0...9 {
            snapshot.append(node(id: "Digit\(digit)", type: "Button", depth: 8, frame: [61, 380 + digit * 40, 72, 72]))
        }
        XCTAssertEqual(ExploreEngine.screenKey(of: snapshot), "MSMCheckPasscodeScreen")
        // A later state (delete button appeared) keeps the key.
        snapshot.append(node(id: "DeleteButton", type: "Button", depth: 8, frame: [269, 692, 72, 72]))
        XCTAssertEqual(ExploreEngine.screenKey(of: snapshot), "MSMCheckPasscodeScreen")
    }

    // Generic wrappers (TouchRecognizingView) stretch full-screen on every
    // screen of the app — but they repeat, and a repeated id is one design
    // element, not a screen name. Gluing screens together by it would fold
    // the whole app into one node.
    func testScreenKeyRejectsRepeatedFullScreenWrappers() {
        let snapshot = [
            node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "TouchRecognizingView", type: "Group", depth: 2, frame: [0, 0, 402, 874]),
            node(id: "TouchRecognizingView", type: "Group", depth: 3, frame: [0, 0, 402, 874]),
            node(id: "TouchRecognizingView", type: "Group", depth: 4, frame: [0, 100, 402, 700]),
            node(id: "OneOff-Button", type: "Button", depth: 5, frame: [20, 300, 100, 44]),
        ]
        XCTAssertNil(ExploreEngine.screenKey(of: snapshot))
    }

    // A form with no identifiers of its own must not split into a node per
    // keyboard/validation state: the navigation-bar title is static per
    // screen and holds it together.
    func testScreenKeyFallsBackToTheNavbarTitle() {
        let base = [
            node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: nil, label: "Create link", type: "StaticText", depth: 2, frame: [150, 60, 100, 24]),
        ]
        let withKeyboard = base + [
            node(id: "KeyboardKey-a", type: "Button", depth: 7, frame: [10, 700, 30, 40]),
        ]
        XCTAssertEqual(ExploreEngine.screenKey(of: base), "navbar:Create link")
        XCTAssertEqual(ExploreEngine.screenKey(of: withKeyboard), "navbar:Create link")
    }

    // Design-system components stamp their ids on every screen: a form with
    // one branded text field already carries HolaTextField-TextField,
    // -PlaceholderText, -ClearButton — three distinct ids that would win the
    // dominant-prefix vote and name the screen after the component. Component
    // vocabulary in the prefix is disqualifying; the screen's own namespace,
    // when present, wins even with fewer ids.
    func testScreenKeyIgnoresComponentNamespacePrefixes() {
        let form = [
            node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "HolaTextField-TextField", type: "TextField", depth: 8),
            node(id: "HolaTextField-PlaceholderText", type: "StaticText", depth: 8),
            node(id: "HolaTextField-ClearButton", type: "Button", depth: 8),
            node(id: "HolaButtonStack-FirstButton", type: "Button", depth: 7),
        ]
        XCTAssertNil(ExploreEngine.screenKey(of: form))
        let named = form + [
            node(id: "RestoreAccessScreen-OldNumber", type: "Group", depth: 6),
            node(id: "RestoreAccessScreen-NewNumber", type: "Group", depth: 6),
            node(id: "RestoreAccessScreen-Curp", type: "Group", depth: 6),
        ]
        XCTAssertEqual(ExploreEngine.screenKey(of: named), "RestoreAccessScreen")
    }

    // A full-screen unique id can still be a control (a screen-sized branded
    // text editor): controls make poor screen names, so the crawl looks past
    // them at the next heuristic.
    func testRootContainerIgnoresComponentNamedNodes() {
        let snapshot = [
            node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "HolaTextField", type: "Group", depth: 5, frame: [0, 0, 402, 874]),
            node(id: nil, label: "Tell us what happened to your old phone number", type: "StaticText", depth: 6, frame: [40, 138, 320, 41]),
        ]
        XCTAssertEqual(ExploreEngine.screenKey(of: snapshot), "headline:Tell us what happened to your old phone number")
    }

    // A brand prefix marks design-system vocabulary even when the suffix list
    // has never heard of the coinage: HolaTextFieldSumm-* would win the
    // dominant-prefix vote on any amount form. The screen's own namespace,
    // when present, still wins.
    func testScreenKeyIgnoresBrandPrefixedComponents() {
        let form = [
            node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "HolaTextFieldSumm-Currency", type: "StaticText", depth: 8),
            node(id: "HolaTextFieldSumm-Value", type: "TextField", depth: 8),
            node(id: "HolaTextFieldSumm-Hint", type: "StaticText", depth: 8),
        ]
        XCTAssertNil(ExploreEngine.screenKey(of: form))
        let named = form + [
            node(id: "AmountInputScreen-ProviderCard", type: "Group", depth: 6),
            node(id: "AmountInputScreen-Continue", type: "Button", depth: 6),
            node(id: "AmountInputScreen-SourcePicker", type: "Group", depth: 6),
        ]
        XCTAssertEqual(ExploreEngine.screenKey(of: named), "AmountInputScreen")
    }

    // Identifier-namespace enums (…Ids / …Identifiers) name the container of
    // ids, not a screen: a widget with three AccountUpgradeWidgetIds-* nodes
    // must not become the "AccountUpgradeWidgetIds" screen.
    func testScreenKeyIgnoresIdentifierNamespaceSuffixes() {
        let widget = [
            node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "AccountUpgradeWidgetIds-Widget", type: "Group", depth: 6),
            node(id: "AccountUpgradeWidgetIds-HolaHeader", type: "Group", depth: 7),
            node(id: "AccountUpgradeWidgetIds-Button", type: "Button", depth: 7),
        ]
        XCTAssertNil(ExploreEngine.screenKey(of: widget))
        let named = widget + [
            node(id: "ProfileScreen-Avatar", type: "Group", depth: 6),
            node(id: "ProfileScreen-PersonalDetailsHolaCell", type: "Group", depth: 6),
            node(id: "ProfileScreen-LanguageHolaCell", type: "Group", depth: 6),
        ]
        XCTAssertEqual(ExploreEngine.screenKey(of: named), "ProfileScreen")
    }

    // A reusable full-screen template carries one container id across many
    // features: two different onboardings hosted by HolaOnboardingScreen are
    // two screens, so the brand-prefixed container must not become their
    // shared key — with no other signal (the template's title sits below the
    // headline zone) the key is nil and the fingerprint keeps them apart.
    func testRootContainerIgnoresBrandPrefixedTemplates() {
        func onboarding(_ title: String) -> [AccessibilityFlatNode] {
            [
                node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
                node(id: "HolaOnboardingScreen", type: "Group", depth: 5, frame: [0, 0, 402, 874]),
                node(id: "HolaOnboardingScreen-Image", type: "Image", depth: 6, frame: [40, 142, 322, 322]),
                node(id: nil, label: title, type: "StaticText", depth: 6, frame: [40, 572, 322, 41]),
            ]
        }
        XCTAssertNil(ExploreEngine.screenKey(of: onboarding("Defer your operations")))
        XCTAssertNil(ExploreEngine.screenKey(of: onboarding("Set a monthly spending limit")))
    }

    // The "lost access" screen as AXe reports it: no full-screen id, only
    // component namespaces, a navbar-window title too long for the navbar
    // heuristic — the headline (topmost title-sized text) is the human name,
    // and it beats the taller two-line bullet below it.
    func testScreenKeyFallsBackToTheHeadline() {
        let snapshot = [
            node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "BackButton", label: "Back", type: "Button", depth: 8, frame: [16, 62, 44, 44]),
            node(id: "HolaScreenTitle-Title", label: "How to restore access with a new phone number", type: "StaticText", depth: 12, frame: [20, 136, 362, 122]),
            node(id: "HolaTextBulletList-Text", label: "Enter your old phone number and your CURP", type: "StaticText", depth: 12, frame: [72, 282, 310, 41]),
            node(id: "HolaTextBulletList-Text", label: "Enter your new phone number", type: "StaticText", depth: 12, frame: [72, 348, 310, 20]),
            node(id: "HolaButtonStack-FirstButton", label: "Continue", type: "Button", depth: 11, frame: [20, 764, 362, 56]),
        ]
        XCTAssertEqual(
            ExploreEngine.screenKey(of: snapshot),
            "headline:How to restore access with a new phone number"
        )
        // 46 characters — under the display cap, shown whole.
        XCTAssertEqual(
            ExploreEngine.title(for: snapshot, fallback: "x"),
            "How to restore access with a new phone number"
        )
        XCTAssertEqual(ExploreEngine.displayTitle(String(repeating: "a", count: 60)).count, 48)
    }

    // Custom tab bars read as RadioButton groups, and app widgets as Groups
    // with an identifier — both are doors, not decoration. Screen-sized
    // containers and anonymous groups stay out.
    func testActionsIncludeTabBarRadioButtonsAndIdentifiedGroups() {
        let snapshot = [
            node(id: nil, type: "Other", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "platform_tabbar_invite", type: "RadioButton", depth: 3, frame: [206, 700, 101, 54]),
            node(id: "TouchRecognizingView", type: "Group", depth: 4, frame: [20, 300, 171, 116]),
            node(id: "FullscreenContainer", type: "Group", depth: 2, frame: [0, 0, 402, 874]),
            node(id: nil, type: "Group", depth: 5, frame: [30, 500, 100, 50]),
        ]
        let actions = ExploreEngine.actions(from: snapshot)
        XCTAssertEqual(actions.map(\.targetId), ["platform_tabbar_invite", "TouchRecognizingView"])
    }

    // The tree lists content far below the fold, but only what is on screen
    // can be tapped: overflow earns the state a pair of scroll probes.
    func testActionsAppendScrollProbesWhenContentOverflows() {
        let overflowing = [
            node(id: nil, type: "Other", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "MainScreen-TransferButton", type: "Button", depth: 3, frame: [20, 300, 100, 44]),
            node(id: "Ids.cell-99", type: "Cell", depth: 4, frame: [20, 980, 362, 86]),
        ]
        let actions = ExploreEngine.actions(from: overflowing)
        XCTAssertEqual(actions.filter(\.isScroll).map(\.key), ["scroll:1", "scroll:2"])
        XCTAssertTrue(actions.filter(\.isScroll).allSatisfy { $0.endY < $0.y })

        let fitting = Array(overflowing.prefix(2))
        XCTAssertTrue(ExploreEngine.actions(from: fitting).filter(\.isScroll).isEmpty)
    }

    // A grid of dozens of distinct tappables (avatar pickers, option lists)
    // is capped so one screen cannot eat the whole step budget — and the tab
    // bar jumps the queue: tabs are the widest doors in the app.
    func testActionsCapGridsAndPutTabsFirst() {
        var snapshot = [node(id: nil, type: "Other", depth: 0, frame: [0, 0, 402, 874])]
        for first in "abcde" {
            for second in "abcdefgh" {
                snapshot.append(node(id: "avatar-\(first)\(second)", type: "Group", depth: 5, frame: [20, 100, 44, 44]))
            }
        }
        snapshot.append(node(id: "platform_tabbar_pay", type: "RadioButton", depth: 3, frame: [116, 795, 101, 54]))
        let actions = ExploreEngine.actions(from: snapshot)
        XCTAssertEqual(actions.count, ExploreEngine.maxActionsPerState)
        XCTAssertEqual(actions.first?.targetId, "platform_tabbar_pay")
    }

    // The bottom edge belongs to the home-indicator gesture: a tap there
    // opens the app switcher, and the crawler leaves the app entirely.
    func testActionsSkipTheHomeIndicatorZone() {
        let snapshot = [
            node(id: nil, type: "Other", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "TabBar-Home", type: "Button", depth: 3, frame: [20, 800, 60, 40]),
            node(id: "EdgeButton", type: "Button", depth: 3, frame: [150, 850, 100, 20]),
        ]
        let actions = ExploreEngine.actions(from: snapshot)
        XCTAssertEqual(actions.map(\.targetId), ["TabBar-Home"])
    }

    // The ax tree carries lower window layers (the presenting screen behind
    // a sheet); the screen's own strings live in its container's DFS subtree.
    func testContentLabelsComeFromTheRootContainerSubtree() {
        let withContainer = [
            node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "ProfileScreen", type: "Group", depth: 2, frame: [0, 0, 402, 874]),
            node(id: nil, label: "Personal details", type: "StaticText", depth: 3),
            node(id: nil, label: "Balance behind the sheet", type: "StaticText", depth: 1),
        ]
        XCTAssertEqual(ExploreEngine.contentLabels(of: withContainer), ["Personal details"])
        // No container — every visible string counts.
        let flat = [node(id: nil, label: "Hello", type: "StaticText", depth: 1)]
        XCTAssertEqual(ExploreEngine.contentLabels(of: flat), ["Hello"])
    }

    // MARK: loading detection

    // Skeletons settle structurally long before the backend answers; the
    // crawler must keep waiting instead of screenshotting placeholders.
    func testIsLoadingSpotsSkeletonsAndSpinners() {
        XCTAssertTrue(ExploreEngine.isLoading([
            node(id: "HolaSkeleton", type: "Group", depth: 4),
        ]))
        XCTAssertTrue(ExploreEngine.isLoading([
            node(id: nil, type: "ActivityIndicator", depth: 3),
        ]))
        XCTAssertFalse(ExploreEngine.isLoading([
            node(id: "MainScreen-Balance", label: "Loading history", type: "StaticText", depth: 3),
        ]))
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

    // MARK: untried actions

    func testUntriedActionsAreReadFromTheKeySetsNotTheCounters() {
        let screen = screenNode(
            actionsTotal: 3, actionsTried: 3,
            actionKeys: ["tab", "profile", "card"], triedActionKeys: ["tab", "profile"]
        )
        // The counters agree; the keys do not, and the keys are the truth.
        XCTAssertTrue(ExploreEngine.hasUntriedActions(screen))
    }

    func testAScreenWhoseEveryCataloguedTapWasMadeIsFinished() {
        let screen = screenNode(
            actionsTotal: 2, actionsTried: 2,
            actionKeys: ["tab", "profile"], triedActionKeys: ["profile", "tab"]
        )
        XCTAssertFalse(ExploreEngine.hasUntriedActions(screen))
    }

    // Stores written before the keys were kept summed both counters per state,
    // so one button in two states counted twice among the totals and once among
    // the tried — the tried count could even overshoot the total. Neither
    // direction may be read as "nothing left to tap".
    func testALegacyStoreWithMismatchedCountersIsTreatedAsUnfinished() {
        XCTAssertTrue(ExploreEngine.hasUntriedActions(
            screenNode(actionsTotal: 35, actionsTried: 37, actionKeys: nil, triedActionKeys: ["a"])
        ))
        XCTAssertTrue(ExploreEngine.hasUntriedActions(
            screenNode(actionsTotal: 69, actionsTried: 24, actionKeys: nil, triedActionKeys: nil)
        ))
        XCTAssertFalse(
            ExploreEngine.hasUntriedActions(
                screenNode(actionsTotal: 8, actionsTried: 8, actionKeys: nil, triedActionKeys: nil)
            ),
            "counters that agree are all such a store has to say"
        )
    }

    // MARK: helpers

    private func screenNode(
        actionsTotal: Int,
        actionsTried: Int,
        actionKeys: [String]?,
        triedActionKeys: [String]?
    ) -> ExploreScreenNode {
        ExploreScreenNode(
            id: "s-main",
            title: "MainScreen",
            fingerprint: "s-main",
            key: "MainScreen",
            screenshot: "shots/s-main.png",
            depth: 0,
            visits: 1,
            states: 1,
            actionsTotal: actionsTotal,
            actionsTried: actionsTried,
            firstSeenAt: "2026-08-21T10:00:00Z",
            triedActionKeys: triedActionKeys,
            actionKeys: actionKeys
        )
    }

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
