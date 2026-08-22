import CryptoKit
import Foundation
import SimToolCore

private extension String {
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
    /// Routes mined from the project source whose tokens name this screen.
    /// Attributed statically — the crawl never opens a deeplink.
    public var deeplinks: [String]?
    /// Localization keys whose values match this screen's visible strings,
    /// reverse-looked-up in the project checkout.
    public var localizationKeys: [String]?
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
    public var schemaVersion: Int
    /// Node id → where the user put that card. Nodes absent here fall back to
    /// the canvas' automatic depth layout.
    public var positions: [String: ExploreNodePosition]

    public init(schemaVersion: Int = 1, positions: [String: ExploreNodePosition] = [:]) {
        self.schemaVersion = schemaVersion
        self.positions = positions
    }
}

// MARK: - HTTP payloads

public struct ExploreStartRequest: Codable, Sendable {
    public var app: String?
    public var profile: String?
    public var maxScreens: Int?
    public var maxSteps: Int?
    public var budgetMinutes: Int?

    public init(
        app: String? = nil,
        profile: String? = nil,
        maxScreens: Int? = nil,
        maxSteps: Int? = nil,
        budgetMinutes: Int? = nil
    ) {
        self.app = app
        self.profile = profile
        self.maxScreens = maxScreens
        self.maxSteps = maxSteps
        self.budgetMinutes = budgetMinutes
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
            // Custom widgets read as identified Groups (`TouchRecognizingView`);
            // the size cap keeps screen-sized containers out.
            let isTappableContainer = type == "Group" && node.id?.nilIfEmpty != nil
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
            let id = node.id?.nilIfEmpty
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

        var grouped: [String: [Action]] = [:]
        var order: [String] = []
        for action in tabCandidates + candidates {
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
        // Identifier-namespace enums (`AccountUpgradeWidgetIds-Widget`,
        // `…ScreenIdentifiers-Title`) name the container of ids, not a screen.
        "ids", "identifiers",
    ]

    /// Name beginnings that mark an identifier as design-system vocabulary:
    /// a kit stamps its brand on every component (`HolaTextFieldSumm`,
    /// `HolaNumpad`), including reusable full-screen templates
    /// (`HolaOnboardingScreen` hosts *different* onboardings), so an id that
    /// opens with the brand never names one screen no matter how its tail
    /// reads — the suffix vocabulary can't keep up with every coinage.
    static let componentNamePrefixes: [String] = [
        "hola",
    ]

    /// True when an identifier names a convention rather than a screen —
    /// the one gate both naming heuristics ask, so a new stopword or component
    /// suffix lands in exactly one place.
    static func isGenericName(_ identifier: String) -> Bool {
        let lowered = identifier.lowercased()
        if titleStopwords.contains(lowered) { return true }
        return componentNamePrefixes.contains { lowered.hasPrefix($0) }
            || componentNameSuffixes.contains { lowered.hasSuffix($0) }
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

    private struct Budgets {
        var maxScreens: Int
        var maxSteps: Int
        var deadline: Date
        var maxRelaunches = 12
    }

    /// What the crawler knows about one discovered screen.
    private struct ScreenState {
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
        return ExploreStatusPayload(
            running: running,
            runId: runId,
            app: graph?.run.app ?? configuration.defaultApp,
            message: message,
            error: lastError,
            graph: graph,
            layout: layout
        )
    }

    public func start(_ request: ExploreStartRequest) throws -> ExploreStatusPayload {
        guard let app = request.app?.nilIfEmpty ?? configuration.defaultApp else {
            throw SimToolError("No app to explore: start the server with --app <bundle-id> or configure `bundleId` in .simtool/config.yml.")
        }
        let profile = try resolveProfile(named: request.profile)

        lock.lock()
        if running {
            lock.unlock()
            throw SimToolError("An exploration run is already in progress.")
        }
        let id = Self.runIdFormatter.string(from: Date())
        let directory = configuration.root
        let budgets = Budgets(
            maxScreens: max(1, request.maxScreens ?? 40),
            maxSteps: max(1, request.maxSteps ?? 200),
            deadline: Date().addingTimeInterval(TimeInterval(max(1, request.budgetMinutes ?? 15) * 60))
        )
        running = true
        runId = id
        runDirectory = directory
        lastError = nil
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
        if let existing = Self.loadGraph(at: directory), existing.run.app == app {
            graph = existing
            graph?.run = meta
            graph?.schemaVersion = 2
            message = "Продолжаю карту: \(existing.nodes.count) экранов…"
        } else {
            graph = ExploreGraph(
                schemaVersion: 2,
                run: meta,
                stats: ExploreStats(screens: 0, transitions: 0, steps: 0, relaunches: 0),
                nodes: [],
                edges: []
            )
            message = "Запускаю \(app)…"
        }
        // Convention: `explore-resume` relaunches after the first one. A fresh
        // full login on every relaunch hammers the auth backend into
        // throttling; the resume profile reuses the session instead.
        let resumeProfile = configuration.profiles.first { $0.name == "explore-resume" }
        task = Task { [weak self] in
            await self?.crawl(
                app: app,
                profile: profile,
                resumeProfile: resumeProfile,
                directory: directory,
                budgets: budgets
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
        var merged = layout.positions
        for (id, position) in positions { merged[id] = position }
        if let known = graph?.nodes, !known.isEmpty {
            let ids = Set(known.map(\.id))
            merged = merged.filter { ids.contains($0.key) }
        }
        let next = ExploreLayout(schemaVersion: 1, positions: merged)
        try FileManager.default.createDirectory(at: configuration.root, withIntermediateDirectories: true)
        try JSON.encoder.encode(next).write(to: layoutFile, options: [.atomic])
        layout = next
        layoutSignature = layoutFileSignature()
        return next
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
                throw SimToolError("Unknown launch profile '\(name)'.\(available.isEmpty ? "" : " Available: \(available).")")
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
        if isNewRun { message = "Показана карта: \(loaded.nodes.count) экранов" }
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
        guard let signature = layoutFileSignature(), signature != layoutSignature else { return }
        guard let data = try? Data(contentsOf: layoutFile),
              let decoded = try? JSON.decoder.decode(ExploreLayout.self, from: data) else { return }
        layoutSignature = signature
        layout = decoded
    }

    private static func loadGraph(at directory: URL) -> ExploreGraph? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("graph.json")) else { return nil }
        return try? JSON.decoder.decode(ExploreGraph.self, from: data)
    }

    /// The store used to be one directory per run. Adopt the newest run as the
    /// single store (its map is the freshest picture of the app) and drop the
    /// rest — they are regenerable crawl artifacts, not history worth keeping.
    private func migrateLegacyRunsLocked() {
        let manager = FileManager.default
        let store = configuration.root.appendingPathComponent("graph.json")
        let legacyRuns = ((try? manager.contentsOfDirectory(at: configuration.root, includingPropertiesForKeys: nil)) ?? [])
            .filter { manager.fileExists(atPath: $0.appendingPathComponent("graph.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard !legacyRuns.isEmpty else { return }
        if !manager.fileExists(atPath: store.path), let newest = legacyRuns.first {
            try? manager.moveItem(
                at: newest.appendingPathComponent("shots", isDirectory: true),
                to: configuration.root.appendingPathComponent("shots", isDirectory: true)
            )
            try? manager.moveItem(at: newest.appendingPathComponent("graph.json"), to: store)
        }
        for legacy in legacyRuns { try? manager.removeItem(at: legacy) }
    }

    // MARK: crawl loop

    private func crawl(
        app: String,
        profile: LaunchProfile?,
        resumeProfile: LaunchProfile?,
        directory: URL,
        budgets: Budgets
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
        /// Node ids whose screenshot was already retaken this run: every screen
        /// the run reaches gets one fresh shot, so the store's pictures track
        /// the app as it is now.
        var refreshedShots: Set<String> = []
        /// The launched app's own accessibility label, captured at launch:
        /// a snapshot rooted in anything else means a tap left the app.
        var expectedApp: String?
        // One scan of the checkout per run: visible strings on every screen
        // reverse-map to the localization keys that mint them.
        let localization = configuration.projectRoot.map(LocalizationIndex.build) ?? .empty

        // Depths only shrink as screens get rediscovered closer to the root,
        // so an edge recorded as a descent can turn lateral later — the
        // published graph re-applies the descent rule every time.
        func descentEdges() -> [ExploreTransitionEdge] {
            let depthById = Dictionary(nodes.map { ($0.id, $0.depth) }, uniquingKeysWith: { first, _ in first })
            return edges.filter { edge in
                guard let from = depthById[edge.from], let to = depthById[edge.to] else { return false }
                return to > from
            }
        }

        func publish(_ text: String?) {
            let descents = descentEdges()
            lock.lock()
            if let text { message = text }
            graph?.nodes = nodes
            graph?.edges = descents
            graph?.stats = ExploreStats(
                screens: nodes.count,
                transitions: descents.count,
                steps: priorSteps + steps,
                relaunches: priorRelaunches + relaunches
            )
            let snapshot = graph
            lock.unlock()
            guard let snapshot, let data = try? JSON.data(snapshot, pretty: true) else { return }
            try? data.write(to: directory.appendingPathComponent("graph.json"), options: [.atomic])
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
        func record(_ snapshot: [AccessibilityFlatNode], depth: Int) async -> String {
            let fingerprint = ExploreEngine.fingerprint(of: snapshot)
            if var known = screens[fingerprint] {
                known.depth = min(known.depth, depth)
                screens[fingerprint] = known
                if let index = nodeIndex[fingerprint] {
                    nodes[index].visits += 1
                    nodes[index].depth = min(nodes[index].depth, known.depth)
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
                    depth: depth,
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
                    nodes[index].actionsTotal += actions.count
                }
                nodes[index].visits += 1
                nodes[index].depth = min(nodes[index].depth, depth)
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
                actionsTotal: actions.count,
                actionsTried: 0,
                firstSeenAt: Self.timestamp(),
                triedActionKeys: nil,
                deeplinks: nil,
                localizationKeys: localizationKeys.isEmpty ? nil : localizationKeys
            ))
            nodeIndex[fingerprint] = nodes.count - 1
            nodeIndexByKey[key] = nodes.count - 1
            return fingerprint
        }

        func recordEdge(from: String, to: String, action: ExploreTransitionAction) {
            // fromId == toId is a state change inside one screen, not a
            // transition the map should draw.
            guard let fromId = screens[from]?.nodeId, let toId = screens[to]?.nodeId, fromId != toId else { return }
            // The map draws only descents into deeper territory. A tap that
            // lands on a shallower or same-depth screen is the crawler coming
            // back — the home tab, a modal's ✕, a cross-tab hop — and arrows
            // into already-charted screens only tangle the map.
            guard let fromIndex = nodeIndex[from], let toIndex = nodeIndex[to],
                  nodes[toIndex].depth > nodes[fromIndex].depth else { return }
            let key = "\(fromId)→\(toId)→\(action.kind)|\(action.targetId ?? action.targetLabel ?? "")"
            if let index = edgeIndex[key] {
                edges[index].count += 1
                return
            }
            edges.append(ExploreTransitionEdge(id: "e-\(edges.count + 1)", from: fromId, to: toId, action: action, count: 1))
            edgeIndex[key] = edges.count - 1
        }

        func markTried(_ fingerprint: String, key: String) {
            screens[fingerprint]?.triedKeys.insert(key)
            if let index = nodeIndex[fingerprint], let nodeId = screens[fingerprint]?.nodeId {
                nodes[index].actionsTried = screens.values
                    .filter { $0.nodeId == nodeId }
                    .reduce(0) { $0 + $1.triedKeys.count }
                // Persisted so the next run continues the frontier here.
                var persisted = Set(nodes[index].triedActionKeys ?? [])
                persisted.insert(key)
                nodes[index].triedActionKeys = persisted.sorted()
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
            var hasUntried: Set<String> = []
            for other in screens.values where other.actions.contains(where: { !other.triedKeys.contains($0.key) }) {
                hasUntried.insert(other.nodeId)
            }
            guard !hasUntried.isEmpty else { return nil }
            var adjacency: [String: [(to: String, action: ExploreTransitionAction)]] = [:]
            for edge in edges {
                adjacency[edge.from, default: []].append((edge.to, edge.action))
            }
            // BFS in node space; edges only ever descend (the depth rule), so
            // this terminates without cycle bookkeeping beyond `visited`.
            var queue: [(node: String, firstHop: ExploreTransitionAction?)] = [(state.nodeId, nil)]
            var visited: Set<String> = [state.nodeId]
            while !queue.isEmpty {
                let (node, firstHop) = queue.removeFirst()
                if hasUntried.contains(node), let firstHop {
                    return state.actions.first {
                        $0.targetId == firstHop.targetId && $0.targetLabel == firstHop.targetLabel && !$0.isScroll
                    }
                }
                for (to, action) in adjacency[node] ?? [] where !visited.contains(to) {
                    visited.insert(to)
                    queue.append((to, firstHop ?? action))
                }
            }
            return nil
        }

        func anyUntriedRemains() -> Bool {
            screens.values.contains { state in state.actions.contains { !state.triedKeys.contains($0.key) } }
        }

        func budgetsExhausted() -> Bool {
            // Budgets meter this run's own work: a resumed store full of
            // screens must not exhaust the screen budget on arrival.
            steps >= budgets.maxSteps || nodes.count - priorScreens >= budgets.maxScreens || Date() >= budgets.deadline
        }

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
                for _ in 0..<3 where launched == nil {
                    try await launch(app: app, profile: relaunches == 1 ? profile : (resumeProfile ?? profile))
                    let settled = try await settledSnapshot(stableReads: 8)
                    if let settled,
                       expectedApp == nil || ExploreEngine.applicationLabel(of: settled) == expectedApp {
                        launched = settled
                    }
                }
                guard let snapshot = launched else {
                    finish(error: "Экран не стабилизировался после запуска \(app).")
                    return
                }
                expectedApp = ExploreEngine.applicationLabel(of: snapshot) ?? expectedApp
                var current = await record(snapshot, depth: 0)
                publish("Стартовый экран: \(nodeTitle(nodes, screens, current))")

                while !Task.isCancelled, !budgetsExhausted() {
                    let fresh = untriedAction(on: current)
                    guard let action = fresh ?? descentAction(on: current) else { break }
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
                        publish("Шаг \(steps): \(isReplay ? "спуск — " : "")tap «\(described)»")
                        _ = try? await SimulatorInputClient.tap(deviceUDID: configuration.device.udid, x: action.x, y: action.y)
                    }
                    guard let after = try await settledSnapshot() else { continue }
                    if let expectedApp, ExploreEngine.applicationLabel(of: after) != expectedApp {
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
                                    nodes[index].actionsTotal += revealed.count
                                }
                            }
                        }
                        publish(nil)
                    }
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
            let reason: String
            if Task.isCancelled { reason = "Остановлено пользователем." }
            else if budgetsExhausted() { reason = "Бюджет исчерпан." }
            else { reason = "Все доступные действия испробованы." }
            publish(nil)
            finish(error: nil, note: "Готово: \(nodes.count) экранов, \(descentEdges().count) переходов, \(steps) шагов. \(reason)")
        } catch is CancellationError {
            publish(nil)
            finish(error: nil, note: "Остановлено пользователем.")
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
        running = false
        lastError = error
        if let note { message = note }
        if let error { message = error }
        graph?.run.finishedAt = Self.timestamp()
        let snapshot = graph
        let directory = runDirectory
        lock.unlock()
        if let snapshot, let directory, let data = try? JSON.data(snapshot, pretty: true) {
            try? data.write(to: directory.appendingPathComponent("graph.json"), options: [.atomic])
        }
    }

    // MARK: simulator I/O

    /// Relaunches through simctl with the profile's argv, arming the SimTool
    /// loggers the same way `simtool test run` does — the crawl must observe
    /// the same app configuration a recorded test would.
    private func launch(app: String, profile: LaunchProfile?) async throws {
        // Home first: a system overlay a stray tap opened (the app switcher)
        // stays above a freshly launched app and would poison the snapshot.
        _ = try? await SimulatorInputClient.button("home", deviceUDID: configuration.device.udid)
        var environment = profile?.environment ?? [:]
        if let serverURL = configuration.appFacingServerURL {
            environment["SIMTOOL_SERVER_URL"] = environment["SIMTOOL_SERVER_URL"] ?? serverURL
            environment["SIMTOOL_NETWORK_LOGGER"] = environment["SIMTOOL_NETWORK_LOGGER"] ?? "1"
            environment["SIMTOOL_STATE_LOGGER"] = environment["SIMTOOL_STATE_LOGGER"] ?? "1"
        }
        // `--terminate-running-process` races the suspend the home press above
        // just started: simctl kills the app mid-transition and then reports
        // ESRCH ("did not return a process handle nor launch error") instead
        // of a pid. Nothing is wrong with the app — the next attempt, with the
        // transition over, launches it — so a lost race costs a retry rather
        // than the whole crawl.
        var lastFailure = ""
        for attempt in 0..<3 {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(1500))
            }
            let output = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: SimulatorAppLifecycleClient.simctlLaunchArguments(
                    deviceUDID: configuration.device.udid,
                    bundleIdentifier: app,
                    launchArguments: (profile?.arguments ?? [])
                ),
                environment: SimulatorAppLifecycleClient.simctlChildEnvironment(launchEnvironment: environment),
                timeoutSeconds: 120
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
    private func settledSnapshot(stableReads: Int = 2) async throws -> [AccessibilityFlatNode]? {
        var snapshot = try await structurallySettledSnapshot(stableReads: stableReads)
        var patience = 10
        while let current = snapshot, ExploreEngine.isLoading(current), patience > 0, !Task.isCancelled {
            patience -= 1
            try await Task.sleep(for: .milliseconds(700))
            if let refreshed = try await structurallySettledSnapshot(stableReads: stableReads) {
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

    /// The accessibility snapshot once the screen stops changing:
    /// `stableReads` consecutive reads with the same structural fingerprint.
    /// Nil when the screen never settles within the window (endless
    /// animation) — the caller decides whether that is fatal.
    private func structurallySettledSnapshot(stableReads: Int = 2) async throws -> [AccessibilityFlatNode]? {
        try await Task.sleep(for: .milliseconds(600))
        var streak = 1
        var previous: (fingerprint: String, nodes: [AccessibilityFlatNode])?
        for _ in 0..<(10 + stableReads * 4) {
            if Task.isCancelled { return previous?.nodes }
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
