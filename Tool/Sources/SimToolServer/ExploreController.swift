import CryptoKit
import Foundation
import SimToolCore

/// Shared across the explore files: the map's own text — a button's word, a
/// screen's title, a bundle's display name — is absent as often as it is empty,
/// and every reader of it wants those to be the same thing.
extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Graph model (persisted as graph.json next to shots/)

public struct ExploreGraph: Codable, Sendable {
    public var schemaVersion: Int
    public var run: ExploreRunMeta
    public var stats: ExploreStats
    public var nodes: [ExploreScreenNode]
    public var edges: [ExploreTransitionEdge]
}

public struct ExploreRunMeta: Codable, Sendable {
    public var id: String
    public var app: String
    public var device: String
    public var profile: String?
    public var startedAt: String
    public var finishedAt: String?
}

public struct ExploreStats: Codable, Sendable {
    public var screens: Int
    public var transitions: Int
    public var steps: Int
    public var relaunches: Int
}

public struct ExploreScreenNode: Codable, Sendable {
    public var id: String
    public var title: String
    public var fingerprint: String
    /// Structural screen key — what makes a later run's snapshot of this screen
    /// land on this node instead of minting a duplicate. Nil in graphs recorded
    /// before runs merged into one store (then the fingerprint stands in).
    public var key: String?
    /// Relative to the store root, e.g. `shots/s-ab12cd34.png`.
    public var screenshot: String
    /// Shortest observed distance from the screen the app launches into.
    public var depth: Int
    public var visits: Int
    /// How many distinct structural states collapsed into this screen. Nil in
    /// graphs recorded before states merged into one node.
    public var states: Int?
    public var actionsTotal: Int
    public var actionsTried: Int
    public var firstSeenAt: String
    /// Action keys already tried on this screen, persisted so the next run
    /// continues the frontier instead of re-tapping everything from scratch.
    public var triedActionKeys: [String]?
    /// Every action key ever catalogued on this screen, across its states and
    /// across runs. The counters above sum per state, so the same button in
    /// two states of one screen counts twice in `actionsTotal` and once in
    /// `actionsTried` — comparing them says nothing. These two key sets are
    /// comparable, which is what "this screen still has untried taps" needs.
    /// Nil in graphs recorded before the keys were kept.
    public var actionKeys: [String]?
    /// Routes mined from the project source whose tokens name this screen.
    /// Attributed statically — the crawl never opens a deeplink.
    public var deeplinks: [String]?
    /// Localization keys whose values match this screen's visible strings,
    /// reverse-looked-up in the project checkout.
    public var localizationKeys: [String]?
    /// Keys of the flows this screen belongs to — each the id of the screen
    /// that flow opens at — derived from the map's forks. A screen several
    /// features share carries all of theirs. Nil in maps recorded before
    /// screens were grouped.
    public var groups: [String]?
    /// True when the app opens on this screen: it was recorded on a launch or
    /// a relaunch rather than reached by a tap. The store says so because the
    /// crawl was there when it happened — which is why grouping trusts this
    /// over "nothing leads into it", a shape a single relaunch artifact fakes.
    /// Nil rather than false so the field stays out of every other node's JSON.
    public var entryPoint: Bool?
}

public struct ExploreTransitionAction: Codable, Sendable, Equatable {
    /// Always "tap" today: back transitions are the crawler retreating, not the
    /// app's forward navigation, so they never become edges.
    public var kind: String
    public var targetId: String?
    public var targetLabel: String?
}

public struct ExploreTransitionEdge: Codable, Sendable {
    public var id: String
    public var from: String
    public var to: String
    public var action: ExploreTransitionAction
    public var count: Int
}

// MARK: - Canvas layout (persisted as layout.json next to graph.json)

/// Where the user dragged one screen card on the Картограф canvas, in canvas
/// points.
public struct ExploreNodePosition: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The hand-made canvas arrangement, kept in its own `layout.json` rather than
/// inside `graph.json`: the crawler rewrites the graph after every step, so a
/// placement saved from the tab would race that write and lose.
public struct ExploreLayout: Codable, Sendable {
    /// The schema this build writes — and reads before writing. A file from a
    /// newer simtool holds an arrangement this build cannot represent, and
    /// replacing it with our own view of it would drop what it does not know.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Node id → where the user put that card. Nodes absent here fall back to
    /// the canvas' automatic depth layout.
    public var positions: [String: ExploreNodePosition]

    public init(
        schemaVersion: Int = ExploreLayout.currentSchemaVersion,
        positions: [String: ExploreNodePosition] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.positions = positions
    }
}

// MARK: - HTTP errors

/// Why an explore request was refused, in the terms the HTTP layer needs. The
/// routes answered 409 for everything `start` could throw, so "a run is already
/// in progress" and "unknown launch profile 'x'" reached the client as the same
/// answer — and a `layout.json` that could not be written reached it as "bad
/// request", which the client can do nothing about.
public enum ExploreRequestError: Error, LocalizedError, Sendable {
    /// The request is wrong, and a different request would work.
    case badRequest(String)
    /// The request is fine; the state it arrived in cannot serve it.
    case conflict(String)
    /// Ours to answer for: a write that failed, a server started without an app
    /// to explore. No request the client can send fixes it.
    case failure(String)

    public var errorDescription: String? {
        switch self {
        case .badRequest(let message), .conflict(let message), .failure(let message): return message
        }
    }
}

// MARK: - HTTP payloads

public struct ExploreStartRequest: Codable, Sendable {
    public var app: String?
    public var profile: String?
    public var maxScreens: Int?
    public var maxSteps: Int?
    public var budgetMinutes: Int?
    /// Start from the screen the simulator is already showing instead of
    /// launching the app first. For a session someone staged by hand — a popup
    /// dismissed, a login done, a screen navigated to — where the usual cold
    /// launch would throw that state away. Later passes launch as always.
    public var fromCurrentScreen: Bool?

    public init(
        app: String? = nil,
        profile: String? = nil,
        maxScreens: Int? = nil,
        maxSteps: Int? = nil,
        budgetMinutes: Int? = nil,
        fromCurrentScreen: Bool? = nil
    ) {
        self.app = app
        self.profile = profile
        self.maxScreens = maxScreens
        self.maxSteps = maxSteps
        self.budgetMinutes = budgetMinutes
        self.fromCurrentScreen = fromCurrentScreen
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case app, profile, maxScreens, maxSteps, budgetMinutes, fromCurrentScreen
    }

