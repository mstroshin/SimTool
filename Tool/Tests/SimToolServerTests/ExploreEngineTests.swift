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

    // Two elements framed alike are one tap: the same pixel, the same gesture,
    // the same result. Template limiting cannot fold them — their identifiers
    // differ — so each spent a step re-tapping what the one before it had
    // already tapped. A real app hands out plenty: every cell wrapped in a
    // same-sized `TouchRecognizingView`, and a screen carrying a SceneKit
    // animation publishing the scene's lights as identically framed Groups.
    func testOneTapPointIsProbedOnce() {
        var snapshot = [node(id: nil, type: "Other", depth: 0, frame: [0, 0, 402, 874])]
        // The scene's lights and geometry, all reported at one rect.
        for name in ["left spot", "right spot", "front line", "CUBE", "ambient"] {
            snapshot.append(node(id: name, type: "Group", depth: 20, frame: [124, 200, 154, 147]))
        }
        // A cell and the gesture view wrapping it, in the order a tree lists
        // them: the container first, and it carries the better name.
        snapshot.append(node(id: "ProfileScreen-PlataPlusHolaCell", type: "Group", depth: 8, frame: [20, 400, 362, 56]))
        snapshot.append(node(id: "TouchRecognizingView", type: "Group", depth: 9, frame: [20, 400, 362, 56]))
        // A control of its own, at a rect nothing else claims.
        snapshot.append(node(id: "ProfileScreen-SettingsCell", type: "Cell", depth: 8, frame: [20, 500, 362, 56]))

        let actions = ExploreEngine.actions(from: snapshot)
        XCTAssertEqual(
            actions.map(\.targetId),
            ["left spot", "ProfileScreen-PlataPlusHolaCell", "ProfileScreen-SettingsCell"]
        )
    }

    // The point a candidate is folded into is its own, not the screen's: two
    // controls of one size on different rows stay two probes.
    func testCandidatesAtDifferentPointsAreAllKept() {
        let snapshot = [
            node(id: nil, type: "Other", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "First", type: "Cell", depth: 4, frame: [20, 100, 362, 56]),
            node(id: "Second", type: "Cell", depth: 4, frame: [20, 160, 362, 56]),
        ]
        XCTAssertEqual(ExploreEngine.actions(from: snapshot).map(\.targetId), ["First", "Second"])
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

    // A tab is told from every other selectable control by its subrole, and by
    // nothing else: the type says RadioButton for a tab and for a form's radio
    // group both, so a settings screen's "Español / English" pair must not
    // spawn a root of the map per option.
    func testOnlyTheTabButtonSubroleMarksAnActionAsATab() {
        let snapshot = [
            node(id: nil, type: "Other", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "platform_tabbar_invest", type: "RadioButton", subrole: "AXTabButton", depth: 3, frame: [166, 764, 69, 49]),
            node(id: "settings-language-spanish", type: "RadioButton", depth: 4, frame: [20, 300, 362, 44]),
            node(id: "MainScreen-TransferButton", type: "Button", depth: 4, frame: [20, 400, 100, 44]),
        ]
        let byId = Dictionary(
            ExploreEngine.actions(from: snapshot).map { ($0.targetId ?? $0.key, $0.isTab) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(byId["platform_tabbar_invest"], true)
        XCTAssertEqual(byId["settings-language-spanish"], false)
        XCTAssertEqual(byId["MainScreen-TransferButton"], false)
    }

    // MARK: system dialogs

    // Measured on a booted simulator: iOS presents a permission alert in its
    // own process, so the snapshot's root names nothing and the alert itself
    // comes back as a `Sheet` whose label is the question, with the buttons in
    // its subtree. Read off exactly that, because a crawl that took it for
    // «the tap left the app» relaunched into the same alert until the run died.
    func testASystemPermissionAlertIsReadOffTheSnapshotWithItsButtons() {
        let dialog = ExploreEngine.systemDialog(in: cameraAlert(), expectedApp: ["Banco Plata Debug"])
        XCTAssertEqual(dialog?.message, "“Banco Plata Debug” would like to access the Camera.")
        XCTAssertEqual(dialog?.buttons.map(\.label), ["Don’t Allow", "Allow"])
        // The centre of «Don’t Allow», which is where the tap goes.
        XCTAssertEqual(dialog?.answer?.label, "Don’t Allow")
        XCTAssertEqual(dialog?.answer?.x, 127)
        XCTAssertEqual(dialog?.answer?.y, 573)
    }

    // The refusal is what gets tapped, whatever the other button is called and
    // however many of them there are: the location alert offers two ways to say
    // yes. Granting is not a crawler's decision to make — the contacts alert
    // offers to upload the address book to a server.
    func testTheRefusingButtonIsTheOneTapped() {
        let contacts = ExploreEngine.systemDialog(
            in: alert(message: "“App” would like to access your Contacts.", buttons: ["Don’t Allow", "Continue"]),
            expectedApp: ["Banco Plata Debug"]
        )
        XCTAssertEqual(contacts?.answer?.label, "Don’t Allow")

        let location = ExploreEngine.systemDialog(
            in: alert(
                message: "Allow “App” to use your location?",
                buttons: ["Allow Once", "Allow While Using App", "Don’t Allow"]
            ),
            expectedApp: ["Banco Plata Debug"]
        )
        XCTAssertEqual(location?.answer?.label, "Don’t Allow")

        let spanish = ExploreEngine.systemDialog(
            in: alert(message: "¿Permitir el acceso?", buttons: ["Permitir", "No permitir"]),
            expectedApp: ["Banco Plata Debug"]
        )
        XCTAssertEqual(spanish?.answer?.label, "No permitir")
    }

    // One button is not a choice: an "OK" over a system error grants nothing,
    // and tapping it is the only way back to the app.
    func testASingleButtonDialogIsTappedBecauseThereIsNoChoice() {
        let dialog = ExploreEngine.systemDialog(
            in: alert(message: "Cannot connect to server", buttons: ["OK"]),
            expectedApp: ["Banco Plata Debug"]
        )
        XCTAssertEqual(dialog?.answer?.label, "OK")
    }

    // A dialog whose buttons say nothing this vocabulary knows is reported and
    // left alone. Tapping the wrong one of two unknown buttons is how a tool
    // grants something on a person's behalf; the message it produces instead
    // names the buttons, which is what makes the locale fixable.
    func testADialogWithUnreadableButtonsIsReportedAndNotAnswered() {
        let dialog = ExploreEngine.systemDialog(
            in: alert(message: "Хочет доступ", buttons: ["Ага", "Валяй"]),
            expectedApp: ["Banco Plata Debug"]
        )
        XCTAssertEqual(dialog?.buttons.map(\.label), ["Ага", "Валяй"])
        XCTAssertNil(dialog?.answer, "two buttons nobody can read are not answered by guessing")
    }

    // The app's own action sheet is one of its screens and belongs on the map.
    // Only something *other* than the app holding a dialog in front of us is
    // this function's business — which is why it is handed the expectation.
    func testTheAppsOwnSheetIsNoSystemDialog() {
        var snapshot = alert(message: "Удалить карту?", buttons: ["Отмена", "Удалить"])
        snapshot[0] = node(id: nil, label: "Banco Plata Debug", type: "Application", depth: 0, frame: [0, 0, 402, 874])
        XCTAssertNil(ExploreEngine.systemDialog(in: snapshot, expectedApp: ["Banco Plata Debug"]))
    }

    // Read while it was still being presented: one button laid out, the other at
    // zero size. «The only button there is» would have pressed «Allow» here, so
    // the shortcut counts the buttons the dialog *holds*, and a dialog that is
    // not laid out yet says so instead of being answered.
    func testADialogCaughtMidPresentationIsNotAnswered() {
        let snapshot = [
            node(id: nil, label: " ", type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: nil, label: "“App” would like to access the Camera.", type: "Sheet", depth: 3, frame: [41, 289, 320, 323]),
            node(id: nil, label: "Don’t Allow", type: "Button", depth: 10, frame: [57, 549, 0, 0]),
            node(id: nil, label: "Allow", type: "Button", depth: 10, frame: [205, 549, 140, 48]),
        ]
        let dialog = ExploreEngine.systemDialog(in: snapshot, expectedApp: ["Banco Plata Debug"])
        XCTAssertEqual(dialog?.buttons.map(\.label), ["Allow"])
        XCTAssertEqual(dialog?.buttonsInDialog, 2)
        XCTAssertFalse(dialog?.isLaidOut ?? true, "half-presented is a reason to look again")
        XCTAssertNil(dialog?.answer, "and never a reason to press the one button that says yes")
    }

    // Two dialogs are in the tree while one alert replaces another, and the flat
    // tree lists the front one last. Answering the one behind taps into the
    // dimming over it and spends an attempt on nothing.
    func testTheFrontDialogIsTheOneAnswered() {
        var snapshot = alert(message: "Первый", buttons: ["Allow", "Don’t Allow"])
        snapshot += [
            node(id: nil, label: "Второй", type: "Sheet", depth: 3, frame: [41, 289, 320, 323]),
            node(id: nil, label: "Continue", type: "Button", depth: 10, frame: [57, 549, 140, 48]),
            node(id: nil, label: "Не разрешать", type: "Button", depth: 10, frame: [205, 549, 140, 48]),
        ]
        let dialog = ExploreEngine.systemDialog(in: snapshot, expectedApp: ["Banco Plata Debug"])
        XCTAssertEqual(dialog?.message, "Второй")
        XCTAssertEqual(dialog?.answer?.label, "Не разрешать")
    }

    // A button whose centre is off the screen is not a button to press: an alert
    // on its way out reports frames nobody can tap.
    func testAButtonOffTheScreenIsNoButtonToPress() {
        let snapshot = [
            node(id: nil, label: " ", type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: nil, label: "Уходящий алерт", type: "Sheet", depth: 3, frame: [41, 900, 320, 323]),
            node(id: nil, label: "Don’t Allow", type: "Button", depth: 10, frame: [57, 1160, 140, 48]),
            node(id: nil, label: "Allow", type: "Button", depth: 10, frame: [205, 1160, 140, 48]),
        ]
        XCTAssertNil(ExploreEngine.systemDialog(in: snapshot, expectedApp: ["Banco Plata Debug"]))
    }

    // Which of a screen's taps are the bar in the corner is a fact the crawl
    // holds when it catalogues them, and the map has to carry it: the same key
    // is a tab's own name on one screen and furniture on every other.
    func testTabsOfAScreenAreRecordedAmongItsCatalogue() {
        var node = ExploreScreenNode(
            id: "s-main", title: "MainScreen", fingerprint: "f", key: "MainScreen",
            screenshot: "shots/s-main.png", depth: 0, visits: 1, states: 1,
            actionsTotal: 2, actionsTried: 0, firstSeenAt: "2026-08-23T10:00:00Z",
            triedActionKeys: nil, deeplinks: nil, localizationKeys: nil
        )
        let tab = ExploreEngine.Action(
            key: "platform_tabbar_invest", targetId: "platform_tabbar_invest", targetLabel: nil,
            x: 0, y: 0, isBack: false, isTab: true
        )
        let button = ExploreEngine.Action(
            key: "MainScreen-TransferButton", targetId: "MainScreen-TransferButton", targetLabel: nil,
            x: 0, y: 0, isBack: false
        )
        ExploreController.catalogueTabs([tab, button], on: &node)
        XCTAssertEqual(node.tabActionKeys, ["platform_tabbar_invest"])

        ExploreController.catalogueTabs([button], on: &node)
        XCTAssertEqual(node.tabActionKeys, ["platform_tabbar_invest"], "a state that hides the bar does not unlearn it")
    }

    // Another app is another app, not a dialog over ours. A tap on «поддержка»
    // lands in a messenger whose onboarding sheet has buttons too; pressing one
    // presses a stranger's button, and reporting «поверх приложения системный
    // алерт» hides the plain truth the failure could have told: «на экране
    // «Telegram»». Only a screen that names *nothing* is SpringBoard's.
    func testASheetInAnotherAppIsNoSystemDialog() {
        var snapshot = alert(message: "Welcome to Telegram", buttons: ["Cancel", "Continue"])
        snapshot[0] = node(id: nil, label: "Telegram", type: "Application", depth: 0, frame: [0, 0, 402, 874])
        XCTAssertNil(ExploreEngine.systemDialog(in: snapshot, expectedApp: ["Banco Plata Debug"]))
    }

    // A button past the end of the dialog's subtree belongs to whatever is
    // behind it — the app switcher's own controls sit in the same snapshot.
    func testOnlyTheDialogsOwnButtonsCount() {
        var snapshot = alert(message: "Allow access?", buttons: ["Don’t Allow", "Allow"])
        snapshot.append(node(id: nil, label: "Открыть", type: "Button", depth: 1, frame: [10, 800, 100, 40]))
        let dialog = ExploreEngine.systemDialog(in: snapshot, expectedApp: ["Banco Plata Debug"])
        XCTAssertEqual(dialog?.buttons.map(\.label), ["Don’t Allow", "Allow"])
    }

    // A dialog with no button to press is not something to press: reported as
    // absent, so the pass relaunches instead of tapping at nothing.
    func testADialogWithoutButtonsIsNotOne() {
        let snapshot = [
            node(id: nil, label: " ", type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: nil, label: "Подождите…", type: "Sheet", depth: 3, frame: [41, 289, 320, 120]),
        ]
        XCTAssertNil(ExploreEngine.systemDialog(in: snapshot, expectedApp: ["Banco Plata Debug"]))
    }

    // MARK: tab identity

    // What makes «the same tab» the same across screens — the tap the crawl
    // spends once per run, and the landing the map keeps one root for, have to
    // agree on it.
    func testATabIsKnownByItsIdentifierThenByItsWords() {
        let identified = ExploreEngine.Action(
            key: "platform_tabbar_invest", targetId: "platform_tabbar_invest", targetLabel: "Invest",
            x: 0, y: 0, isBack: false, isTab: true
        )
        XCTAssertEqual(ExploreController.tabIdentity(of: identified), "platform_tabbar_invest")

        let labelled = ExploreEngine.Action(
            key: "Invest@RadioButton", targetId: nil, targetLabel: "Invest",
            x: 0, y: 0, isBack: false, isTab: true
        )
        XCTAssertEqual(ExploreController.tabIdentity(of: labelled), "Invest")

        let anonymous = ExploreEngine.Action(
            key: "@RadioButton", targetId: nil, targetLabel: nil,
            x: 0, y: 0, isBack: false, isTab: true
        )
        XCTAssertNil(ExploreController.tabIdentity(of: anonymous), "two nameless tabs cannot be told apart")

        let notATab = ExploreEngine.Action(
            key: "MainScreen-TransferButton", targetId: "MainScreen-TransferButton", targetLabel: nil,
            x: 0, y: 0, isBack: false
        )
        XCTAssertNil(ExploreController.tabIdentity(of: notATab))
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
        // Laid out as a grid really is — five rows of eight, each cell its own
        // square. Stacked at one rect they would be one tap point, and the cap
        // this test is about would never be reached to be tested.
        for (row, first) in "abcde".enumerated() {
            for (column, second) in "abcdefgh".enumerated() {
                snapshot.append(node(
                    id: "avatar-\(first)\(second)",
                    type: "Group",
                    depth: 5,
                    frame: [20 + column * 46, 100 + row * 46, 44, 44]
                ))
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

    // MARK: names that are not a screen's

    // The namespace half is the giveaway, and it sits before the dash: the
    // suffix vocabulary only ever sees the tail, so this id read as a screen
    // name and a promo sheet ended up on the canvas as
    // `BenefitOptionsViewIds-BenefitOptionContainer`.
    func testRootContainerIgnoresAnIdentifierNamespaceBeforeTheDash() {
        let sheet = [
            node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "BenefitOptionsViewIds-BenefitOptionContainer", type: "Group", depth: 4, frame: [0, 0, 402, 874]),
            node(id: nil, label: "10 cashback categories", type: "StaticText", depth: 6, frame: [24, 300, 340, 34]),
        ]
        XCTAssertEqual(ExploreEngine.screenKey(of: sheet), "headline:10 cashback categories")
    }

    // A router, a hosting controller, a tap region: several different screens
    // share one wrapper, so its name says nothing about which of them this is.
    func testRootContainerIgnoresContainerVocabulary() {
        for wrapper in [
            "SubscriptionsMainScreenNavigation",
            "PopoverDismissRegion",
            "PaymentsFlowRouter",
            "OnboardingContentWrapper",
        ] {
            let snapshot = [
                node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
                node(id: wrapper, type: "Group", depth: 3, frame: [0, 0, 402, 874]),
                node(id: nil, label: "Your subscriptions", type: "StaticText", depth: 5, frame: [24, 280, 340, 34]),
            ]
            XCTAssertEqual(ExploreEngine.screenKey(of: snapshot), "headline:Your subscriptions", wrapper)
        }
    }

    // A screen genuinely named after itself still wins: the vocabulary rules
    // out wrappers, not every long identifier.
    func testRootContainerStillAcceptsAScreensOwnName() {
        let snapshot = [
            node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "PersonalDetailsScreen", type: "Group", depth: 3, frame: [0, 0, 402, 874]),
        ]
        XCTAssertEqual(ExploreEngine.screenKey(of: snapshot), "PersonalDetailsScreen")
    }

    // MARK: actions

    // SwiftUI names its own hosting containers with a leading underscore. They
    // are not controls: a tap aims at the centre of the container and presses
    // whatever sits there, spending the budget and minting transitions no
    // button of the app can explain.
    func testPrivateSystemContainersOfferNoAction() {
        let snapshot = [
            node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "_TtGC7SwiftUI29PresentationHosting", type: "Group", depth: 2, frame: [0, 100, 402, 400]),
            node(id: "_TtGC7SwiftUI32NavigationStackHosting", type: "Group", depth: 3, frame: [0, 120, 402, 300]),
            node(id: "MainScreen-TransferButton", type: "Button", depth: 4, frame: [24, 200, 120, 44]),
        ]
        XCTAssertEqual(ExploreEngine.actions(from: snapshot).map(\.key), ["MainScreen-TransferButton"])
    }

    // A control the app did label is still tappable — by its label — even when
    // the identifier next to it belongs to the framework.
    func testPrivateIdentifierWithALabelIsStillTappable() {
        let snapshot = [
            node(id: nil, type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "_UIButtonBarButton", label: "Continue", type: "Button", depth: 4, frame: [24, 200, 120, 44]),
        ]
        XCTAssertEqual(ExploreEngine.actions(from: snapshot).map(\.key), ["Continue@Button"])
    }

    // MARK: counted nouns

    func testACountIsReadWithItsNounInTheRightForm() {
        XCTAssertEqual(ExploreEngine.counted(1, "экран", "экрана", "экранов"), "1 экран")
        XCTAssertEqual(ExploreEngine.counted(2, "экран", "экрана", "экранов"), "2 экрана")
        XCTAssertEqual(ExploreEngine.counted(5, "шаг", "шага", "шагов"), "5 шагов")
        XCTAssertEqual(ExploreEngine.counted(11, "шаг", "шага", "шагов"), "11 шагов")
        XCTAssertEqual(ExploreEngine.counted(21, "шаг", "шага", "шагов"), "21 шаг")
        XCTAssertEqual(ExploreEngine.counted(114, "шаг", "шага", "шагов"), "114 шагов")
        XCTAssertEqual(ExploreEngine.counted(141, "шаг", "шага", "шагов"), "141 шаг")
        XCTAssertEqual(ExploreEngine.counted(0, "переход", "перехода", "переходов"), "0 переходов")
    }

    // MARK: budgets

    // A number nobody means still has to be answered: multiplying
    // `budgetMinutes` out into seconds in `Int` trapped, and the trap took the
    // whole simtool process down with it — stream, mocks, the run watching them.
    func testAbsurdBudgetsAreRefusedInsteadOfOverflowing() {
        for request in [
            ExploreStartRequest(budgetMinutes: 1_000_000_000_000_000_000),
            ExploreStartRequest(budgetMinutes: Int.max),
            ExploreStartRequest(budgetMinutes: 0),
            ExploreStartRequest(budgetMinutes: -5),
            ExploreStartRequest(maxScreens: 0),
            ExploreStartRequest(maxScreens: Int.max),
            ExploreStartRequest(maxSteps: -1),
            ExploreStartRequest(maxSteps: Int.max),
        ] {
            XCTAssertThrowsError(try ExploreController.budgets(for: request)) { error in
                // The client can fix its own request, and has to be told so.
                guard case ExploreRequestError.badRequest = error else {
                    return XCTFail("expected a bad-request refusal, got \(error)")
                }
            }
        }
    }

    // The ceiling is not a clamp: what a caller may ask for it still gets, and
    // the widest allowed budget still lands on a real date.
    func testAcceptedBudgetsKeepTheirNumbers() throws {
        let defaults = try ExploreController.budgets(for: ExploreStartRequest())
        XCTAssertEqual(defaults.maxScreens, 40)
        XCTAssertEqual(defaults.maxSteps, 200)
        XCTAssertEqual(defaults.deadline.timeIntervalSinceNow, 15 * 60, accuracy: 30)

        let widest = try ExploreController.budgets(for: ExploreStartRequest(
            maxScreens: ExploreController.maxScreensLimit,
            maxSteps: ExploreController.maxStepsLimit,
            budgetMinutes: ExploreController.budgetMinutesLimit
        ))
        XCTAssertEqual(widest.maxScreens, ExploreController.maxScreensLimit)
        XCTAssertEqual(widest.maxSteps, ExploreController.maxStepsLimit)
        XCTAssertEqual(
            widest.deadline.timeIntervalSinceNow,
            Double(ExploreController.budgetMinutesLimit) * 60,
            accuracy: 30
        )
    }

    // MARK: the descent

    // The nearest screen with work left can sit behind a scroll, and a scroll
    // records nothing to aim at. The search used to answer "no descent anywhere"
    // on the strength of that one edge, the pass went barren, and two of those
    // ended the run with "дальше идти некуда" over untapped screens.
    func testDescentSkipsAScrollHopItCannotReplayAndTakesAnotherPath() {
        let descent = ExploreController.descentAction(
            from: "s-main",
            actions: [action(key: "MainScreen-Cards", targetId: "MainScreen-Cards", label: "Карты")],
            edges: [
                edge(from: "s-main", to: "s-feed", kind: "scroll", targetId: nil, label: nil),
                edge(from: "s-main", to: "s-cards", kind: "tap", targetId: "MainScreen-Cards", label: "Карты"),
            ],
            targets: ["s-feed", "s-cards"]
        )
        XCTAssertEqual(descent?.key, "MainScreen-Cards")
    }

    // A scroll hop is replayable after all when the screen still offers a scroll
    // — that is the action that recorded the edge.
    func testDescentReplaysAScrollHopWithAScroll() {
        let descent = ExploreController.descentAction(
            from: "s-main",
            actions: [action(key: "scroll:1", targetId: nil, label: nil, isScroll: true)],
            edges: [edge(from: "s-main", to: "s-feed", kind: "scroll", targetId: nil, label: nil)],
            targets: ["s-feed"]
        )
        XCTAssertEqual(descent?.key, "scroll:1")
    }

    // Two hops away is still a descent: what comes back is the first of them,
    // because that is all this screen can do about it.
    func testDescentReturnsTheFirstHopOfALongerPath() {
        let descent = ExploreController.descentAction(
            from: "s-main",
            actions: [action(key: "MainScreen-Cards", targetId: "MainScreen-Cards", label: "Карты")],
            edges: [
                edge(from: "s-main", to: "s-cards", kind: "tap", targetId: "MainScreen-Cards", label: "Карты"),
                edge(from: "s-cards", to: "s-limit", kind: "tap", targetId: "Cards-Limit", label: "Лимит"),
            ],
            targets: ["s-limit"]
        )
        XCTAssertEqual(descent?.key, "MainScreen-Cards")
    }

    func testNoRecordedPathMeansNoDescent() {
        XCTAssertNil(ExploreController.descentAction(
            from: "s-main",
            actions: [action(key: "MainScreen-Cards", targetId: "MainScreen-Cards", label: "Карты")],
            edges: [edge(from: "s-cards", to: "s-limit", kind: "tap", targetId: "x", label: "y")],
            targets: ["s-limit"]
        ))
    }

    // MARK: the frontier

    // A screen with several states was judged by the state in hand: the crawl
    // called it finished and stopped, while the map — reading the node's stored
    // key sets — went on showing untried taps on that very card.
    func testAVisitedScreenIsJudgedByItsStoredKeysToo() {
        let node = screenNode(
            actionsTotal: 3, actionsTried: 1,
            actionKeys: ["tab", "profile", "card"], triedActionKeys: ["tab"]
        )
        let seenState = ExploreController.ScreenState(
            nodeId: "s-main",
            depth: 0,
            actions: [action(key: "tab", targetId: "tab", label: nil)],
            triedKeys: ["tab"]
        )
        XCTAssertEqual(
            ExploreController.nodesWithUntried(states: ["fingerprint": seenState], nodes: [node]),
            ["s-main"]
        )
        XCTAssertTrue(ExploreEngine.hasUntriedActions(node), "the map and the crawl answer alike")
    }

    func testAScreenWhoseStoredKeysWereAllTriedLeavesTheFrontier() {
        let node = screenNode(
            actionsTotal: 2, actionsTried: 2,
            actionKeys: ["tab", "profile"], triedActionKeys: ["tab", "profile"]
        )
        let seenState = ExploreController.ScreenState(
            nodeId: "s-main",
            depth: 0,
            actions: [action(key: "tab", targetId: "tab", label: nil)],
            triedKeys: ["tab"]
        )
        XCTAssertTrue(
            ExploreController.nodesWithUntried(states: ["fingerprint": seenState], nodes: [node]).isEmpty
        )
    }

    // A tab this pass has already opened is work the pass will not do, and the
    // frontier has to agree — otherwise every screen carrying the bar keeps
    // calling the crawl back to a tap it has decided to skip, and no pass can
    // ever call the map finished. Told through `spent`, never by writing
    // «tried» into the store: the card on the canvas prints that number, and it
    // would be claiming a tap nobody made.
    func testATabSpentThisPassLeavesTheFrontierWithoutBeingCalledTried() {
        let node = screenNode(
            actionsTotal: 2, actionsTried: 1,
            actionKeys: ["platform_tabbar_invest", "profile"], triedActionKeys: ["profile"]
        )
        let seenState = ExploreController.ScreenState(
            nodeId: "s-main",
            depth: 0,
            actions: [action(key: "platform_tabbar_invest", targetId: "platform_tabbar_invest", label: nil)],
            triedKeys: []
        )
        XCTAssertEqual(
            ExploreController.nodesWithUntried(states: ["fingerprint": seenState], nodes: [node]),
            ["s-main"],
            "before the tab is spent, the screen has work left"
        )
        XCTAssertTrue(
            ExploreController.nodesWithUntried(
                states: ["fingerprint": seenState],
                nodes: [node],
                spent: ["platform_tabbar_invest"]
            ).isEmpty,
            "and once it is spent, the screen stops calling the crawl back"
        )
        XCTAssertEqual(node.actionsTried, 1, "the store still says one tap, because one tap is what happened")
        XCTAssertEqual(node.triedActionKeys, ["profile"])
    }

    // MARK: counters across runs

    // The second run extends what the first recorded rather than restating it:
    // both key sets are unions, and neither counter the map already showed can
    // fall.
    func testASecondRunExtendsTheStoredKeySets() {
        var node = screenNode(
            actionsTotal: 2, actionsTried: 2,
            actionKeys: ["profile", "tab"], triedActionKeys: ["profile", "tab"]
        )
        // This run finds the screen again, with one tappable more than before.
        ExploreController.catalogue(["tab", "profile", "card"], on: &node)
        XCTAssertEqual(node.actionKeys, ["card", "profile", "tab"])
        XCTAssertEqual(node.actionsTotal, 3)
        XCTAssertEqual(node.actionsTried, 2)
        XCTAssertTrue(ExploreEngine.hasUntriedActions(node))

        ExploreController.markTried("card", on: &node)
        XCTAssertEqual(node.triedActionKeys, ["card", "profile", "tab"])
        XCTAssertEqual(node.actionsTried, 3)
        XCTAssertEqual(node.actionsTotal, 3)
        XCTAssertFalse(ExploreEngine.hasUntriedActions(node))
    }

    // A schema-1 node published `5/8` with no keys behind either number.
    // Rebuilding its key set is deliberate; publishing `1/10` on the first tap
    // of the next run is not — the share the map showed walked backwards.
    func testALegacyTriedCountNeverWalksBackwards() {
        var node = screenNode(actionsTotal: 8, actionsTried: 5, actionKeys: nil, triedActionKeys: nil)
        let legacyTried = node.actionsTried

        ExploreController.catalogue((1...10).map { "key-\($0)" }, on: &node)
        XCTAssertEqual(node.actionsTotal, 10, "the keys are known now, and there are ten of them")
        XCTAssertEqual(node.actionsTried, 5)

        ExploreController.markTried("key-1", on: &node, legacyTriedCount: legacyTried)
        XCTAssertEqual(node.actionsTried, 5, "5/10 after one tap, never 1/10")
        XCTAssertEqual(node.triedActionKeys, ["key-1"])

        for key in ["key-2", "key-3", "key-4", "key-5", "key-6"] {
            ExploreController.markTried(key, on: &node, legacyTriedCount: legacyTried)
        }
        XCTAssertEqual(node.actionsTried, 6, "the rebuilt set overtakes the history and takes over")
    }

    // A schema-1 node also published a tried count with no keys behind it, and
    // the screen it describes can have fewer taps on it than the count claims —
    // the app changed, or the count was a per-state sum that double-counted one
    // button. The total is a set size and the tried count is not, so the total
    // has to cover it: `3/5` says the map has lost track of five taps it made,
    // and the canvas was quietly clamping the number to keep the bar drawable.
    func testACataloguedSetSmallerThanTheHistoryStillCoversIt() {
        var node = screenNode(actionsTotal: 8, actionsTried: 5, actionKeys: nil, triedActionKeys: nil)

        ExploreController.catalogue(["tab", "profile", "card"], on: &node)
        XCTAssertEqual(node.actionKeys, ["card", "profile", "tab"])
        XCTAssertEqual(node.actionsTried, 5)
        XCTAssertGreaterThanOrEqual(node.actionsTotal, node.actionsTried, "5 taps out of 3 is not a share")
        XCTAssertEqual(node.actionsTotal, 5)
    }

    // MARK: is this the app we launched

    // The screen names the app: the ordinary case, and case-insensitively,
    // because the root label is the localized display name.
    func testAScreenThatNamesTheAppIsTheApp() {
        let match = ExploreController.appMatch(rootLabel: "banco plata debug", expected: ["Banco Plata Debug"])
        XCTAssertTrue(match.isApp)
        XCTAssertEqual(match.label, "banco plata debug")
    }

    func testAScreenThatNamesSomethingElseIsNotTheApp() {
        let match = ExploreController.appMatch(rootLabel: "Safari", expected: ["Banco Plata Debug"])
        XCTAssertFalse(match.isApp)
        XCTAssertEqual(match.label, "Safari", "the name it did show is what the failure gets to report")
    }

    // A blank root label is SpringBoard's answer, not the absence of one:
    // measured on a booted simulator, the app reports its display name and
    // SpringBoard reports a single space. Reading the space as "undecidable,
    // carry on" let a crawl map `SBSwitcherWindow:Main` as one of the app's own
    // screens — and the permission alert iOS puts over a freshly installed app
    // is that same screen.
    func testAScreenThatNamesNothingIsSpringBoardAndNotTheApp() {
        for blank in [" ", "", "\n  \t"] {
            let match = ExploreController.appMatch(rootLabel: blank, expected: ["Banco Plata Debug"])
            XCTAssertFalse(match.isApp, "a blank label is not the app, got acceptance for \(blank.debugDescription)")
            XCTAssertNil(match.label, "and nothing may narrow the expectation down to whitespace")
        }
    }

    // Nothing was read at all — no root node in the snapshot. Not the app
    // either, and with nothing to report about what was on screen.
    func testASnapshotWithNoRootIsNotTheApp() {
        let match = ExploreController.appMatch(rootLabel: nil, expected: ["Banco Plata Debug"])
        XCTAssertFalse(match.isApp)
        XCTAssertNil(match.label)
    }

    // An app that names itself nowhere leaves nothing to check against, and
    // every screen passes — as it did before the launch was checked at all.
    func testWithNothingToCheckAgainstEveryScreenPasses() {
        XCTAssertTrue(ExploreController.appMatch(rootLabel: "Safari", expected: []).isApp)
    }

    // MARK: the depth a landing leaves behind

    // A pass that walks to a known screen by a shorter route than before has
    // found something out about the app. A pass that *lands* on it has not: the
    // landing is at distance zero from itself, and taking that for a shorter
    // path flattened a screen charted one tap in to depth 0. The map is measured
    // from its openings, and the recorded depth is what decides which of two
    // openings that reach each other it hangs on — so the flattened screen won
    // that decision and the arrow into it stopped being drawn. See
    // `ExploreGroupingTests.testTheRecordedDepthDecidesWhichOfTwoOpeningsTheMapHangsOn`.
    func testALandingKeepsTheDepthTheScreenWasChartedAt() {
        XCTAssertEqual(ExploreController.settledDepth(recorded: 3, reached: 0, isLanding: true), 3)
        XCTAssertEqual(
            ExploreController.settledDepth(recorded: 3, reached: 1, isLanding: false),
            1,
            "a shorter walk is news about the app"
        )
        XCTAssertEqual(
            ExploreController.settledDepth(recorded: 1, reached: 4, isLanding: false),
            1,
            "a longer one is not"
        )
    }

    // MARK: the relaunch profile

    // The convention pairs a profile with its own `-resume`. It used to hand
    // every run `explore-resume` from the second pass on, so a crawl asked for
    // by name came up under another configuration halfway through and the map
    // was glued together from two.
    func testResumeProfileIsTheChosenProfilesOwnPair() {
        let profiles = [
            LaunchProfile(name: "explore"),
            LaunchProfile(name: "explore-resume"),
            LaunchProfile(name: "qa"),
        ]
        XCTAssertEqual(
            ExploreController.resumeProfile(for: profiles[0], in: profiles)?.name,
            "explore-resume"
        )
        XCTAssertNil(
            ExploreController.resumeProfile(for: profiles[2], in: profiles),
            "a profile with no pair of its own relaunches through itself"
        )
        XCTAssertNil(ExploreController.resumeProfile(for: nil, in: profiles))
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

    private func action(
        key: String,
        targetId: String?,
        label: String?,
        isScroll: Bool = false
    ) -> ExploreEngine.Action {
        ExploreEngine.Action(
            key: key,
            targetId: targetId,
            targetLabel: label,
            x: 100,
            y: 200,
            isBack: false,
            isScroll: isScroll,
            endY: isScroll ? 100 : 0
        )
    }

    private func edge(
        from: String,
        to: String,
        kind: String,
        targetId: String?,
        label: String?
    ) -> ExploreTransitionEdge {
        ExploreTransitionEdge(
            id: "e-\(from)-\(to)",
            from: from,
            to: to,
            action: ExploreTransitionAction(kind: kind, targetId: targetId, targetLabel: label),
            count: 1
        )
    }


    /// The camera permission alert exactly as a booted simulator reports it:
    /// a root that names nothing, the alert as a `Sheet` three levels in whose
    /// label is the question, its texts, and its two buttons — apostrophe and
    /// all (iOS ships «Don’t» with U+2019, a vocabulary is written with U+0027).
    private func cameraAlert() -> [AccessibilityFlatNode] {
        [
            node(id: nil, label: " ", type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: "SBSwitcherWindow:Main", label: nil, type: "Group", depth: 1, frame: [0, 0, 402, 874]),
            node(id: nil, label: "“Banco Plata Debug” would like to access the Camera.", type: "Sheet", depth: 3, frame: [41, 289, 320, 323]),
            node(id: nil, label: "“Banco Plata Debug” would like to access the Camera.", type: "StaticText", depth: 9, frame: [71, 400, 260, 42]),
            node(id: nil, label: "This will allow you to scan QR and barcodes and take selfies", type: "StaticText", depth: 9, frame: [71, 450, 260, 78]),
            node(id: nil, label: "Don’t Allow", type: "Button", depth: 10, frame: [57, 549, 140, 48]),
            node(id: nil, label: "Allow", type: "Button", depth: 10, frame: [205, 549, 140, 48]),
        ]
    }

    /// The same shape with a message and buttons of one's choosing.
    private func alert(message: String, buttons: [String]) -> [AccessibilityFlatNode] {
        var snapshot = [
            node(id: nil, label: " ", type: "Application", depth: 0, frame: [0, 0, 402, 874]),
            node(id: nil, label: message, type: "Sheet", depth: 3, frame: [41, 289, 320, 323]),
        ]
        for (index, label) in buttons.enumerated() {
            snapshot.append(node(
                id: nil,
                label: label,
                type: "Button",
                depth: 10,
                frame: [57, 549 + index * 56, 288, 48]
            ))
        }
        return snapshot
    }

    private func node(
        id: String?,
        label: String? = nil,
        type: String?,
        subrole: String? = nil,
        depth: Int,
        frame: [Int]? = nil,
        enabled: Bool? = nil
    ) -> AccessibilityFlatNode {
        AccessibilityFlatNode(
            id: id,
            label: label,
            value: nil,
            title: nil,
            type: type,
            subrole: subrole,
            depth: depth,
            frame: frame,
            enabled: enabled
        )
    }
}
