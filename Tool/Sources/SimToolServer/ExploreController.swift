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
    /// Relative to the run directory, e.g. `shots/s-ab12cd34.png`.
    public var screenshot: String
    /// Shortest observed distance from the screen the app launches into.
    public var depth: Int
    public var visits: Int
    public var actionsTotal: Int
    public var actionsTried: Int
    public var firstSeenAt: String
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

public struct ExploreStatusPayload: Codable, Sendable {
    public var running: Bool
    public var runId: String?
    public var app: String?
    public var message: String?
    public var error: String?
    public var graph: ExploreGraph?
}

// MARK: - Engine (pure, unit-testable)

/// The decisions the crawler makes about a single accessibility snapshot:
/// what identifies the screen, what can be tapped on it, and what to call it.
/// Free of I/O so tests can feed it recorded trees.
public enum ExploreEngine {
    /// One tappable candidate on a screen. `x`/`y` are the frame center in
    /// points — the coordinate space AXe taps in.
    public struct Action: Equatable, Sendable {
        public var key: String
        public var targetId: String?
        public var targetLabel: String?
        public var x: Double
        public var y: Double
        public var isBack: Bool
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
        "logout", "log out", "sign out", "delete", "remove", "call",
        "выйти", "выход", "удал", "заблок", "позвон",
    ]

    static let tappableTypes: Set<String> = ["Button", "Cell", "Link"]

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