    /// A key the body carried, whatever it was. `CodingKeys` can only see the
    /// ones this build knows, and the ones it does not are the entire question.
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Written out instead of synthesized for one reason: `Codable` ignores a
    /// key it does not recognise, so `{"maxStep": 60}` decoded as "crawl with
    /// the defaults" and a typo in a budget became a silent 200-step run over
    /// the wrong app. Refusing a body that will not parse is half the guard;
    /// the half that mattered is refusing one that parses into something the
    /// caller did not ask for.
    ///
    /// Every field stays optional — omitting one still means "use the default".
    /// It is naming a field this build has never heard of that is a mistake, and
    /// the answer says which one and what the alternatives are.
    public init(from decoder: Decoder) throws {
        let present = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let unknown = present.filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else {
            // Ours to word, not `DecodingError`'s: its `debugDescription` never
            // reaches `localizedDescription`, and the answer a caller reads
            // would have been "the data isn't in the correct format" over a
            // body that is perfectly good JSON. Naming the field is the point.
            throw SimToolError(
                "Unknown field\(unknown.count == 1 ? "" : "s") \(unknown.joined(separator: ", ")) "
                    + "in the start request. Known fields: \(known.sorted().joined(separator: ", "))."
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try container.decodeIfPresent(String.self, forKey: .app)
        profile = try container.decodeIfPresent(String.self, forKey: .profile)
        maxScreens = try container.decodeIfPresent(Int.self, forKey: .maxScreens)
        maxSteps = try container.decodeIfPresent(Int.self, forKey: .maxSteps)
        budgetMinutes = try container.decodeIfPresent(Int.self, forKey: .budgetMinutes)
        fromCurrentScreen = try container.decodeIfPresent(Bool.self, forKey: .fromCurrentScreen)
    }
}

/// Positions the tab reports after a drag. A partial map: only the cards that
/// moved travel over the wire, and the server merges them into what it has.
public struct ExploreLayoutRequest: Codable, Sendable {
    public var positions: [String: ExploreNodePosition]

    public init(positions: [String: ExploreNodePosition] = [:]) {
        self.positions = positions
    }
}

public struct ExploreStatusPayload: Codable, Sendable {
    public var running: Bool
    public var runId: String?
    public var app: String?
    public var message: String?
    public var error: String?
    public var graph: ExploreGraph?
    /// The saved canvas arrangement, so opening the tab restores the map the
    /// way the user left it without a second request.
    public var layout: ExploreLayout?
    /// The groups the map's screens fall into, coarse level first and by size
    /// within a level. Derived from the graph on every read rather than stored
    /// with it, so a map recorded before grouping existed still gets them.
    public var groups: [ExploreGroup]?
}

// MARK: - Engine (pure, unit-testable)

/// The decisions the crawler makes about a single accessibility snapshot:
/// what identifies the screen, what can be tapped on it, and what to call it.
/// Free of I/O so tests can feed it recorded trees.
public enum ExploreEngine {
    /// One tappable candidate on a screen. `x`/`y` are the frame center in
    /// points — the coordinate space AXe taps in. A scroll candidate swipes
    /// from (`x`, `y`) up to (`x`, `endY`) instead of tapping.
    public struct Action: Equatable, Sendable {
        public var key: String
        public var targetId: String?
        public var targetLabel: String?
        public var x: Double
        public var y: Double
        public var isBack: Bool
        public var isScroll: Bool = false
        public var endY: Double = 0
    }

    /// Digit runs collapse to `N` so `Ids.cell-3` and `Ids.cell-17` are the
    /// same element for fingerprinting and template grouping: list content
    /// must not multiply screens.
    public static func normalizeIdentifier(_ id: String) -> String {
        var result = ""
        var inDigits = false
        for character in id {
            if character.isNumber {
                if !inDigits { result.append("N") }
                inDigits = true
            } else {
                inDigits = false
                result.append(character)
            }
        }
        return result
    }

    /// Structural screen identity: the sorted set of `(normalized id, type,
    /// depth)` for nodes carrying an identifier. Labels and values are content
    /// (balances, dates, names) and deliberately do not participate — two
    /// snapshots of one screen with different data must collide.
    public static func fingerprint(of nodes: [AccessibilityFlatNode]) -> String {
        let entries = Set(nodes.compactMap { node -> String? in
            guard let id = node.id, !id.isEmpty, !id.hasPrefix("_") else { return nil }
            return "\(normalizeIdentifier(id))|\(node.type ?? "")|\(node.depth)"
        })
        let digest = SHA256.hash(data: Data(entries.sorted().joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Words that mark an element as unsafe to tap blindly. Generic
    /// destructive/exit vocabulary only — project-specific rules belong in the
    /// project, not in simtool.
    public static let defaultDenylist = [
        "logout", "log out", "log_out", "log-out",
        "signout", "sign out", "sign_out", "sign-out",
        "delete", "remove", "call",
        "выйти", "выход", "удал", "заблок", "позвон",
    ]

    /// RadioButton included: custom tab bars read as radio groups, and the
    /// tabs are the widest doors in the app.
    static let tappableTypes: Set<String> = ["Button", "Cell", "Link", "RadioButton"]

    /// The most taps one screen state may claim from the step budget.
    public static let maxActionsPerState = 24

    /// Whether the screen still offers taps nobody has made — the difference
    /// between a screen the map has finished with and one it merely reached.
    ///
    /// Read from the key sets when the store carries them, because those are
    /// comparable; a store written before the keys were kept leaves only the
    /// old per-state sums, where the total can even sit below the tried count,
    /// so there the answer is "assume there is work left" rather than a
    /// comparison that means nothing.
    public static func hasUntriedActions(_ node: ExploreScreenNode) -> Bool {
        guard let catalogued = node.actionKeys else {
            return node.actionsTried != node.actionsTotal
        }
        return !Set(catalogued).subtracting(node.triedActionKeys ?? []).isEmpty
    }

    static let backTokens = ["back", "close", "dismiss", "cancel", "назад", "закрыть", "отмена", "отменить", "chevron.backward", "xmark"]

    public static func isBack(id: String?, label: String?) -> Bool {
        let haystack = "\(id ?? "") \(label ?? "")".lowercased()
        return backTokens.contains { haystack.contains($0) }
    }

    /// The tappable elements of a snapshot, safety-filtered and template-limited.
    ///
    /// Template limiting: cells sharing a normalized identifier are one design,
    /// not N screens — only the first and last of each group survive, so a long
    /// list contributes two probes instead of dozens.
    public static func actions(
        from nodes: [AccessibilityFlatNode],
        denylist: [String] = defaultDenylist
    ) -> [Action] {
        let bounds = nodes.first(where: { $0.depth == 0 })?.frame
        let lowered = denylist.map { $0.lowercased() }

        // Tabs first: a tab bar is the widest door in the app, and the crawl
        // tries actions in catalog order.
        var tabCandidates: [Action] = []
        var candidates: [Action] = []
        for node in nodes {
            guard let type = node.type else { continue }
            // An underscore opens the identifiers UIKit and SwiftUI give their
            // own plumbing (`_TtGC7SwiftUI29PresentationHosting`), never one the
            // app chose. Such a node is not a control: tapping it aims at the
            // centre of a hosting container and presses whatever happens to sit
            // there, which spends the step budget and mints transitions no
            // button of the app can explain. The screen heuristics already
            // ignore these ids — here the whole element goes with them, unless
            // it carries a human label of its own to tap by.
            let id = node.id?.nilIfEmpty.flatMap { $0.hasPrefix("_") ? nil : $0 }
            // Custom widgets read as identified Groups (`TouchRecognizingView`);
            // the size cap keeps screen-sized containers out.
            let isTappableContainer = type == "Group" && id != nil
            guard tappableTypes.contains(type) || isTappableContainer else { continue }
            guard node.enabled != false else { continue }
            guard let frame = node.frame, frame.count == 4, frame[2] >= 10, frame[3] >= 10 else { continue }
            if isTappableContainer, let bounds, bounds.count == 4 {
                let windowArea = Double(bounds[2]) * Double(bounds[3])
                guard Double(frame[2]) * Double(frame[3]) <= windowArea * 0.6 else { continue }
            }
            let centerX = Double(frame[0]) + Double(frame[2]) / 2
            let centerY = Double(frame[1]) + Double(frame[3]) / 2
            if let bounds, bounds.count == 4 {
                let inX = centerX >= Double(bounds[0]) && centerX <= Double(bounds[0] + bounds[2])
                let inY = centerY >= Double(bounds[1]) && centerY <= Double(bounds[1] + bounds[3])
                guard inX, inY else { continue }
                // The bottom edge is the home-indicator gesture zone: a tap
                // there opens the app switcher instead of the control.
                guard centerY <= Double(bounds[1] + bounds[3]) - 24 else { continue }
            }
            let label = node.label?.nilIfEmpty
            guard id != nil || label != nil else { continue }
            let text = "\(id ?? "") \(label ?? "")".lowercased()
            guard !lowered.contains(where: { text.contains($0) }) else { continue }
            // A navigation-bar back button carries the previous screen's title
            // as its label, so vocabulary alone cannot catch it — but its home
            // is always the top-left corner.
            let looksLikeNavbarBack = type == "Button" && centerX < 100 && centerY < 120
            let action = Action(
                key: id ?? "\(label ?? "")@\(type)",
                targetId: id,
                targetLabel: label,
                x: centerX,
                y: centerY,
                isBack: looksLikeNavbarBack || isBack(id: id, label: label)
            )
            if type == "RadioButton" { tabCandidates.append(action) } else { candidates.append(action) }
        }

        // One tap point, one probe. Two candidates whose frames share a centre
        // are the same tap — the same pixel, the same gesture, the same result —
        // and the app hands out plenty of those: every cell of this list wraps
        // itself in a `TouchRecognizingView` of exactly its own size, and a
        // screen with a SceneKit animation on it publishes the scene's lights
        // and geometry (`left spot`, `front line`, `CUBE`, `ambient`) as eight
        // identically framed Groups. Template limiting cannot fold them — their
        // identifiers differ — so each one spent a step tapping a pixel the one
        // before it had already tapped, and on a screen at the cap below it took
        // a real control's place. The first one wins, which is also the outer,
        // better-named element: the tree lists a container before its child.
        var seenPoints = Set<[Double]>()
        let distinct = (tabCandidates + candidates).filter { seenPoints.insert([$0.x, $0.y]).inserted }

        var grouped: [String: [Action]] = [:]
        var order: [String] = []
        for action in distinct {
            let template = normalizeIdentifier(action.targetId ?? action.key)
            if grouped[template] == nil { order.append(template) }
            grouped[template, default: []].append(action)
        }
        var limited: [Action] = []
        for template in order {
            guard let group = grouped[template] else { continue }
            limited.append(group[0])
            if group.count > 1, let last = group.last, last.key != group[0].key {
                limited.append(last)
            }
        }
        // Grid screens (avatar pickers, option lists) mint dozens of tappables
        // with distinct identifiers that template limiting cannot fold; a cap
        // keeps one such screen from eating the whole step budget.
        if limited.count > maxActionsPerState {
            limited = Array(limited.prefix(maxActionsPerState))
        }
        // Content below the fold: the tree already lists it, but only what is
        // on screen can be tapped — a couple of scroll probes reveal the rest.
        // Appended last, so visible taps run first (`untriedAction` keeps
        // catalog order for non-back actions).
        if let bounds, bounds.count == 4 {
            let bottom = Double(bounds[1] + bounds[3])
            let overflows = nodes.contains { node in
                guard let frame = node.frame, frame.count == 4 else { return false }
                return Double(frame[1]) > bottom || Double(frame[1] + frame[3]) > bottom + 100
            }
            if overflows {
                let centerX = Double(bounds[0]) + Double(bounds[2]) / 2
                let top = Double(bounds[1])
                let height = Double(bounds[3])
                for index in 1...2 {
                    limited.append(Action(
                        key: "scroll:\(index)",
                        targetId: nil,
                        targetLabel: nil,
                        x: centerX,
                        y: top + height * 0.62,
                        isBack: false,
                        isScroll: true,
                        endY: top + height * 0.28
                    ))
                }
            }
        }
        return limited
    }

    /// Whole identifiers that name a convention, not a screen: reverse-DNS
    /// heads, SF Symbols, generic UIKit vocabulary. Only the words the
    /// component vocabulary below cannot catch — `button`, `label`, `navbar`
    /// and friends already end in a component name, and listing them twice
    /// would mean maintaining the same rule in two places.
    static let titleStopwords: Set<String> = [
        "com", "org", "net", "app", "apple", "chevron", "xmark", "table",
        "nav", "tab", "static", "view", "screen",
    ]

    /// Name endings that mark an identifier as a reusable control, not a
    /// screen: design systems stamp their component ids on every screen
    /// (`HolaTextField-TextField`, `AcmeButtonStack-FirstButton`), so a form
    /// with three branded text fields hands the "dominant prefix" crown to the
    /// text-field component unless component names are ruled out up front.
    /// Suffix match, not exact: the brand half varies, the vocabulary half is
    /// stable UIKit/design-system English.
    static let componentNameSuffixes: [String] = [
        "textfield", "securetextfield", "textview", "textarea", "texteditor",
        "field", "input", "keyboard", "button", "buttons", "cell", "row",
        "item", "label", "text", "title", "subtitle", "caption", "image",
        "icon", "avatar", "badge", "chip", "pill", "toggle", "switch",
        "slider", "stepper", "picker", "checkbox", "spinner", "loader",
        "header", "footer", "divider", "separator", "stack", "bar", "list",
        "carousel", "banner", "card", "tooltip", "toast", "snackbar",
        // Plumbing that wraps a screen rather than being one: a router, a
        // hosting controller, a tap region, the container a component draws
        // itself in. The screen's own name is what the container is named
        // after, so the wrapper's name is always the worse of the two — and
        // several different screens share one wrapper, which is how
        // `…-BenefitOptionContainer` ended up naming a promo sheet.
        "container", "navigation", "navigator", "wrapper", "content",
        "hosting", "region", "overlay", "router",
    ]

    /// Name endings of an identifier-namespace enum: a type that exists to hold
    /// the ids of a screen's elements (`AccountUpgradeWidgetIds-Widget`,
    /// `…ScreenIdentifiers-Title`) names the container of ids, not a screen.
    /// Kept apart from the component vocabulary because it is also asked of
    /// every *segment* of a composite identifier, not just of its tail.
    static let namespaceSuffixes: [String] = ["ids", "identifiers"]

    private static let nameSuffixes: [String] = componentNameSuffixes + namespaceSuffixes

    /// Name beginnings that mark an identifier as design-system vocabulary:
    /// a kit stamps its brand on every component (`HolaTextFieldSumm`,
    /// `HolaNumpad`), including reusable full-screen templates
    /// (`HolaOnboardingScreen` hosts *different* onboardings), so an id that
    /// opens with the brand never names one screen no matter how its tail
    /// reads — the suffix vocabulary can't keep up with every coinage.
    static let componentNamePrefixes: [String] = [
        "hola",
    ]

    /// True when an identifier names a convention rather than a screen — the one
    /// gate every naming heuristic asks (both screen-key heuristics, and the
    /// label a feature chip is shown under), so a new stopword or component
    /// suffix lands in exactly one place.
    ///
    /// A composite identifier is judged segment by segment as well as whole:
    /// the vocabulary above only ever sees the tail, so
    /// `AccountUpgradeWidgetIds-Widget` — whose *namespace* half is the
    /// giveaway — read as a screen name until each segment was asked too.
    static func isGenericName(_ identifier: String) -> Bool {
        let lowered = identifier.lowercased()
        if titleStopwords.contains(lowered) { return true }
        if componentNamePrefixes.contains(where: { lowered.hasPrefix($0) }) { return true }
        if nameSuffixes.contains(where: { lowered.hasSuffix($0) }) { return true }
        let segments = lowered.split(whereSeparator: { $0 == "-" || $0 == "." })
        guard segments.count >= 2 else { return false }
        return segments.contains { segment in
            namespaceSuffixes.contains { segment.hasSuffix($0) }
        }
    }

    /// Coarse screen identity, so that states of one screen (spinner, empty
    /// list, expanded section) collapse into one canvas node although their
    /// structural fingerprints differ. Two heuristics, strongest first:
    ///
    /// 1. The root container: a *unique* identifier on a near-full-screen
    ///    node — SwiftUI/UIKit screens tend to carry one (`ProfileScreen`,
    ///    `MSMCheckPasscodeScreen`). Uniqueness matters: generic wrappers
    ///    (`TouchRecognizingView`) also stretch full-screen but repeat.
    /// 2. The dominant identifier prefix over *distinct* ids
    ///    (`MainScreen-Balance`, `MainScreen-TransferButton` → `MainScreen`).
    ///    Distinct, because a repeated wrapper id is one design element, not
    ///    a namespace; proper prefixes only, for the same reason; and never a
    ///    component name — a form full of branded text fields is named after
    ///    the screen, not after the text-field component.
    /// 3. The navigation-bar title: static per screen in practice, and a
    ///    defense against one form splitting into a node per
    ///    keyboard/validation state.
    /// 4. The headline: the big text a designer put at the top is how a human
    ///    would name the screen — and the last line of defense before the
    ///    fingerprint hash, which names it "Экран ab12ef".
    ///
    /// Nil when none fires — then the fingerprint is all we have.
    public static func screenKey(of nodes: [AccessibilityFlatNode]) -> String? {
        if let root = rootContainerId(of: nodes) { return root }
        var distinctIdsByPrefix: [String: Set<String>] = [:]
        for node in nodes {
            guard let id = node.id, !id.hasPrefix("_") else { continue }
            let parts = id.split(whereSeparator: { $0 == "-" || $0 == "." })
            guard parts.count >= 2, let prefix = parts.first.map(String.init) else { continue }
            guard prefix.count >= 4,
                  prefix.rangeOfCharacter(from: .letters) != nil,
                  !isGenericName(prefix) else { continue }
            distinctIdsByPrefix[prefix, default: []].insert(id)
        }
        let best = distinctIdsByPrefix.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }
        if let best, best.value.count >= 3 { return best.key }
        if let navbar = navbarTitle(of: nodes) { return "navbar:\(navbar)" }
        if let headline = headline(of: nodes) { return "headline:\(headline)" }
        return nil
    }

    /// The shallowest node whose identifier appears exactly once in the
    /// snapshot and whose frame covers most of the window — the screen's own
    /// container, when the app names one.
    public static func rootContainerId(of nodes: [AccessibilityFlatNode]) -> String? {
        rootContainerIndex(of: nodes).flatMap { nodes[$0].id }
    }

    static func rootContainerIndex(of nodes: [AccessibilityFlatNode]) -> Int? {
        guard let bounds = nodes.first(where: { $0.depth == 0 })?.frame, bounds.count == 4,
              bounds[2] > 0, bounds[3] > 0 else { return nil }
        let windowArea = Double(bounds[2]) * Double(bounds[3])
        var idCounts: [String: Int] = [:]
        for node in nodes {
            if let id = node.id, !id.isEmpty { idCounts[id, default: 0] += 1 }
        }
        var best: (index: Int, depth: Int)?
        for (index, node) in nodes.enumerated() {
            guard let id = node.id, !id.isEmpty, !id.hasPrefix("_"), idCounts[id] == 1 else { continue }
            guard id.count >= 4,
                  id.rangeOfCharacter(from: .letters) != nil,
                  !isGenericName(id) else { continue }
            guard let frame = node.frame, frame.count == 4 else { continue }
            guard Double(frame[2]) * Double(frame[3]) >= windowArea * 0.7 else { continue }
            if best == nil || node.depth < best!.depth { best = (index, node.depth) }
        }
        return best?.index
    }

    /// The visible strings that belong to the screen itself. The tree carries
    /// lower window layers too (the presenting screen behind a sheet), so when
    /// the screen has its own container, only its DFS subtree counts.
    public static func contentLabels(of nodes: [AccessibilityFlatNode]) -> [String] {
        var slice = nodes[nodes.startIndex...]
        if let start = rootContainerIndex(of: nodes) {
            var end = start + 1
            while end < nodes.count, nodes[end].depth > nodes[start].depth { end += 1 }
            slice = nodes[start..<end]
        }
        return slice.flatMap { [$0.label, $0.title].compactMap { $0 } }
    }

    /// Words that mark a node as "data still on its way": skeletons and
    /// shimmer placeholders settle structurally long before content arrives,
    /// and a screenshot taken then maps a loading screen, not the screen.
    static let loadingTokens = ["skeleton", "shimmer", "spinner", "loading", "activityindicator", "progressindicator", "progressview"]

    public static func isLoading(_ nodes: [AccessibilityFlatNode]) -> Bool {
        nodes.contains { node in
            let haystack = "\(node.id ?? "") \(node.type ?? "")".lowercased()
            return loadingTokens.contains { haystack.contains($0) }
        }
    }

    /// The frontmost application's label — the crawl's "are we still in the
    /// app we launched" anchor. A tap can leave the app (app switcher, an
    /// external link, a crash to SpringBoard); those screens are not the
    /// app's map.
    public static func applicationLabel(of nodes: [AccessibilityFlatNode]) -> String? {
        nodes.first { $0.depth == 0 }?.label
    }

    /// Navigation-bar text: below the status bar (whose clock and battery
    /// read as labels too), short, and containing at least one letter.
    public static func navbarTitle(of nodes: [AccessibilityFlatNode]) -> String? {
        let navbarText = nodes.first { node in
            guard node.type == "StaticText", let frame = node.frame, frame.count == 4 else { return false }
            guard let label = node.label, (2...40).contains(label.count),
                  label.rangeOfCharacter(from: .letters) != nil else { return false }
            return frame[1] >= 30 && frame[1] < 160
        }
        return navbarText?.label
    }

    /// The screen's headline: the topmost large text in the upper part of the
    /// window — "Your phone number", "How to restore access…". Large means a
    /// line of title-sized font (28+ points tall), which skips status-bar
    /// text, chips, and body copy on the way down; topmost, because when both
    /// a title and a tall two-line paragraph qualify, the title sits above it.
    public static func headline(of nodes: [AccessibilityFlatNode]) -> String? {
        guard let bounds = nodes.first(where: { $0.depth == 0 })?.frame, bounds.count == 4,
              bounds[3] > 0 else { return nil }
        let ceiling = Int(Double(bounds[3]) * 0.45)
        let candidates = nodes.filter { node in
            guard node.type == "StaticText", let frame = node.frame, frame.count == 4 else { return false }
            guard let label = node.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                  (2...80).contains(label.count),
                  label.rangeOfCharacter(from: .letters) != nil else { return false }
            return frame[1] >= 30 && frame[1] <= ceiling && frame[3] >= 28
        }
        let best = candidates.min { lhs, rhs in
            (lhs.frame![1], -lhs.frame![3]) < (rhs.frame![1], -rhs.frame![3])
        }
        guard let label = best?.label else { return nil }
        // SwiftUI multiline labels carry their newlines; a key must not.
        return label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A display name for a screen, best effort: the screen key when one
    /// exists (root container, dominant prefix, navbar title, or headline),
    /// else the first titled node, else the caller's fallback.
    public static func title(for nodes: [AccessibilityFlatNode], fallback: String) -> String {
        if let key = screenKey(of: nodes) {
            // Text-derived keys carry a namespace prefix so they can never
            // collide with an identifier; the display name drops it.
            for namespace in ["navbar:", "headline:"] where key.hasPrefix(namespace) {
                return displayTitle(String(key.dropFirst(namespace.count)))
            }
            return displayTitle(key)
        }
        if let titled = nodes.first(where: { !($0.title ?? "").isEmpty }), let title = titled.title {
            return displayTitle(title)
        }
        return fallback
    }

    /// A count with its noun in the right Russian form: «1 экран», «2 экрана»,
    /// «5 экранов». The status line is read by a person, and a number glued to
    /// a single hardcoded form ("1 экранов") reads like a half-built interface.
    public static func counted(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let hundreds = abs(count) % 100
        let units = hundreds % 10
        if (11...14).contains(hundreds) { return "\(count) \(many)" }
        switch units {
        case 1: return "\(count) \(one)"
        case 2...4: return "\(count) \(few)"
        default: return "\(count) \(many)"
        }
    }

    /// Headlines make honest names but poor labels when they run long; the
    /// key keeps the full text (identity), the card shows it trimmed.
    static func displayTitle(_ raw: String) -> String {
        raw.count <= 48 ? raw : String(raw.prefix(47)) + "…"
    }
}

// MARK: - Controller

/// Owns one exploration run at a time: launches the app, walks its screens by
/// tapping through the accessibility tree, and persists `graph.json` plus a
/// screenshot per screen after every step — the artifact the Картограф tab
/// renders and the crash-safe record of the run.
public final class ExploreController: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var device: SimulatorDevice
        public var defaultApp: String?
        public var profiles: [LaunchProfile]
        /// Named deeplinks from the project config, matched after the crawl
        /// to the discovered screens' names — never opened.
        public var deeplinks: [ProjectConfig.Deeplink]
        public var appFacingServerURL: String?
        /// The project checkout, searched for localization tables.
        public var projectRoot: URL?
        /// Runs live in `<root>/<runId>/` as `graph.json` + `shots/*.png`.
        public var root: URL

        public init(
            device: SimulatorDevice,
            defaultApp: String?,
            profiles: [LaunchProfile],
            deeplinks: [ProjectConfig.Deeplink] = [],
            appFacingServerURL: String?,
            projectRoot: URL? = nil,
            root: URL
        ) {
            self.device = device
            self.defaultApp = defaultApp
            self.profiles = profiles
            self.deeplinks = deeplinks
            self.appFacingServerURL = appFacingServerURL
            self.projectRoot = projectRoot
            self.root = root
        }
    }

    struct Budgets {
        var maxScreens: Int
        var maxSteps: Int
        var deadline: Date
        var maxRelaunches = 12
    }

    /// Ceilings for the three budgets a request may name. Not politeness: the
    /// minute budget is multiplied out into seconds, `Int` arithmetic traps on
    /// overflow, and one absurd number in a request body took the whole simtool
    /// process down with it — stream, mocks and the run watching them. They are
    /// also the honest ceiling of a crawl: no app has twenty thousand screens,
    /// no simulator session outlives a million taps, and nobody waits a week
    /// for a map. Past them the number is a typo, and a typo deserves an answer
    /// rather than a silent clamp to something else.
    static let maxScreensLimit = 20_000
    static let maxStepsLimit = 1_000_000
    static let budgetMinutesLimit = 7 * 24 * 60

    /// The budgets of one run, or a rejection naming the field at fault.
    static func budgets(for request: ExploreStartRequest) throws -> Budgets {
        func checked(_ value: Int?, _ field: String, fallback: Int, limit: Int) throws -> Int {
            guard let value else { return fallback }
            guard value > 0, value <= limit else {
                throw ExploreRequestError.badRequest("\(field) must be between 1 and \(limit), got \(value).")
            }
            return value
        }
        let screens = try checked(request.maxScreens, "maxScreens", fallback: 40, limit: maxScreensLimit)
        let steps = try checked(request.maxSteps, "maxSteps", fallback: 200, limit: maxStepsLimit)
        let minutes = try checked(request.budgetMinutes, "budgetMinutes", fallback: 15, limit: budgetMinutesLimit)
        return Budgets(
            maxScreens: screens,
            maxSteps: steps,
            // Counted in `TimeInterval`: the same arithmetic in `Int` is what
            // trapped.
            deadline: Date().addingTimeInterval(TimeInterval(minutes) * 60)
        )
    }

    /// What the crawler knows about one discovered screen. Visible to tests:
    /// the frontier and descent rules below are decided from these.
    struct ScreenState {
        var nodeId: String
        var depth: Int
        var actions: [ExploreEngine.Action]
        var triedKeys: Set<String> = []
    }

    private let configuration: Configuration
    private let lock = NSLock()
    private var running = false
    private var runId: String?
    private var runDirectory: URL?
    private var graph: ExploreGraph?
    private var message: String?
    private var lastError: String?
    /// Something wrong with the store itself: a file set aside because it would
    /// not decode, one written by a newer simtool, a run directory that could
    /// not be adopted. Kept apart from `lastError`, which belongs to the run,
    /// and reported next to it — a lost arrangement is news even when the crawl
    /// went perfectly.
    ///
    /// Keyed by the file each notice is about, because a notice outlives the
    /// poll that raised it and only that file's own news can retire it. One
    /// slot for all of them meant a successful `layout.json` write cleared the
    /// notice that `groups.json` had been set aside — and nothing could ever
    /// raise it again, since the next read of a quarantined file just finds it
    /// missing. One card dragged, and every name a person had given the
    /// features was quietly out of play with the banner that said so gone.
    private var storeWarnings: [String: String] = [:]
    /// The schema of a `layout.json` / `groups.json` this build is too old to
    /// rewrite, when the file says so. Reading it is fine — what decodes is
    /// shown — but writing our own view over it would drop the rest.
    private var futureLayoutVersion: Int?
    private var futureNamesVersion: Int?
    /// Legacy per-run directories are looked for once, not on every poll.
    private var legacyRunsMigrated = false
    private var task: Task<Void, Never>?
    /// `<directory>|<graph.json mtime>` of the run `loadNewestRunLocked` last
    /// decoded, so the tab's 3-second poll does not re-decode an unchanged file.
    private var loadedRunSignature: String?
    /// The hand-made canvas arrangement, and the `layout.json` mtime it was
    /// decoded from — same reason as the graph: the tab polls, the file rarely
    /// changes.
    private var layout = ExploreLayout()
    private var layoutSignature: String?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: HTTP surface

    public func status() -> ExploreStatusPayload {
        lock.lock()
        defer { lock.unlock() }
        loadNewestRunLocked()
        loadLayoutLocked()
        // Grouping is derived, not stored: computing it here rather than only
        // at crawl time means a map recorded by an earlier version lights up
        // with feature groups on the next poll, without being re-walked.
        let grouped = graph.map { ExploreGrouping.annotatedWithGroups($0, names: loadNamesLocked()) }
        // The store holds every transition the crawl observed; the tab is shown
        // the ones the map draws. Keeping the two apart is what lets a screen
        // the crawl relaunches into keep its arrows instead of losing them from
        // the file the first time it is entered twice.
        let drawn = grouped.map { ExploreGrouping.descending($0.graph) }
        return ExploreStatusPayload(
            running: running,
            runId: runId,
            app: graph?.run.app ?? configuration.defaultApp,
            message: message,
            // Both, joined: a file set aside or a store gone from disk is
            // news the run itself has no way to report.
            error: ([lastError].compactMap { $0 } + storeWarnings.sorted { $0.key < $1.key }.map(\.value))
                .joined(separator: " ").nilIfEmpty,
            graph: drawn,
            layout: layout,
            groups: grouped?.groups
        )
    }

    public func start(_ request: ExploreStartRequest) throws -> ExploreStatusPayload {
        // Budgets first: they are arithmetic on the request alone, and telling a
        // caller its numbers are impossible is cheaper than resolving an app and
        // a profile for a run that cannot happen.
        let budgets = try Self.budgets(for: request)
        guard let app = request.app?.nilIfEmpty ?? configuration.defaultApp else {
            // Neither the caller's mistake nor a state to wait out: the server
            // was started without an app, and no request fixes that.
            throw ExploreRequestError.failure(
                "No app to explore: start the server with --app <bundle-id> or configure `bundleId` in .simtool/config.yml."
            )
        }
        let profile = try resolveProfile(named: request.profile)

        lock.lock()
        if running {
            lock.unlock()
            throw ExploreRequestError.conflict("An exploration run is already in progress.")
        }
        let id = Self.runIdFormatter.string(from: Date())
        let directory = configuration.root
        running = true
        runId = id
        runDirectory = directory
        lastError = nil
        // A new crawl is the answer to a map that could not be read, so its own
        // notice goes. The notices about the arrangement and the names are not
        // this run's business, and a run does not put either file back.
        storeWarnings["graph.json"] = nil
        let meta = ExploreRunMeta(
            id: id,
            app: app,
            device: configuration.device.name,
            profile: profile?.name,
            startedAt: Self.timestamp(),
            finishedAt: nil
        )
        // One store per project: a new run resumes the existing map — same
        // nodes, same shots — and only extends and refreshes it. A map of a
        // different app is stale territory, not something to merge into.
        migrateLegacyRunsLocked()
        let existing = loadGraphToResumeLocked(at: directory)
        if let existing, existing.run.app == app {
            graph = existing
            graph?.run = meta
            graph?.schemaVersion = 2
            message = "Продолжаю карту: \(ExploreEngine.counted(existing.nodes.count, "экран", "экрана", "экранов"))…"
        } else {
            // Everything the previous app left behind goes with its map: the
            // screenshots of screens this crawl will never see, the arrangement
            // of cards that no longer exist, the names someone gave its
            // features. Kept, they grew `.simtool/explore/` without bound while
            // a stray feature name waited for a matching id to latch onto.
            if existing != nil { discardStoreLocked() }
            graph = ExploreGraph(
                schemaVersion: 2,
                run: meta,
                stats: ExploreStats(screens: 0, transitions: 0, steps: 0, relaunches: 0),
                nodes: [],
                edges: []
            )
            message = "Запускаю \(app)…"
        }
        let resumeProfile = Self.resumeProfile(for: profile, in: configuration.profiles)
        task = Task { [weak self] in
            await self?.crawl(
                app: app,
                profile: profile,
                resumeProfile: resumeProfile,
                directory: directory,
                budgets: budgets,
                fromCurrentScreen: request.fromCurrentScreen ?? false
            )
        }
        lock.unlock()
        return status()
    }

    /// Cancels the in-flight run, if any. The crawler notices at its next await
    /// and finalizes the graph; until then the status stays running.
    public func stop() -> ExploreStatusPayload {
        lock.lock()
        let task = running ? self.task : nil
        lock.unlock()
        task?.cancel()
        return status()
    }

    /// PNG bytes of a node's screenshot from the current (or last loaded) run.
    /// The node id is sanitized because it becomes a file name under our root.
    public func shotData(node: String) -> Data? {
        guard node.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), !node.isEmpty else { return nil }
        lock.lock()
        loadNewestRunLocked()
        let directory = runDirectory
        lock.unlock()
        guard let directory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent("shots/\(node).png"))
    }

    /// Records where the user dragged screen cards. Merges rather than
    /// replaces: only the cards that moved arrive, and two open tabs must not
    /// wipe each other's placements. Positions of screens the store no longer
    /// knows are dropped so the file cannot grow forever.
    @discardableResult
    public func saveLayout(_ positions: [String: ExploreNodePosition]) throws -> ExploreLayout {
        lock.lock()
        defer { lock.unlock() }
        loadNewestRunLocked()
        loadLayoutLocked()
        if let version = futureLayoutVersion {
            throw ExploreRequestError.conflict(
                "layout.json was written by a newer simtool (schemaVersion \(version)); refusing to overwrite it. Move the file aside to start a new arrangement."
            )
        }
        var merged = layout.positions
        for (id, position) in positions { merged[id] = position }
        if let known = graph?.nodes, !known.isEmpty {
            let ids = Set(known.map(\.id))
            merged = merged.filter { ids.contains($0.key) }
        }
        let next = ExploreLayout(positions: merged)
        do {
            try FileManager.default.createDirectory(at: configuration.root, withIntermediateDirectories: true)
            try JSON.encoder.encode(next).write(to: layoutFile, options: [.atomic])
        } catch {
            // Ours, not the caller's: the request was fine and the disk was not.
            throw writeRefusalLocked(layoutFile, error)
        }
        layout = next
        layoutSignature = layoutFileSignature()
        storeWarnings["layout.json"] = nil
        return next
    }

    // MARK: group names

    private var namesFile: URL {
        configuration.root.appendingPathComponent("groups.json")
    }

    /// The `groups.json` schema this build writes. Kept here rather than on
    /// `ExploreGroupNames`: how the file is versioned is the store's business,
    /// and the store is this file.
    static let namesSchemaVersion = 1

    private func loadNamesLocked() -> ExploreGroupNames {
        guard let data = try? Data(contentsOf: namesFile) else {
            futureNamesVersion = nil
            return ExploreGroupNames()
        }
        guard let decoded = try? JSON.decoder.decode(ExploreGroupNames.self, from: data) else {
            // Every name a person gave a feature is in this file. Starting from
            // none of them is survivable; the next save writing that emptiness
            // over the file is not, and nobody would have learned it happened.
            quarantineLocked(namesFile, what: "имена фич")
            futureNamesVersion = nil
            return ExploreGroupNames()
        }
        if decoded.schemaVersion > Self.namesSchemaVersion {
            futureNamesVersion = decoded.schemaVersion
            storeWarnings["groups.json"] = "groups.json написан более новой версией simtool (schemaVersion \(decoded.schemaVersion)) — файл не перезаписывается."
        } else {
            futureNamesVersion = nil
            // Readable and writable again: this file's own news, and the only
            // thing that can retire its notice. See `loadLayoutLocked` — a
            // notice that only a save could clear outlived what it described.
            storeWarnings["groups.json"] = nil
        }
        return decoded
    }

    /// The groups an agent is asked to name: only the ones a person can pick,
    /// each with the raw material for a name and the screenshot of the screen
    /// it opens at. Reads the store off disk, so naming needs neither a crawl
    /// in flight nor a booted simulator.
    public func namingGroups() -> [ExploreGroup] {
        lock.lock()
        defer { lock.unlock() }
        loadNewestRunLocked()
        guard let graph else { return [] }
        // Grouping reads the map's edges and counters, none of which annotating
        // touches, so the raw store answers this without a second pass over it.
        return ExploreGrouping.groups(of: graph, names: loadNamesLocked()).filter(\.displayable)
    }

    /// Records names for several groups at once.
    ///
    /// A set at a time, not one group per call: two groups can open at the same
    /// screen, and only a namer looking at all of them together can tell them
    /// apart. The whole set is rejected when any two labels collide — with
    /// nothing to correct by hand, an ambiguous chip has no way back.
    @discardableResult
    public func saveGroupNames(_ requested: [String: String]) throws -> [ExploreGroup] {
        lock.lock()
        defer { lock.unlock() }
        loadNewestRunLocked()
        guard let graph else { throw SimToolError("No map to name groups in") }
        // Walked once: splitting the map costs a reachability pass per screen,
        // and asking for it again per name in the request made a set of twenty
        // do the same work twenty times over.
        let flows = ExploreGrouping.groups(of: graph)
        let known = Set(flows.map(\.key))
        // Only a name has to land on a flow that exists. An empty name is an
        // erasure, and the record most in need of erasing is exactly the one
        // whose flow is gone: refusing it left a name nothing showed and
        // nothing could clear, and `groups.json` had to be edited by hand.
        let unknown = requested.first {
            !known.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let unknown {
            throw SimToolError("No group named \(unknown.key) in this map")
        }

        let membersByKey = Dictionary(flows.map { ($0.key, $0.members) }, uniquingKeysWith: { first, _ in first })
        var stored = loadNamesLocked()
        for (key, name) in requested {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { stored.names[key] = nil; continue }
            // A key that outlived its flow does not get to hold the name it is
            // no longer showing anywhere against the flow that is — see
            // `ExploreGroupNaming.retired`.
            for dead in ExploreGroupNaming.retired(name: trimmed, in: stored, flows: known) {
                stored.names[dead] = nil
            }
            stored.names[key] = ExploreGroupName(name: trimmed, members: membersByKey[key] ?? [])
        }

        // Collisions are judged over every recorded name, not just the ones on
        // the panel right now: a feature that shrank to one screen drops off
        // the panel for a run, and judging only what is shown let its name be
        // handed to a second feature — two identical chips once it came back.
        let conflicts = ExploreGroupNaming.conflicts(in: stored)
        guard conflicts.isEmpty else {
            throw SimToolError("Groups would share a name: \(conflicts.joined(separator: ", "))")
        }

        if let version = futureNamesVersion {
            throw ExploreRequestError.conflict(
                "groups.json was written by a newer simtool (schemaVersion \(version)); refusing to overwrite it. Move the file aside to record names again."
            )
        }
        do {
            try FileManager.default.createDirectory(at: configuration.root, withIntermediateDirectories: true)
            try JSON.encoder.encode(stored).write(to: namesFile, options: [.atomic])
        } catch {
            throw writeRefusalLocked(namesFile, error)
        }
        storeWarnings["groups.json"] = nil
        return ExploreGrouping.named(flows, with: stored).filter(\.displayable)
    }

    /// Stops the crawler when the server shuts down.
    public func shutdown() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    // MARK: run resolution

    private func resolveProfile(named name: String?) throws -> LaunchProfile? {
        if let name = name?.nilIfEmpty {
            guard let match = configuration.profiles.first(where: { $0.name == name }) else {
                let available = configuration.profiles.map(\.name).joined(separator: ", ")
                throw ExploreRequestError.badRequest(
                    "Unknown launch profile '\(name)'.\(available.isEmpty ? "" : " Available: \(available).")"
                )
            }
            return match
        }
        // Convention: a profile literally named `explore` is the one a project
        // prepared for crawling (mock backend, auto-login). Nothing breaks
        // without it — the app just launches plain.
        return configuration.profiles.first { $0.name == "explore" }
    }

    private static let runIdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// Shows the store on disk whenever no crawl of our own is in flight: the
    /// map survives a server restart, and a store someone else is writing — an
    /// agent performing the cartograph.md pass — grows on the canvas live
    /// instead of appearing after a restart.
    private func loadNewestRunLocked() {
        guard !running else { return }
        migrateLegacyRunsLocked()
        let file = configuration.root.appendingPathComponent("graph.json")
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else {
            // The store is gone from disk — the cartograph.md pass is told to
            // delete it when the map has to be started over. Holding the decoded
            // copy alive answered `/status` with twelve screens nobody could see
            // any more, and let the next `/layout` save build the directory back
            // around them.
            if graph != nil {
                graph = nil
                runId = nil
                runDirectory = nil
                loadedRunSignature = nil
                message = "Карта удалена с диска."
            }
            return
        }
        let signature = "graph|\(modified.timeIntervalSince1970)"
        if signature == loadedRunSignature { return }
        // A decode failure here is a run mid-write (a torn graph.json): keep
        // showing what we have and retry on the next poll.
        guard let loaded = Self.loadGraph(at: configuration.root) else { return }
        loadedRunSignature = signature
        // Re-reading the store we just finished writing must not clobber the
        // closing note ("Готово: … экранов …").
        let isNewRun = loaded.run.id != runId
        graph = loaded
        runId = loaded.run.id
        runDirectory = configuration.root
        if isNewRun {
            message = "Показана карта: \(ExploreEngine.counted(loaded.nodes.count, "экран", "экрана", "экранов"))"
        }
    }

    private var layoutFile: URL {
        configuration.root.appendingPathComponent("layout.json")
    }

    private func layoutFileSignature() -> String? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: layoutFile.path))?[.modificationDate] as? Date else {
            return nil
        }
        return "layout|\(modified.timeIntervalSince1970)"
    }

    /// Decodes `layout.json` when it changed on disk. A missing file is the
    /// normal state of a map nobody rearranged yet, and a torn read (a save in
    /// flight) keeps the arrangement we already hold.
    private func loadLayoutLocked() {
        guard let signature = layoutFileSignature() else {
            // Deleted: the arrangement went with the file, and answering with
            // the copy in memory would write it back at the next save.
            if layoutSignature != nil {
                layout = ExploreLayout()
                layoutSignature = nil
                futureLayoutVersion = nil
            }
            return
        }
        guard signature != layoutSignature else { return }
        guard let data = try? Data(contentsOf: layoutFile) else { return }
        guard let decoded = try? JSON.decoder.decode(ExploreLayout.self, from: data) else {
            // Every card a person dragged is in this file. Starting from an
            // empty arrangement is survivable; the next save writing that
            // emptiness over the file is not — and until it did, nobody would
            // have learned the file had stopped being read.
            quarantineLocked(layoutFile, what: "раскладка карточек")
            layout = ExploreLayout()
            layoutSignature = nil
            futureLayoutVersion = nil
            return
        }
        layoutSignature = signature
        layout = decoded
        // What decodes is still shown — a newer schema is additive until it
        // proves otherwise — but this build cannot write back the parts it does
        // not know about, so it does not write the file at all.
        if decoded.schemaVersion > ExploreLayout.currentSchemaVersion {
            futureLayoutVersion = decoded.schemaVersion
            storeWarnings["layout.json"] = "layout.json написан более новой версией simtool (schemaVersion \(decoded.schemaVersion)) — файл не перезаписывается."
        } else {
            futureLayoutVersion = nil
            // A file this build can write again is this file's own news, and
            // the notice about it goes. Only a save used to retire it, so the
            // banner outlived what it described: move the newer `layout.json`
            // aside — the very thing the banner asks for — and the page went on
            // reporting a refusal that no longer applied until somebody
            // happened to drag a card.
            storeWarnings["layout.json"] = nil
        }
    }

    private static func loadGraph(at directory: URL) -> ExploreGraph? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("graph.json")) else { return nil }
        return try? JSON.decoder.decode(ExploreGraph.self, from: data)
    }

    /// The store a starting run resumes from, or nil when there is none.
    ///
    /// A `graph.json` that will not decode is not "no store": it is a map, and
    /// starting fresh on top of it replaces it at the first publish. Set aside
    /// first, so what could not be read can still be looked at.
    private func loadGraphToResumeLocked(at directory: URL) -> ExploreGraph? {
        let file = directory.appendingPathComponent("graph.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        if let loaded = Self.loadGraph(at: directory) { return loaded }
        quarantineLocked(file, what: "карта")
        return nil
    }

    /// Why a store file would not take a write: something a person has to move
    /// before any attempt can work, or a disk that may well take the next one.
    ///
    /// The tab tells the two apart by status — a refusal it must stop repeating
    /// against one worth trying again. A directory sitting where a file belongs
    /// never resolves itself, and a page that keeps posting into it every few
    /// seconds promises to retry an arrangement that is already lost.
    private func writeRefusalLocked(_ file: URL, _ error: Error) -> ExploreRequestError {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        func settled(_ complaint: String) -> ExploreRequestError {
            storeWarnings[file.lastPathComponent] = complaint
            return .conflict(complaint)
        }
        if manager.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return settled("\(file.lastPathComponent) — каталог, а не файл; записать туда нечего до того, как его уберут.")
        }
        if manager.fileExists(atPath: configuration.root.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return settled("\(configuration.root.lastPathComponent) — файл, а не каталог; хранилище карты не записать, пока его не уберут.")
        }
        return .failure("Could not write \(file.lastPathComponent): \(error.localizedDescription)")
    }

    /// Moves a file this build must not use out of the way instead of writing
    /// over it, and says so where a person will see it — under that file's own
    /// name, so the notice lasts until that file is news again. Nothing else
    /// can raise it a second time: the next read of a quarantined file simply
    /// finds it missing, which is the normal state of a store nobody has
    /// written yet and says nothing at all.
    private func quarantineLocked(_ file: URL, what: String) {
        let aside = file.appendingPathExtension("broken-\(Self.quarantineStamp.string(from: Date()))")
        do {
            try FileManager.default.moveItem(at: file, to: aside)
            storeWarnings[file.lastPathComponent] = "\(file.lastPathComponent) не читается (\(what)) — файл отложен как \(aside.lastPathComponent)."
        } catch {
            storeWarnings[file.lastPathComponent] = "\(file.lastPathComponent) не читается (\(what)), и отложить его не удалось: \(error.localizedDescription)"
        }
    }

    /// Everything the store holds about one app: its map, its screenshots, the
    /// arrangement of its cards, the names of its features. Dropped together
    /// when the app under exploration changes — one of them outliving the
    /// others is what "leftover" means.
    private func discardStoreLocked() {
        let manager = FileManager.default
        for name in ["graph.json", "shots", "layout.json", "groups.json"] {
            try? manager.removeItem(at: configuration.root.appendingPathComponent(name))
        }
        loadedRunSignature = nil
        layout = ExploreLayout()
        layoutSignature = nil
        futureLayoutVersion = nil
        futureNamesVersion = nil
        // The files the notices were about are gone with the rest of the store.
        storeWarnings.removeAll()
    }

    /// The store used to be one directory per run. Adopt the newest run as the
    /// single store (its map is the freshest picture of the app) and drop the
    /// rest — they are regenerable crawl artifacts, not history worth keeping.
    ///
    /// Once, not on every status poll: this walks the store directory to answer
    /// a question whose answer cannot change after the first pass, and the tab
    /// asks for the status every three seconds.
    private func migrateLegacyRunsLocked() {
        guard !legacyRunsMigrated else { return }
        let manager = FileManager.default
        let store = configuration.root.appendingPathComponent("graph.json")
        let legacyRuns = ((try? manager.contentsOfDirectory(at: configuration.root, includingPropertiesForKeys: nil)) ?? [])
            .filter { manager.fileExists(atPath: $0.appendingPathComponent("graph.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard !legacyRuns.isEmpty else {
            legacyRunsMigrated = true
            return
        }
        if !manager.fileExists(atPath: store.path), let newest = legacyRuns.first {
            let shots = newest.appendingPathComponent("shots", isDirectory: true)
            do {
                if manager.fileExists(atPath: shots.path) {
                    try manager.moveItem(at: shots, to: configuration.root.appendingPathComponent("shots", isDirectory: true))
                }
                try manager.moveItem(at: newest.appendingPathComponent("graph.json"), to: store)
            } catch {
                // The map we meant to adopt is still in its old directory, and
                // the sweep below deletes every one of those: a move that failed
                // — a `shots` already at the root, most often — used to take the
                // only copy of the screenshots with it. Leave everything where
                // it is and say so; nothing is lost, and the next poll retries
                // once someone has looked.
                storeWarnings[newest.lastPathComponent] = "Прежний прогон \(newest.lastPathComponent) не перенесён: \(error.localizedDescription) Каталог оставлен на месте."
                return
            }
        }
        for legacy in legacyRuns {
            try? manager.removeItem(at: legacy)
            // The retry got through: whatever this directory was blamed for is
            // no longer there to look at.
            storeWarnings[legacy.lastPathComponent] = nil
        }
        legacyRunsMigrated = true
    }

    private static let quarantineStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Convention: a profile named `<name>-resume` is that profile's relaunch
    /// companion — a session reused instead of a full login on every pass.
    ///
    /// Looked up from the profile the run actually uses, never from the name
    /// `explore`: every run relaunched through `explore-resume` from its second
    /// pass on, including a run someone asked for by name, so the map came out
    /// glued together from two configurations with only the first recorded in
    /// `graph.run.profile`.
    static func resumeProfile(for profile: LaunchProfile?, in profiles: [LaunchProfile]) -> LaunchProfile? {
        guard let name = profile?.name else { return nil }
        return profiles.first { $0.name == "\(name)-resume" }
    }

    // MARK: what the store keeps

    /// The map as it goes to disk: the crawl's own record, plus the flow
    /// annotations a reader of the store wants.
    ///
    /// Nothing is added on top of `annotated`, and there used to be — a loop
    /// that copied every recorded depth back over the annotated one, in case
    /// the annotation had measured a new one. It never had; deleting the loop
    /// changed no map and broke no test, which is all a guard against a caller
    /// that cannot misbehave can ever amount to. What the store may and may not
    /// carry is `annotated`'s own promise, tested where it is made
    /// (`ExploreGroupingTests.testTheStoreKeepsWhatTheCrawlRecorded`), and the
    /// name here says which map goes where.
    static func storeSnapshot(_ graph: ExploreGraph) -> ExploreGraph {
        ExploreGrouping.annotated(graph)
    }

    /// Writes the store, throwing when it could not be written. The failure was
    /// swallowed here (`try?`), so a run whose writes all failed still finished
    /// with "Готово: N экранов" over a file that was not there.
    static func writeStore(_ snapshot: ExploreGraph, to directory: URL) throws {
        try JSON.data(snapshot, pretty: true)
            .write(to: directory.appendingPathComponent("graph.json"), options: [.atomic])
    }

    /// The same write, and what the run has to say about the store afterwards:
    /// nothing when it went through, why not when it did not.
    ///
    /// One answer for both writers. The closing write used to swallow its
    /// failure, so a run reported "Готово: 30 экранов" over a file that was
    /// never there; the per-step write grew a recovery of its own for the
    /// opposite case, a run still complaining after the map had actually landed
    /// on disk. Two writers, two half-answers. Recomputed from the attempt in
    /// hand, so neither direction can be the one that was forgotten.
    static func writeStoreReportingFailure(_ snapshot: ExploreGraph, to directory: URL) -> String? {
        do {
            try writeStore(snapshot, to: directory)
            return nil
        } catch {
            return "Карта не сохранена: \(error.localizedDescription)"
        }
    }

    // MARK: the frontier (pure, so tests can ask it directly)

    /// Nodes that still hold untried taps.
    ///
    /// The node's stored key sets are the answer, and the states walked this run
    /// only add to it. Judging a visited screen by the states seen this pass let
    /// the crawl call a screen with several states finished on the strength of
    /// one of them, while `ExploreEngine.hasUntriedActions` — the same question,
    /// asked by the map over the same node — still showed untried taps on that
    /// card. Two answers to one question is a bug wherever they differ, so
    /// there is one, and it is the one the map shows.
    static func nodesWithUntried(states: [String: ScreenState], nodes: [ExploreScreenNode]) -> Set<String> {
        var result = Set(nodes.filter(ExploreEngine.hasUntriedActions).map(\.id))
        // A key tried in another state of the same screen is tried as far as the
        // store is concerned, and untried in the state in hand — where the crawl
        // can still act on it. That is work left, so it counts.
        for state in states.values
        where state.actions.contains(where: { !state.triedKeys.contains($0.key) }) {
            result.insert(state.nodeId)
        }
        return result
    }

    /// The first hop of the shortest recorded path from `origin` to a node that
    /// still has untried taps — the action to replay when the screen in hand is
    /// worked out.
    ///
    /// A path whose first hop this screen cannot reproduce is skipped, not taken
    /// as the answer: the search used to give up the moment the nearest target's
    /// first hop did not match, with a queue still full of other paths. One
    /// scroll edge out of the current screen was enough to trigger it, because a
    /// scroll records no target and the match asked for a non-scroll action with
    /// none — a pair nothing can satisfy. So the descent was declared
    /// impossible, the pass went barren, and two of those ended the run with
    /// "дальше идти некуда" over a map full of untapped screens.
    static func descentAction(
        from origin: String,
        actions: [ExploreEngine.Action],
        edges: [ExploreTransitionEdge],
        targets: Set<String>
    ) -> ExploreEngine.Action? {
        guard !targets.isEmpty else { return nil }
        var adjacency: [String: [(to: String, action: ExploreTransitionAction)]] = [:]
        for edge in edges {
            adjacency[edge.from, default: []].append((edge.to, edge.action))
        }
        // BFS in node space; edges only ever descend (the depth rule), so this
        // terminates without cycle bookkeeping beyond `visited`.
        var queue: [(node: String, firstHop: ExploreTransitionAction?)] = [(origin, nil)]
        var visited: Set<String> = [origin]
        while !queue.isEmpty {
            let (node, firstHop) = queue.removeFirst()
            if targets.contains(node), let firstHop, let action = replaying(firstHop, from: actions) {
                return action
            }
            for (to, action) in adjacency[node] ?? [] where !visited.contains(to) {
                visited.insert(to)
                queue.append((to, firstHop ?? action))
            }
        }
        return nil
    }

    /// The action on the screen in hand that would repeat a recorded
    /// transition. A scroll carries nothing to aim at, so it is matched by kind;
    /// a tap by what it aimed at.
    private static func replaying(
        _ recorded: ExploreTransitionAction,
        from actions: [ExploreEngine.Action]
    ) -> ExploreEngine.Action? {
        guard recorded.kind != "scroll" else { return actions.first(where: \.isScroll) }
        return actions.first {
            !$0.isScroll && $0.targetId == recorded.targetId && $0.targetLabel == recorded.targetLabel
        }
    }

    /// Whether the screen in hand belongs to the app under exploration, and the
    /// name it gave for itself if it gave one.
    ///
    /// Nothing to check against (`expected` empty — an app that names itself
    /// nowhere in its bundle) means every screen passes, as it did before the
    /// launch was checked at all. Otherwise the root label decides.
    ///
    /// A blank root label is not the absence of an answer — it is SpringBoard's
    /// answer. Measured on a booted simulator: the app under exploration reports
    /// its display name, and SpringBoard reports a single space. So a screen that
    /// names nothing is not the app, and the permission alert iOS puts over a
    /// freshly installed app is exactly that screen. Treating the space as
    /// "undecidable, carry on" let a crawl map `SBSwitcherWindow:Main` as one of
    /// the app's own screens.
    ///
    /// The name comes back trimmed and only when there is one, so nothing
    /// narrows the expectation down to whitespace.
    static func appMatch(rootLabel: String?, expected: Set<String>) -> (isApp: Bool, label: String?) {
        guard !expected.isEmpty else { return (true, nil) }
        guard let rootLabel else { return (false, nil) }
        let label = rootLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return (false, nil) }
        return (expected.contains { $0.compare(label, options: .caseInsensitive) == .orderedSame }, label)
    }

    /// What to call a screen that settled on something other than the app, when
    /// a failure has to name it. A screen that named nothing is described rather
    /// than quoted: the message read «на экране « »», which tells a reader that
    /// the crawl is confused rather than that iOS is in front of them.
    static let unnamedScreenDescription = "системный экран без названия"

    // MARK: what a node has been through

    /// Adds action keys to what the screen is known to offer. Both counters a
    /// node publishes are sizes of key sets, so "tried" and "total" mean the
    /// same kind of thing and can be compared — the per-state sums they used to
    /// be could not (one button in two states counted twice in the total and
    /// once among the tried, and the total could even end up below the tried
    /// count).
    static func catalogue(_ keys: [String], on node: inout ExploreScreenNode) {
        var known = Set(node.actionKeys ?? [])
        // A store from before the keys were kept knows only its old total; the
        // union starts from the keys of the state at hand and grows.
        known.formUnion(keys)
        node.actionKeys = known.sorted()
        node.actionsTotal = max(known.count, node.actionsTried)
    }

    /// Records a tap in the set the next run continues from.
    ///
    /// `legacyTriedCount` is what a schema-1 store published as this screen's
    /// tried count with no keys behind it. Re-tapping such a screen is
    /// deliberate — its key set has to be rebuilt from nothing — but the share
    /// the map already showed must not walk backwards while that happens: `5/8`
    /// turned into `1/10` on the first tap of the next run. So the count is the
    /// larger of the rebuilt set and the history, and only there can it exceed
    /// the number of keys listed.
    /// The depth a screen the crawl has already charted keeps.
    ///
    /// Normally the shorter of what it had and how far this pass walked to
    /// reach it — a shorter path is news about the app. A pass *landing* on the
    /// screen is not: `reached` is then zero for every relaunch, and flattening
    /// a screen charted three taps in to zero on each of them told the reader
    /// the app opens there. The reader believes it — the map is measured from
    /// its openings, and among two openings that lead to each other the
    /// shallower recorded depth is what decides which one the map hangs on
    /// (`ExploreGrouping.rootOrder`). A flattened depth handed that job to
    /// whichever screen happened to be busiest, and the arrow from the launch
    /// screen into the hub it landed on stopped being drawn.
    static func settledDepth(recorded: Int, reached: Int, isLanding: Bool) -> Int {
        isLanding ? recorded : min(recorded, reached)
    }

    static func markTried(_ key: String, on node: inout ExploreScreenNode, legacyTriedCount: Int = 0) {
        var persisted = Set(node.triedActionKeys ?? [])
        persisted.insert(key)
        node.triedActionKeys = persisted.sorted()
        node.actionsTried = max(persisted.count, legacyTriedCount)
        catalogue([key], on: &node)
    }

    // MARK: crawl loop

    private func crawl(
        app: String,
        profile: LaunchProfile?,
        resumeProfile: LaunchProfile?,
        directory: URL,
        budgets: Budgets,
        fromCurrentScreen: Bool = false
    ) async {
        let shotsDirectory = directory.appendingPathComponent("shots", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: shotsDirectory, withIntermediateDirectories: true)
        } catch {
            finish(error: "Не удалось создать каталог прогона: \(error.localizedDescription)")
            return
        }

        // Resume from the store: previous runs' nodes and edges are the
        // starting map; their persisted screen keys and tried actions let this
        // run attach to known screens and continue the frontier instead of
        // re-mapping from scratch.
        lock.lock()
        let resumed = graph
        lock.unlock()
        var screens: [String: ScreenState] = [:]
        var nodes: [ExploreScreenNode] = resumed?.nodes ?? []
        /// Fingerprint → index in `nodes`. Many-to-one: every structural state
        /// of a screen points at the screen's single canvas node.
        var nodeIndex: [String: Int] = [:]
        /// Screen key → index in `nodes` — what makes a later state of a known
        /// screen land on the existing node instead of minting a duplicate.
        var nodeIndexByKey: [String: Int] = [:]
        for (index, node) in nodes.enumerated() {
            nodeIndex[node.fingerprint] = index
            nodeIndexByKey[node.key ?? node.fingerprint] = index
        }
        var edges: [ExploreTransitionEdge] = resumed?.edges ?? []
        var edgeIndex: [String: Int] = [:]
        for (index, edge) in edges.enumerated() {
            edgeIndex["\(edge.from)→\(edge.to)→\(edge.action.kind)|\(edge.action.targetId ?? edge.action.targetLabel ?? "")"] = index
        }
        /// The node each node was first reached from (node-id space, so any
        /// state of the origin screen counts). A tap that lands back on it is
        /// a return, whatever the button was called.
        var arrivedFrom: [String: String] = [:]
        var steps = 0
        var relaunches = 0
        /// Published stats stay cumulative across runs; budgets meter this run.
        let priorSteps = resumed?.stats.steps ?? 0
        let priorRelaunches = resumed?.stats.relaunches ?? 0
        let priorScreens = nodes.count
        /// The tried count a schema-1 node published with no keys behind it, per
        /// node id. Its key set is rebuilt from nothing over this run, and the
        /// share the map already showed must not fall while that happens.
        var legacyTriedCounts: [String: Int] = [:]
        for node in nodes where node.triedActionKeys == nil {
            legacyTriedCounts[node.id] = node.actionsTried
        }
        /// Node ids whose screenshot was already retaken this run: every screen
        /// the run reaches gets one fresh shot, so the store's pictures track
        /// the app as it is now.
        var refreshedShots: Set<String> = []
        /// The names the launched app may present as its accessibility root.
        /// Seeded from the installed bundle, because the first snapshot cannot
        /// be trusted to vouch for itself: a launch that silently failed
        /// settles on the iOS home screen, and accepting it made the crawl map
        /// SpringBoard — its icons and app switcher — as if it were the app.
        /// Every name the bundle carries counts, not just `Info.plist`'s: the
        /// root label is the *localized* display name, so a Spanish app checked
        /// against the base name would reject its own launch and the whole
        /// crawl with it. Narrowed to the one observed name once a launch is
        /// confirmed, so a later hop out of the app is still caught.
        var expectedApp: Set<String> = await installedAppDisplayNames(bundleId: app)
        /// The root label of the last screen that settled, so a launch nothing
        /// matched can say what it saw instead of only that it failed.
        var lastSettledLabel: String?
        /// Whether a settled screen belongs to the app under exploration.
        /// Undecidable when the app names itself nowhere — then any screen
        /// passes, as it did before the launch was checked at all.
        func isExpectedApp(_ snapshot: [AccessibilityFlatNode]) -> Bool {
            let root = ExploreEngine.applicationLabel(of: snapshot)
            let match = Self.appMatch(rootLabel: root, expected: expectedApp)
            // Named or not, a screen that had a root node did settle on
            // something, and the failure below has to be able to say what.
            if root != nil, !expectedApp.isEmpty {
                lastSettledLabel = match.label ?? Self.unnamedScreenDescription
            }
            return match.isApp
        }
        // One scan of the checkout per run: visible strings on every screen
        // reverse-map to the localization keys that mint them.
        let localization = configuration.projectRoot.map(LocalizationIndex.build) ?? .empty

        /// What to say about the store instead of "Готово" when a write failed.
        var storeWriteError: String?

        func publish(_ text: String?) {
            // Which transitions the map *draws* is a question about the screens'
            // distances from the app's openings, and those keep moving as the
            // crawl finds shorter paths — so the answer is computed on read
            // (`ExploreGrouping.descending`) and never baked into the store.
            // Storing only the drawn ones cost the map real transitions: a
            // relaunch that landed on a charted screen made it an opening, and
            // every arrow into it vanished from the file for good.
            let drawn = ExploreGrouping.descending(edges: edges, nodes: nodes).count
            lock.lock()
            if let text { message = text }
            graph?.nodes = nodes
            graph?.edges = edges
            graph?.stats = ExploreStats(
                screens: nodes.count,
                transitions: drawn,
                steps: priorSteps + steps,
                relaunches: priorRelaunches + relaunches
            )
            let snapshot = graph.map(Self.storeSnapshot)
            lock.unlock()
            guard let snapshot else { return }
            // A map nobody could write must not end the run with "Готово: N
            // экранов" — the number would describe a file that is not there —
            // and a write that goes through afterwards must take the complaint
            // back, or the run sends someone hunting for a map that is on disk.
            // Assigned either way for that second half: nothing else touches
            // `lastError` while a run is in flight.
            storeWriteError = Self.writeStoreReportingFailure(snapshot, to: directory)
            lock.lock()
            lastError = storeWriteError
            lock.unlock()
        }

        /// Retakes a node's screenshot once per run, so the store's pictures
        /// track the app as it is now instead of freezing at first discovery.
        func refreshShot(_ nodeId: String) async {
            guard !refreshedShots.contains(nodeId) else { return }
            refreshedShots.insert(nodeId)
            if let png = try? await SimulatorScreenshotClient.png(deviceUDID: configuration.device.udid, maxDimension: 700) {
                try? png.write(to: directory.appendingPathComponent("shots/\(nodeId).png"), options: [.atomic])
            }
        }

        /// Records the screen a snapshot shows and returns its fingerprint. A
        /// new state of a known screen (same screen key, different structure)
        /// joins the existing node — only its actions extend the crawl
        /// frontier. Screens persisted by previous runs attach the same way,
        /// seeded with the actions they already tried.
        ///
        /// `isEntry` marks the screen a pass launched into — a fact about the
        /// app, recorded whether or not a tap also reaches the screen, and it
        /// is `ExploreGrouping.rootmost` that decides what the drawn map makes
        /// of the mark. The landing is not a shorter path to anywhere, so the
        /// screen keeps the depth it was charted at; see `settledDepth`.
        func record(_ snapshot: [AccessibilityFlatNode], depth: Int, isEntry: Bool = false) async -> String {
            let fingerprint = ExploreEngine.fingerprint(of: snapshot)
            func settled(_ current: Int) -> Int {
                Self.settledDepth(recorded: current, reached: depth, isLanding: isEntry)
            }
            if var known = screens[fingerprint] {
                known.depth = settled(known.depth)
                screens[fingerprint] = known
                if let index = nodeIndex[fingerprint] {
                    nodes[index].visits += 1
                    nodes[index].depth = settled(nodes[index].depth)
                    if isEntry { nodes[index].entryPoint = true }
                    await refreshShot(nodes[index].id)
                }
                return fingerprint
            }
            let actions = ExploreEngine.actions(from: snapshot)
            let key = ExploreEngine.screenKey(of: snapshot) ?? fingerprint
            let localizationKeys = localization.keys(forLabels: ExploreEngine.contentLabels(of: snapshot))
            if let index = nodeIndex[fingerprint] ?? nodeIndexByKey[key] {
                // A fingerprint the store already carries is a revisit of a
                // known state, not a new one — only a genuinely new structure
                // of the screen grows the state and action counters.
                let isNewState = nodeIndex[fingerprint] == nil
                screens[fingerprint] = ScreenState(
                    nodeId: nodes[index].id,
                    depth: settled(nodes[index].depth),
                    actions: actions,
                    triedKeys: Set(nodes[index].triedActionKeys ?? [])
                )
                nodeIndex[fingerprint] = index
                nodeIndexByKey[key] = index
                // Stores from before schema 2 carry no key — adopt this one, so
                // the next run can match the screen even if its structure moved.
                if nodes[index].key == nil { nodes[index].key = key }
                if isNewState {
                    nodes[index].states = (nodes[index].states ?? 1) + 1
                }
                catalogue(actions.map(\.key), on: index)
                nodes[index].visits += 1
                nodes[index].depth = settled(nodes[index].depth)
                if isEntry { nodes[index].entryPoint = true }
                var mergedKeys = nodes[index].localizationKeys ?? []
                for key in localizationKeys where !mergedKeys.contains(key) && mergedKeys.count < 30 {
                    mergedKeys.append(key)
                }
                nodes[index].localizationKeys = mergedKeys.isEmpty ? nil : mergedKeys
                await refreshShot(nodes[index].id)
                return fingerprint
            }
            let nodeId = "s-\(fingerprint.prefix(10))"
            screens[fingerprint] = ScreenState(nodeId: nodeId, depth: depth, actions: actions)
            let shot = "shots/\(nodeId).png"
            refreshedShots.insert(nodeId)
            if let png = try? await SimulatorScreenshotClient.png(deviceUDID: configuration.device.udid, maxDimension: 700) {
                try? png.write(to: directory.appendingPathComponent(shot), options: [.atomic])
            }
            nodes.append(ExploreScreenNode(
                id: nodeId,
                title: ExploreEngine.title(for: snapshot, fallback: "Экран \(fingerprint.prefix(6))"),
                fingerprint: fingerprint,
                key: key,
                screenshot: shot,
                depth: depth,
                visits: 1,
                states: 1,
                actionsTotal: Set(actions.map(\.key)).count,
                actionsTried: 0,
                firstSeenAt: Self.timestamp(),
                triedActionKeys: nil,
                actionKeys: Set(actions.map(\.key)).sorted(),
                deeplinks: nil,
                localizationKeys: localizationKeys.isEmpty ? nil : localizationKeys,
                entryPoint: isEntry ? true : nil
            ))
            nodeIndex[fingerprint] = nodes.count - 1
            nodeIndexByKey[key] = nodes.count - 1
            return fingerprint
        }

        func recordEdge(from: String, to: String, action: ExploreTransitionAction) {
            // fromId == toId is a state change inside one screen, not a
            // transition the map should draw.
            guard let fromId = screens[from]?.nodeId, let toId = screens[to]?.nodeId, fromId != toId else { return }
            // Every forward transition is recorded — that a tap on this screen
            // opened that one is a fact about the app, and facts belong in the
            // store. Which of them the map draws (only descents into deeper
            // territory; a hop onto a shallower screen is the crawler coming
            // back and would only tangle the map) is decided on read, because
            // the depths it depends on keep moving under it.
            let key = "\(fromId)→\(toId)→\(action.kind)|\(action.targetId ?? action.targetLabel ?? "")"
            if let index = edgeIndex[key] {
                edges[index].count += 1
                return
            }
            edges.append(ExploreTransitionEdge(id: "e-\(edges.count + 1)", from: fromId, to: toId, action: action, count: 1))
            edgeIndex[key] = edges.count - 1
        }

        func catalogue(_ keys: [String], on index: Int) {
            Self.catalogue(keys, on: &nodes[index])
        }

        func markTried(_ fingerprint: String, key: String) {
            screens[fingerprint]?.triedKeys.insert(key)
            if let index = nodeIndex[fingerprint] {
                // Persisted so the next run continues the frontier here.
                let legacyTried = legacyTriedCounts[nodes[index].id] ?? 0
                Self.markTried(key, on: &nodes[index], legacyTriedCount: legacyTried)
            }
        }

        func untriedAction(on fingerprint: String) -> ExploreEngine.Action? {
            guard let state = screens[fingerprint] else { return nil }
            // Non-back actions first: back closes the screen we are mining.
            return state.actions.first { !$0.isBack && !state.triedKeys.contains($0.key) }
                ?? state.actions.first { $0.isBack && !state.triedKeys.contains($0.key) }
        }

        /// When the current screen is exhausted, a tried action can still be
        /// worth replaying: the first hop of the shortest recorded path to a
        /// screen that has untried actions. Without this, every relaunch
        /// strands the crawl on the worked-out start screen while the
        /// frontier sits three taps deeper.
        func descentAction(on fingerprint: String) -> ExploreEngine.Action? {
            guard let state = screens[fingerprint] else { return nil }
            return Self.descentAction(
                from: state.nodeId,
                actions: state.actions,
                edges: edges,
                targets: nodesWithUntried()
            )
        }

        /// Nodes that still hold untried taps: what the map says about every
        /// screen it carries, plus what the states walked this run add to it.
        /// Screen states live for one run, the map does not — reading the
        /// frontier from visited states alone made a resumed run call the map
        /// finished the moment its start screen was exhausted, while every
        /// screen one tap deeper still had most of its actions untried.
        func nodesWithUntried() -> Set<String> {
            Self.nodesWithUntried(states: screens, nodes: nodes)
        }

        func anyUntriedRemains() -> Bool {
            !nodesWithUntried().isEmpty
        }

        /// A close/back control to re-tap on a screen that has nothing untried
        /// and no path onward. A popup the app raises on every launch (a survey,
        /// a rate-us sheet) is such a dead end: its own controls were all tried
        /// in an earlier pass, and the screen it covers is unreachable until it
        /// is dismissed. Tapping it again is not exploration — it is getting out
        /// of the way — so it happens once per screen per pass, and the edge
        /// rules keep the return off the map.
        func escapeAction(on fingerprint: String) -> ExploreEngine.Action? {
            guard let state = screens[fingerprint] else { return nil }
            return state.actions.first { $0.isBack && !$0.isScroll }
        }

        func budgetsExhausted() -> Bool {
            // Budgets meter this run's own work: a resumed store full of
            // screens must not exhaust the screen budget on arrival.
            steps >= budgets.maxSteps || nodes.count - priorScreens >= budgets.maxScreens || Date() >= budgets.deadline
        }

        var attachToCurrentScreen = fromCurrentScreen
        /// Passes that ended without a single step or new screen. Two in a row
        /// mean the launch lands on the same worked-out screen every time and
        /// nothing gets out of it — relaunching a third time would repeat it
        /// until the budget runs out.
        var barrenPasses = 0
        var stalled = false
        /// Why a relaunch after the first pass could not get the app up. Ends the
        /// run with what it has instead of discarding it.
        var lateLaunchFailure: String?
        do {
            passes: while !Task.isCancelled, !budgetsExhausted(), relaunches < budgets.maxRelaunches {
                if relaunches > 0, !anyUntriedRemains() { break }
                relaunches += 1
                publish("Запуск \(relaunches): жду стабилизации экрана…")
                // Auto-login profiles (fast login, auto-passcode) can spend
                // most of a minute before the first identified screen shows
                // up, so a launch deserves several settling windows — and a
                // settle that lands outside the app (a leftover app switcher
                // above the fresh launch) does not count as launched.
                var launched: [AccessibilityFlatNode]?
                var launchError: String?
                if attachToCurrentScreen {
                    // Someone staged this session by hand. Launching would undo
                    // it, so the first pass starts from what is on screen; if
                    // the app is not there after all, the launch below runs.
                    attachToCurrentScreen = false
                    publish("Продолжаю с текущего экрана: жду стабилизации…")
                    if let settled = try await settledSnapshot(stableReads: 4, deadline: budgets.deadline),
                       isExpectedApp(settled) {
                        launched = settled
                    } else {
                        publish("На экране не \(app) — запускаю приложение…")
                    }
                }
                // The time budget bounds the launch phase too: three launch
                // attempts at a two-minute timeout each, plus a settling window
                // after every one of them, used to run to the end whatever the
                // clock said — a pass begun a millisecond before the deadline
                // went on for minutes.
                for _ in 0..<3 where launched == nil && !budgetsExhausted() {
                    do {
                        try await launch(
                            app: app,
                            profile: relaunches == 1 ? profile : (resumeProfile ?? profile),
                            deadline: budgets.deadline
                        )
                        launchError = nil
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // simctl reports "did not return a process handle nor
                        // launch error" for launches that did start the app, so
                        // the screen below still gets its chance — and a launch
                        // that truly failed is one retry of this loop, not the
                        // end of the crawl.
                        launchError = error.localizedDescription
                        publish("Запуск \(relaunches) не удался, пробую снова…")
                    }
                    let settled = try await settledSnapshot(stableReads: 8, deadline: budgets.deadline)
                    if let settled, isExpectedApp(settled) {
                        launched = settled
                    }
                }
                guard let snapshot = launched else {
                    let failure: String
                    if let launchError {
                        failure = "Не удалось запустить \(app): \(launchError)"
                    } else if let lastSettledLabel, !expectedApp.isEmpty {
                        // The screen did settle — on something that is not the
                        // app. Naming both sides is the difference between a
                        // diagnosable mismatch and a dead end.
                        failure = """
                            После запуска \(app) на экране «\(lastSettledLabel)», \
                            а ожидалось \(expectedApp.sorted().map { "«\($0)»" }.joined(separator: " или ")).
                            """
                    } else {
                        failure = "Экран не стабилизировался после запуска \(app)."
                    }
                    // Nothing failed if nobody waited: the budget cut the launch
                    // phase short, and the closing reason below says so.
                    if budgetsExhausted() { break passes }
                    // Not getting the app up at all is the run failing — there is
                    // no map yet, and no reason to expect the next try to differ.
                    // Not getting it up on the eighth pass, after thirty screens,
                    // is a reason to stop rather than to throw the pass away: the
                    // map, the deeplink attribution and the closing tally are all
                    // still worth having.
                    if relaunches == 1 {
                        finish(error: failure)
                        return
                    }
                    lateLaunchFailure = failure
                    break passes
                }
                // Narrowed to the one name this launch actually showed — but only
                // to a name. A blank root label is no name at all (see
                // `appMatch`), and pinning the expectation to it would make every
                // equally blank screen pass for the app from here on. Read off
                // the snapshot rather than through `appMatch`, so an app that
                // names itself nowhere in the bundle still gets its expectation
                // narrowed to what its own launch showed.
                if let label = ExploreEngine.applicationLabel(of: snapshot)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    expectedApp = [label]
                }
                var current = await record(snapshot, depth: 0, isEntry: true)
                publish("Стартовый экран: \(nodeTitle(nodes, screens, current))")
                let stepsAtPassStart = steps
                let screensAtPassStart = nodes.count
                var escaped: Set<String> = []
                /// Steps this pass spent only getting out of the way. They are
                /// not progress, so a pass that did nothing else still counts
                /// as barren — otherwise a launch popup whose ✕ leads nowhere
                /// resets the stall detector on every pass and the crawl burns
                /// its whole relaunch budget re-tapping it.
                var escapeSteps = 0

                while !Task.isCancelled, !budgetsExhausted() {
                    let fresh = untriedAction(on: current)
                    // One BFS per step: the descent is asked for once and the
                    // answer reused, both to decide whether an escape is needed
                    // and as the action to take when it is not.
                    let descent = fresh == nil ? descentAction(on: current) : nil
                    var escape: ExploreEngine.Action?
                    if fresh == nil, descent == nil, !escaped.contains(current) {
                        escape = escapeAction(on: current)
                        if escape != nil {
                            escaped.insert(current)
                            publish("Экран испробован — закрываю его, чтобы добраться до того, что под ним…")
                        }
                    }
                    guard let action = fresh ?? escape ?? descent else { break }
                    if escape != nil { escapeSteps += 1 }
                    let isReplay = fresh == nil
                    markTried(current, key: action.key)
                    steps += 1
                    if action.isScroll {
                        publish("Шаг \(steps): скролл вниз")
                        _ = try? await SimulatorInputClient.swipe(
                            deviceUDID: configuration.device.udid,
                            startX: action.x, startY: action.y,
                            endX: action.x, endY: action.endY,
                            duration: 0.4
                        )
                    } else {
                        let described = action.targetLabel ?? action.targetId ?? "(\(Int(action.x)), \(Int(action.y)))"
                        // An escape is not a descent: it re-taps a control
                        // whose screen is worked out, to get out of the way of
                        // what sits under it. Calling both "спуск" made the
                        // status line describe the opposite of what happened.
                        let intent = escape != nil ? "выход — " : (isReplay ? "спуск — " : "")
                        publish("Шаг \(steps): \(intent)tap «\(described)»")
                        _ = try? await SimulatorInputClient.tap(deviceUDID: configuration.device.udid, x: action.x, y: action.y)
                    }
                    guard let after = try await settledSnapshot() else {
                        // A webview, or a native screen carrying no identifiers
                        // at all, is invisible to the snapshot reader — and
                        // whatever this one is, we no longer know what is in
                        // front of us. Going back to the top of the loop kept
                        // tapping the catalog of the screen we just left, blind,
                        // by its coordinates, with the denylist filtering a
                        // snapshot nobody is looking at. Relaunching is the
                        // honest way out; the tap that got us here is already
                        // marked tried, so the next pass walks past it.
                        publish("Экран не распознан — перезапускаю…")
                        break
                    }
                    if !isExpectedApp(after) {
                        // The tap left the app (switcher, external link, crash):
                        // SpringBoard is not part of the map — relaunch instead.
                        publish("Тап увёл из приложения — перезапускаю…")
                        break
                    }
                    let next = await record(after, depth: (screens[current]?.depth ?? 0) + 1)
                    if next != current {
                        // The map only draws forward transitions. A retreat is
                        // either a back-looking tap or any tap that lands on
                        // the screen this one was reached from — iOS back
                        // buttons are titled after that screen, so vocabulary
                        // alone would miss them. Both checks run on node ids:
                        // landing on any state of the origin screen is still
                        // a return.
                        let currentNode = screens[current]?.nodeId
                        let nextNode = screens[next]?.nodeId
                        let isReturn = action.isBack
                            || (currentNode != nil && arrivedFrom[currentNode!] == nextNode)
                        if !isReturn {
                            recordEdge(from: current, to: next, action: ExploreTransitionAction(
                                kind: action.isScroll ? "scroll" : "tap",
                                targetId: action.targetId,
                                targetLabel: action.targetLabel
                            ))
                            if let currentNode, let nextNode, currentNode != nextNode,
                               arrivedFrom[nextNode] == nil {
                                arrivedFrom[nextNode] = currentNode
                            }
                        }
                        current = next
                        publish("Открыт экран: \(nodeTitle(nodes, screens, current)) (\(nodes.count) всего)")
                    } else {
                        // A replayed hop that no longer navigates is a dead
                        // end — the app changed under the recorded path, and
                        // repeating it would spin until the budget runs out.
                        if isReplay { break }
                        // A scroll that kept the structure still moved new
                        // tappables on screen — fold them into this state's
                        // catalog so the crawl can reach them.
                        if action.isScroll, var state = screens[current] {
                            let known = Set(state.actions.map(\.key))
                            // The same per-state cap as at catalog time, with
                            // headroom for what only scrolling could show.
                            let room = ExploreEngine.maxActionsPerState + 8 - state.actions.count
                            let revealed = ExploreEngine.actions(from: after)
                                .filter { !known.contains($0.key) && !$0.isScroll }
                                .prefix(max(0, room))
                            if !revealed.isEmpty {
                                state.actions += revealed
                                screens[current] = state
                                if let index = nodeIndex[current] {
                                    catalogue(revealed.map(\.key), on: index)
                                }
                            }
                        }
                        publish(nil)
                    }
                }
                if steps - escapeSteps == stepsAtPassStart, nodes.count == screensAtPassStart {
                    barrenPasses += 1
                    if barrenPasses >= 2 {
                        stalled = true
                        break passes
                    }
                } else {
                    barrenPasses = 0
                }
                if !anyUntriedRemains() { break passes }
            }
            // Deeplink attribution — static, nothing is ever opened. Routes
            // are mined from the project's own source (every `scheme://…`
            // literal, schemes read from the installed bundle's Info.plist;
            // the config's curated list rides along) and matched against the
            // names of the screens the taps discovered. Probing used to open
            // each URL after a relaunch, and every landing minted an orphan
            // node — a screen on the map that no tap reaches, often a
            // duplicate of a charted one in a different structural state.
            // An unmatched route stays unattributed instead.
            //
            // Outside the time budget, deliberately: the scan opens nothing,
            // reads only the checkout, and is the run's one chance to attribute
            // routes to the screens it just found. A crawl that walked for
            // fifteen minutes should not lose that because the deadline fell in
            // its last second.
            if !Task.isCancelled {
                publish("Ищу диплинки в исходниках…")
                var links = configuration.deeplinks.map(\.url)
                if let projectRoot = configuration.projectRoot {
                    let schemes = await installedAppSchemes(bundleId: app)
                    for url in DeeplinkHarvest.harvest(projectRoot: projectRoot, schemes: schemes)
                    where !links.contains(url) {
                        links.append(url)
                    }
                }
                let names = nodes.map(\.title)
                var attributed = 0
                for url in links {
                    guard let index = DeeplinkHarvest.screenIndex(for: url, inNames: names) else { continue }
                    var known = nodes[index].deeplinks ?? []
                    guard !known.contains(url) else { continue }
                    known.append(url)
                    nodes[index].deeplinks = known
                    attributed += 1
                }
                if attributed > 0 { publish("Диплинки из исходников: привязано \(attributed)") }
            }
            // Honest endings before the limiters: a crawl that finished the
            // frontier on its last pass reported "Исчерпан лимит перезапусков",
            // and a deadline that expired during the deeplink scan — with the
            // walking already over — reported "Бюджет исчерпан". Both named
            // something that had stopped nothing.
            let reason: String
            if Task.isCancelled { reason = "Остановлено пользователем." }
            else if !nodes.isEmpty, !anyUntriedRemains() { reason = "Все доступные действия испробованы." }
            else if stalled { reason = "Запуск приводит на тот же испробованный экран — дальше идти некуда." }
            else if let lateLaunchFailure { reason = "Перезапуск не удался. \(lateLaunchFailure)" }
            else if budgetsExhausted() { reason = "Бюджет исчерпан." }
            else if relaunches >= budgets.maxRelaunches { reason = "Исчерпан лимит перезапусков." }
            else { reason = "Обход завершён." }
            publish(nil)
            let drawn = ExploreGrouping.descending(edges: edges, nodes: nodes).count
            // Steps are cumulative across runs, the way the tab's header counts
            // them: a closing note saying "105 шагов" next to a header reading
            // "285 шагов" reads like a bug in one of the two.
            let tally = [
                ExploreEngine.counted(nodes.count, "экран", "экрана", "экранов"),
                ExploreEngine.counted(drawn, "переход", "перехода", "переходов"),
                ExploreEngine.counted(priorSteps + steps, "шаг", "шага", "шагов"),
            ].joined(separator: ", ")
            finish(error: storeWriteError, note: "Готово: \(tally). \(reason)")
        } catch is CancellationError {
            publish(nil)
            finish(error: storeWriteError, note: "Остановлено пользователем.")
        } catch {
            publish(nil)
            finish(error: "Обход прерван: \(error.localizedDescription)")
        }
    }

    private func nodeTitle(_ nodes: [ExploreScreenNode], _ screens: [String: ScreenState], _ fingerprint: String) -> String {
        guard let nodeId = screens[fingerprint]?.nodeId else { return String(fingerprint.prefix(6)) }
        return nodes.first { $0.id == nodeId }?.title ?? nodeId
    }

    private func finish(error: String?, note: String? = nil) {
        lock.lock()
        graph?.run.finishedAt = Self.timestamp()
        let snapshot = graph.map(Self.storeSnapshot)
        let directory = runDirectory
        lock.unlock()

        // The closing write is the one that matters most and was the one least
        // watched: swallowed here, it let a run report "Готово: 30 экранов" over
        // a store that was never written.
        var writeFailure: String?
        if let snapshot, let directory {
            writeFailure = Self.writeStoreReportingFailure(snapshot, to: directory)
        }

        lock.lock()
        running = false
        lastError = [error, writeFailure].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        if let note { message = note }
        if let error { message = error }
        if let writeFailure { message = writeFailure }
        lock.unlock()
    }

    // MARK: simulator I/O

    /// Relaunches through simctl with the profile's argv, arming the SimTool
    /// loggers the same way `simtool test run` does — the crawl must observe
    /// the same app configuration a recorded test would.
    private func launch(app: String, profile: LaunchProfile?, deadline: Date) async throws {
        // Home first: a system overlay a stray tap opened (the app switcher)
        // stays above a freshly launched app and would poison the snapshot.
        // The press has to land before the launch does: SpringBoard is still
        // suspending the app while `--terminate-running-process` kills it, and
        // simctl then reports the launch as "did not return a process handle
        // nor launch error" instead of starting the app.
        _ = try? await SimulatorInputClient.button("home", deviceUDID: configuration.device.udid)
        try await Task.sleep(for: .milliseconds(700))
        var environment = profile?.environment ?? [:]
        if let serverURL = configuration.appFacingServerURL {
            environment["SIMTOOL_SERVER_URL"] = environment["SIMTOOL_SERVER_URL"] ?? serverURL
            environment["SIMTOOL_NETWORK_LOGGER"] = environment["SIMTOOL_NETWORK_LOGGER"] ?? "1"
            environment["SIMTOOL_STATE_LOGGER"] = environment["SIMTOOL_STATE_LOGGER"] ?? "1"
        }
        let arguments = SimulatorAppLifecycleClient.simctlLaunchArguments(
            deviceUDID: configuration.device.udid,
            bundleIdentifier: app,
            launchArguments: (profile?.arguments ?? [])
        )
        // `--terminate-running-process` races the suspend the home press above
        // just started: simctl kills the app mid-transition and then reports
        // ESRCH ("did not return a process handle nor launch error") instead
        // of a pid. Nothing is wrong with the app — the next attempt, with the
        // transition over, launches it — so a lost race costs a retry rather
        // than the whole crawl.
        var lastFailure = ""
        for attempt in 0..<3 {
            // Under the run's own deadline, like every other phase: a launch
            // that starts after the budget is spent is work nobody is waiting
            // for, and simctl's timeout alone let three of them run for six
            // minutes past it.
            guard Date() < deadline else {
                throw SimToolError("Бюджет времени исчерпан во время запуска \(app).")
            }
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(1500))
            }
            let output = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: arguments,
                environment: SimulatorAppLifecycleClient.simctlChildEnvironment(launchEnvironment: environment),
                // Never past the deadline, and never so short that a healthy
                // launch is cut off: simctl needs its two minutes when it has
                // them.
                timeoutSeconds: min(120, max(5, deadline.timeIntervalSinceNow))
            )
            if output.status == 0 { return }
            lastFailure = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw SimToolError("simctl launch \(app) failed: \(lastFailure)")
    }

    /// The snapshot once the screen stops changing AND its data has arrived.
    /// Skeletons/shimmers settle structurally long before the backend answers,
    /// so a settled-but-loading screen keeps polling until the placeholders
    /// clear — bounded, because a screen can also shimmer forever, and then
    /// recording it as it is beats stalling the crawl.
    ///
    /// `stableReads` is how many consecutive identical reads count as settled:
    /// 2 between taps, but a launch under an auto-login profile walks through
    /// auth screens that each stand still for seconds — tapping them breaks
    /// the login — so a launch demands a much longer quiet streak.
    ///
    /// `deadline` cuts the wait short with whatever settled last. Passed by the
    /// launch phase, whose windows are counted in minutes; the wait between two
    /// taps is left alone, because a snapshot taken half-drawn maps a screen
    /// nobody ever sees.
    private func settledSnapshot(stableReads: Int = 2, deadline: Date? = nil) async throws -> [AccessibilityFlatNode]? {
        var snapshot = try await structurallySettledSnapshot(stableReads: stableReads, deadline: deadline)
        var patience = 10
        while let current = snapshot, ExploreEngine.isLoading(current), patience > 0, !Task.isCancelled,
              Date() < (deadline ?? .distantFuture) {
            patience -= 1
            try await Task.sleep(for: .milliseconds(700))
            if let refreshed = try await structurallySettledSnapshot(stableReads: stableReads, deadline: deadline) {
                snapshot = refreshed
            }
        }
        return snapshot
    }

    /// The custom URL schemes of the installed app, read from its bundle on
    /// the simulator — runtime truth, no project-side guessing.
    private func installedAppSchemes(bundleId: String) async -> [String] {
        guard let output = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "get_app_container", configuration.device.udid, bundleId, "app"],
            timeoutSeconds: 30
        ), output.status == 0 else { return [] }
        let appPath = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appPath.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: appPath).appendingPathComponent("Info.plist")) else {
            return []
        }
        return DeeplinkHarvest.schemes(fromInfoPlist: data)
    }

    /// Every name iOS could show under the app's icon — which is also the
    /// label of the accessibility root the app presents. Empty when the bundle
    /// is not installed or names itself nowhere; then the crawl has nothing to
    /// check the launch against and trusts the first settled screen.
    ///
    /// A set, not one name: the root label is the *localized* display name, and
    /// a localized app keeps that in `<lang>.lproj/InfoPlist.strings` while
    /// `Info.plist` still carries the base one. Checking against the base name
    /// alone rejected every launch of such an app, and with it the whole crawl.
    private func installedAppDisplayNames(bundleId: String) async -> Set<String> {
        guard let output = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "get_app_container", configuration.device.udid, bundleId, "app"],
            timeoutSeconds: 30
        ), output.status == 0 else { return [] }
        let appPath = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appPath.isEmpty else { return [] }
        let bundle = URL(fileURLWithPath: appPath)
        var names: Set<String> = []
        func collect(from url: URL) {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return }
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = (plist[key] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    names.insert(name)
                }
            }
        }
        collect(from: bundle.appendingPathComponent("Info.plist"))
        // Compiled `.strings` files are binary plists, so the same reader does.
        let localizations = (try? FileManager.default.contentsOfDirectory(
            at: bundle,
            includingPropertiesForKeys: nil
        )) ?? []
        for directory in localizations where directory.pathExtension == "lproj" {
            collect(from: directory.appendingPathComponent("InfoPlist.strings"))
        }
        return names
    }

    /// The accessibility snapshot once the screen stops changing:
    /// `stableReads` consecutive reads with the same structural fingerprint.
    /// Nil when the screen never settles within the window (endless
    /// animation) — the caller decides whether that is fatal.
    private func structurallySettledSnapshot(stableReads: Int = 2, deadline: Date? = nil) async throws -> [AccessibilityFlatNode]? {
        try await Task.sleep(for: .milliseconds(600))
        var streak = 1
        var previous: (fingerprint: String, nodes: [AccessibilityFlatNode])?
        for _ in 0..<(10 + stableReads * 4) {
            if Task.isCancelled { return previous?.nodes }
            if let deadline, Date() >= deadline { return previous?.nodes }
            // AXe fails transiently mid-transition ("no translation object
            // returned") — that is "not settled yet", not a fatal error, so a
            // failed read costs one retry instead of the whole run.
            let nodes: [AccessibilityFlatNode]
            do {
                let tree = try await SimulatorAccessibilityClient.normalizedTree(deviceUDID: configuration.device.udid)
                nodes = SimulatorAccessibilityClient.flatten(tree, labeledOnly: false).nodes
            } catch {
                try await Task.sleep(for: .milliseconds(700))
                continue
            }
            let fingerprint = ExploreEngine.fingerprint(of: nodes)
            // A snapshot with no identified nodes is the app still starting
            // (splash, launch storyboard) or AXe mid-transition, not a screen:
            // settling on it would map a phantom screen — and at launch end
            // the whole crawl on the spot, since it offers zero actions.
            if fingerprint == Self.emptyFingerprint {
                previous = nil
                streak = 1
                try await Task.sleep(for: .milliseconds(700))
                continue
            }
            if let previous, previous.fingerprint == fingerprint {
                streak += 1
                if streak >= stableReads { return nodes }
            } else {
                streak = 1
            }
            previous = (fingerprint, nodes)
            try await Task.sleep(for: .milliseconds(600))
        }
        return previous?.nodes
    }

    private static let emptyFingerprint = ExploreEngine.fingerprint(of: [])
}