        var candidates: [Action] = []
        for node in nodes {
            guard let type = node.type, tappableTypes.contains(type) else { continue }
            guard node.enabled != false else { continue }
            guard let frame = node.frame, frame.count == 4, frame[2] >= 10, frame[3] >= 10 else { continue }
            let centerX = Double(frame[0]) + Double(frame[2]) / 2
            let centerY = Double(frame[1]) + Double(frame[3]) / 2
            if let bounds, bounds.count == 4 {
                let inX = centerX >= Double(bounds[0]) && centerX <= Double(bounds[0] + bounds[2])
                let inY = centerY >= Double(bounds[1]) && centerY <= Double(bounds[1] + bounds[3])
                guard inX, inY else { continue }
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
            candidates.append(Action(
                key: id ?? "\(label ?? "")@\(type)",
                targetId: id,
                targetLabel: label,
                x: centerX,
                y: centerY,
                isBack: looksLikeNavbarBack || isBack(id: id, label: label)
            ))
        }

        var grouped: [String: [Action]] = [:]
        var order: [String] = []
        for action in candidates {
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
        return limited
    }

    /// Identifier prefixes that name a convention, not a screen: reverse-DNS
    /// heads, SF Symbols, generic UIKit vocabulary.
    static let titleStopwords: Set<String> = [
        "com", "org", "net", "app", "apple", "chevron", "xmark", "arrow", "icon",
        "cell", "button", "label", "image", "title", "text", "list", "table",
        "nav", "navbar", "tab", "tabbar", "static", "view", "screen",
    ]

    /// A display name for a screen, best effort: the dominant identifier prefix
    /// (`MainScreen-TransferButton` → `MainScreen`), else a navigation-bar-ish
    /// title, else the caller's fallback.
    public static func title(for nodes: [AccessibilityFlatNode], fallback: String) -> String {
        var prefixCounts: [String: Int] = [:]
        for node in nodes {
            guard let id = node.id, !id.hasPrefix("_") else { continue }
            let prefix = id.split(whereSeparator: { $0 == "-" || $0 == "." }).first.map(String.init) ?? id
            guard prefix.count >= 4,
                  prefix.rangeOfCharacter(from: .letters) != nil,
                  !titleStopwords.contains(prefix.lowercased()) else { continue }
            prefixCounts[prefix, default: 0] += 1
        }
        if let best = prefixCounts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value >= 3 {
            return best.key
        }
        if let titled = nodes.first(where: { !($0.title ?? "").isEmpty }), let title = titled.title {
            return title
        }
        // Navigation-bar text: below the status bar (whose clock and battery
        // read as labels too), short, and containing at least one letter.
        let navbarText = nodes.first { node in
            guard node.type == "StaticText", let frame = node.frame, frame.count == 4 else { return false }
            guard let label = node.label, (2...40).contains(label.count),
                  label.rangeOfCharacter(from: .letters) != nil else { return false }
            return frame[1] >= 30 && frame[1] < 160
        }
        if let label = navbarText?.label { return label }
        return fallback
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
        public var appFacingServerURL: String?
        /// Runs live in `<root>/<runId>/` as `graph.json` + `shots/*.png`.
        public var root: URL

        public init(
            device: SimulatorDevice,
            defaultApp: String?,
            profiles: [LaunchProfile],
            appFacingServerURL: String?,
            root: URL
        ) {
            self.device = device
            self.defaultApp = defaultApp
            self.profiles = profiles
            self.appFacingServerURL = appFacingServerURL
            self.root = root
        }
    }

    private struct Budgets {
        var maxScreens: Int
        var maxSteps: Int
        var deadline: Date
        var maxRelaunches = 8
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
    private var loadedPreviousRun = false

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: HTTP surface

    public func status() -> ExploreStatusPayload {
        lock.lock()
        defer { lock.unlock() }
        loadPreviousRunLocked()
        return ExploreStatusPayload(
            running: running,
            runId: runId,
            app: graph?.run.app ?? configuration.defaultApp,
            message: message,
            error: lastError,
            graph: graph
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
        let directory = configuration.root.appendingPathComponent(id, isDirectory: true)
        let budgets = Budgets(
            maxScreens: max(1, request.maxScreens ?? 20),
            maxSteps: max(1, request.maxSteps ?? 80),
            deadline: Date().addingTimeInterval(TimeInterval(max(1, request.budgetMinutes ?? 10) * 60))
        )
        running = true
        runId = id
        runDirectory = directory
        lastError = nil
        message = "Запускаю \(app)…"
        graph = ExploreGraph(
            schemaVersion: 1,
            run: ExploreRunMeta(
                id: id,
                app: app,
                device: configuration.device.name,
                profile: profile?.name,
                startedAt: Self.timestamp(),
                finishedAt: nil
            ),
            stats: ExploreStats(screens: 0, transitions: 0, steps: 0, relaunches: 0),
            nodes: [],
            edges: []
        )
        task = Task { [weak self] in
            await self?.crawl(app: app, profile: profile, directory: directory, budgets: budgets)
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
        loadPreviousRunLocked()
        let directory = runDirectory
        lock.unlock()
        guard let directory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent("shots/\(node).png"))
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

    /// Shows the newest finished run when the server (re)starts, so the map
    /// survives a restart instead of greeting the tab with an empty canvas.
    private func loadPreviousRunLocked() {
        guard graph == nil, !running, !loadedPreviousRun else { return }
        loadedPreviousRun = true
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: configuration.root,
            includingPropertiesForKeys: nil
        )) ?? []
        for directory in directories.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let file = directory.appendingPathComponent("graph.json")
            guard let data = try? Data(contentsOf: file),
                  let loaded = try? JSON.decoder.decode(ExploreGraph.self, from: data) else { continue }
            graph = loaded
            runId = loaded.run.id
            runDirectory = directory
            message = "Показан прошлый прогон \(loaded.run.id)"
            return
        }
    }

    // MARK: crawl loop

    private func crawl(app: String, profile: LaunchProfile?, directory: URL, budgets: Budgets) async {
        let shotsDirectory = directory.appendingPathComponent("shots", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: shotsDirectory, withIntermediateDirectories: true)
        } catch {
            finish(error: "Не удалось создать каталог прогона: \(error.localizedDescription)")
            return
        }

        var screens: [String: ScreenState] = [:]
        var nodes: [ExploreScreenNode] = []
        var nodeIndex: [String: Int] = [:]
        var edges: [ExploreTransitionEdge] = []
        var edgeIndex: [String: Int] = [:]
        /// The screen each screen was first reached from. A tap that lands
        /// back on it is a return, whatever the button was called.
        var arrivedFrom: [String: String] = [:]
        var steps = 0
        var relaunches = 0

        func publish(_ text: String?) {
            lock.lock()
            if let text { message = text }
            graph?.nodes = nodes
            graph?.edges = edges
            graph?.stats = ExploreStats(screens: nodes.count, transitions: edges.count, steps: steps, relaunches: relaunches)
            let snapshot = graph
            lock.unlock()
            guard let snapshot, let data = try? JSON.data(snapshot, pretty: true) else { return }
            try? data.write(to: directory.appendingPathComponent("graph.json"), options: [.atomic])
        }

        /// Records the screen a snapshot shows, screenshotting it on first
        /// sight, and returns its fingerprint.
        func record(_ snapshot: [AccessibilityFlatNode], depth: Int) async -> String {
            let fingerprint = ExploreEngine.fingerprint(of: snapshot)
            if var known = screens[fingerprint] {
                known.depth = min(known.depth, depth)
                screens[fingerprint] = known
                if let index = nodeIndex[fingerprint] {
                    nodes[index].visits += 1
                    nodes[index].depth = known.depth
                    nodes[index].actionsTried = known.triedKeys.count
                }
                return fingerprint
            }
            let nodeId = "s-\(fingerprint.prefix(10))"
            let actions = ExploreEngine.actions(from: snapshot)
            screens[fingerprint] = ScreenState(nodeId: nodeId, depth: depth, actions: actions)
            let shot = "shots/\(nodeId).png"
            if let png = try? await SimulatorScreenshotClient.png(deviceUDID: configuration.device.udid, maxDimension: 700) {
                try? png.write(to: directory.appendingPathComponent(shot), options: [.atomic])
            }
            nodes.append(ExploreScreenNode(
                id: nodeId,
                title: ExploreEngine.title(for: snapshot, fallback: "Экран \(fingerprint.prefix(6))"),
                fingerprint: fingerprint,
                screenshot: shot,
                depth: depth,
                visits: 1,
                actionsTotal: actions.count,
                actionsTried: 0,
                firstSeenAt: Self.timestamp()
            ))
            nodeIndex[fingerprint] = nodes.count - 1
            return fingerprint
        }

        func recordEdge(from: String, to: String, action: ExploreTransitionAction) {
            guard from != to, let fromId = screens[from]?.nodeId, let toId = screens[to]?.nodeId else { return }
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
            if let index = nodeIndex[fingerprint], let state = screens[fingerprint] {
                nodes[index].actionsTried = state.triedKeys.count
            }
        }

        func untriedAction(on fingerprint: String) -> ExploreEngine.Action? {
            guard let state = screens[fingerprint] else { return nil }
            // Non-back actions first: back closes the screen we are mining.
            return state.actions.first { !$0.isBack && !state.triedKeys.contains($0.key) }
                ?? state.actions.first { $0.isBack && !state.triedKeys.contains($0.key) }
        }

        func anyUntriedRemains() -> Bool {
            screens.values.contains { state in state.actions.contains { !state.triedKeys.contains($0.key) } }
        }

        func budgetsExhausted() -> Bool {
            steps >= budgets.maxSteps || nodes.count >= budgets.maxScreens || Date() >= budgets.deadline
        }

        do {
            passes: while !Task.isCancelled, !budgetsExhausted(), relaunches < budgets.maxRelaunches {
                if relaunches > 0, !anyUntriedRemains() { break }
                try await launch(app: app, profile: profile)
                relaunches += 1
                publish("Запуск \(relaunches): жду стабилизации экрана…")
                guard let snapshot = try await settledSnapshot() else {
                    finish(error: "Экран не стабилизировался после запуска \(app).")
                    return
                }
                var current = await record(snapshot, depth: 0)
                publish("Стартовый экран: \(nodeTitle(nodes, screens, current))")

                while !Task.isCancelled, !budgetsExhausted() {
                    guard let action = untriedAction(on: current) else { break }
                    markTried(current, key: action.key)
                    steps += 1
                    let described = action.targetLabel ?? action.targetId ?? "(\(Int(action.x)), \(Int(action.y)))"
                    publish("Шаг \(steps): tap «\(described)»")
                    _ = try? await SimulatorInputClient.tap(deviceUDID: configuration.device.udid, x: action.x, y: action.y)
                    guard let after = try await settledSnapshot() else { continue }
                    let next = await record(after, depth: (screens[current]?.depth ?? 0) + 1)
                    if next != current {
                        // The map only draws forward transitions. A retreat is
                        // either a back-looking tap or any tap that lands on
                        // the screen this one was reached from — iOS back
                        // buttons are titled after that screen, so vocabulary
                        // alone would miss them.
                        let isReturn = action.isBack || arrivedFrom[current] == next
                        if !isReturn {
                            recordEdge(from: current, to: next, action: ExploreTransitionAction(
                                kind: "tap",
                                targetId: action.targetId,
                                targetLabel: action.targetLabel
                            ))
                            if arrivedFrom[next] == nil { arrivedFrom[next] = current }
                        }
                        current = next
                        publish("Открыт экран: \(nodeTitle(nodes, screens, current)) (\(nodes.count) всего)")
                    } else {
                        publish(nil)
                    }
                }
                if !anyUntriedRemains() { break passes }
            }
            let reason: String
            if Task.isCancelled { reason = "Остановлено пользователем." }
            else if budgetsExhausted() { reason = "Бюджет исчерпан." }
            else { reason = "Все доступные действия испробованы." }
            publish(nil)
            finish(error: nil, note: "Готово: \(nodes.count) экранов, \(edges.count) переходов, \(steps) шагов. \(reason)")
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
        var environment = profile?.environment ?? [:]
        if let serverURL = configuration.appFacingServerURL {
            environment["SIMTOOL_SERVER_URL"] = environment["SIMTOOL_SERVER_URL"] ?? serverURL
            environment["SIMTOOL_NETWORK_LOGGER"] = environment["SIMTOOL_NETWORK_LOGGER"] ?? "1"
            environment["SIMTOOL_STATE_LOGGER"] = environment["SIMTOOL_STATE_LOGGER"] ?? "1"
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
        guard output.status == 0 else {
            throw SimToolError("simctl launch \(app) failed: \(output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// The accessibility snapshot once the screen stops changing: two
    /// consecutive reads with the same structural fingerprint. Nil when the
    /// screen never settles within the window (endless animation) — the caller
    /// decides whether that is fatal.
    private func settledSnapshot() async throws -> [AccessibilityFlatNode]? {
        try await Task.sleep(for: .milliseconds(600))
        var previous: (fingerprint: String, nodes: [AccessibilityFlatNode])?
        for _ in 0..<14 {
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
            if let previous, previous.fingerprint == fingerprint { return nodes }
            previous = (fingerprint, nodes)
            try await Task.sleep(for: .milliseconds(600))
        }
        return previous?.nodes
    }
}
