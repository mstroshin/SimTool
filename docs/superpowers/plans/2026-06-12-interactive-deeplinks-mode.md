# Interactive Deeplinks Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bare `simtool` starts an interactive loop that lists deeplinks from `.simtool.yml` and opens the selected one on the configured simulator, repeatedly, until Exit.

**Architecture:** A small testable choice model (`InteractiveDeeplinkChoice`) lives in `SimToolCore`; a new `Interactive` subcommand in `SimToolCLI` drives a `Noora().singleChoicePrompt` loop and becomes the root command's `defaultSubcommand` (replacing `Devices`). Device resolution/boot happens once per session and is re-done after a failed open.

**Tech Stack:** Swift, swift-argument-parser, Noora (already a dependency), XCTest.

**Spec:** `docs/superpowers/specs/2026-06-12-interactive-deeplinks-mode-design.md`

**⚠️ Per user instruction: do NOT commit any of this work. Skip all commit steps.**

**Behavior change to be aware of:** bare `simtool` currently runs `devices` (see `defaultSubcommand: Devices.self` in `Sources/SimToolCLI/SimTool.swift:36`). After this plan it runs `interactive`, which errors fast in non-TTY contexts. `simtool devices` remains available explicitly.

---

### Task 1: Choice model in SimToolCore

**Files:**
- Create: `Sources/SimToolCore/InteractiveDeeplinks.swift`
- Test: `Tests/SimToolCoreTests/InteractiveDeeplinksTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SimToolCore

final class InteractiveDeeplinksTests: XCTestCase {
    private func makeConfig(deeplinks: [ProjectConfig.Deeplink]) -> ProjectConfig {
        ProjectConfig(
            simulator: "iPhone 16 Pro",
            bundleId: "com.example.MyApp",
            build: .init(workspace: "/tmp/App.xcworkspace", project: nil, scheme: "App", configuration: nil, derivedDataPath: nil),
            server: .init(),
            deeplinks: deeplinks,
            sourcePath: "/tmp/.simtool.yml"
        )
    }

    func testChoicesListDeeplinksInConfigOrderWithExitLast() {
        let details = ProjectConfig.Deeplink(name: "Details", url: "myapp://items/42")
        let settings = ProjectConfig.Deeplink(name: "Settings", url: "myapp://settings?section=general")
        let choices = InteractiveDeeplinkChoice.choices(for: makeConfig(deeplinks: [details, settings]))
        XCTAssertEqual(choices, [.deeplink(details), .deeplink(settings), .exit])
    }

    func testDeeplinkChoiceDescriptionMatchesDeeplink() {
        let link = ProjectConfig.Deeplink(name: "Details", url: "myapp://items/42")
        XCTAssertEqual(InteractiveDeeplinkChoice.deeplink(link).description, link.description)
    }

    func testExitChoiceDescription() {
        XCTAssertEqual(InteractiveDeeplinkChoice.exit.description, "Exit")
    }
}
```

Note: check the actual memberwise availability of `ProjectConfig.init` and `Build`/`Server` initializers in `Sources/SimToolCore/ProjectConfig.swift:85-101` before writing `makeConfig` — use the existing public initializer's parameter list and defaults (e.g. `server:` and `deeplinks:` have defaults; pass only what the initializer requires). Adjust `makeConfig` to compile against it rather than inventing labels.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter InteractiveDeeplinksTests`
Expected: compilation failure — `InteractiveDeeplinkChoice` not defined.

- [ ] **Step 3: Implement the choice model**

```swift
import Foundation

/// One row in the interactive deeplink prompt: a configured deeplink or the
/// trailing Exit entry. Kept in SimToolCore so the option-list shape is unit
/// testable without driving a terminal prompt.
public enum InteractiveDeeplinkChoice: Equatable, Sendable, CustomStringConvertible {
    case deeplink(ProjectConfig.Deeplink)
    case exit

    public var description: String {
        switch self {
        case .deeplink(let link): return link.description
        case .exit: return "Exit"
        }
    }

    /// Prompt options for a config: deeplinks in config order, Exit last.
    public static func choices(for config: ProjectConfig) -> [InteractiveDeeplinkChoice] {
        config.deeplinks.map { .deeplink($0) } + [.exit]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter InteractiveDeeplinksTests`
Expected: 3 tests PASS.

---

### Task 2: `Interactive` subcommand and default-subcommand switch

**Files:**
- Modify: `Sources/SimToolCLI/SimTool.swift` (root `CommandConfiguration` at lines 18-37; add the new command near `Open`, which is around line 964)

- [ ] **Step 1: Add the `Interactive` command**

Place it next to `struct Open` in `SimTool.swift`:

```swift
struct Interactive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "interactive",
        abstract: "Interactively open configured deeplinks in a loop. Runs when `simtool` is invoked without a subcommand."
    )

    @Option(help: "Path to the project config. Defaults to .simtool.yml discovered from the working directory upward.")
    var config: String?

    @OptionGroup var common: CommonJSON

    func run() async throws {
        guard !common.json, isatty(STDIN_FILENO) != 0 else {
            throw SimToolError("Interactive mode needs a terminal. Use `simtool open <name>` to open a deeplink non-interactively, or `simtool --help` for other commands.")
        }
        let projectConfig = try ProjectConfigLoader.load(explicitPath: config)
        guard !projectConfig.deeplinks.isEmpty else {
            throw SimToolError("No deeplinks configured in \(projectConfig.sourcePath). Add a `deeplinks:` list to use interactive mode.")
        }
        var device: SimulatorDevice?
        while true {
            let choice = Noora().singleChoicePrompt(
                title: "Deeplinks",
                question: "Which deeplink do you want to open?",
                options: InteractiveDeeplinkChoice.choices(for: projectConfig)
            )
            guard case .deeplink(let link) = choice else { return }
            do {
                let booted: SimulatorDevice
                if let cached = device {
                    booted = cached
                } else {
                    let resolved = try await SimulatorDeviceClient.resolve(projectConfig.simulator)
                    booted = try await SimulatorDeviceClient.ensureBooted(resolved)
                    device = booted
                }
                let payload = try await SimulatorDeeplinkClient.open(
                    name: link.name,
                    url: link.url,
                    device: booted
                )
                Noora().success(.alert("Opened deeplink", takeaways: [
                    "Name: \(payload.name)",
                    "URL: \(payload.url)",
                    "Device: \(booted.name)",
                ]))
            } catch {
                // Drop the cached device so the next attempt re-resolves and re-boots.
                device = nil
                Noora().error(.alert("Failed to open '\(link.name)': \(error.localizedDescription)"))
            }
        }
    }
}
```

If `Noora().error(.alert(...))` does not exist in the pinned Noora version (compile error), use `Noora().warning("Failed to open '\(link.name)': \(error.localizedDescription)")` instead — `warning` is already used at `SimTool.swift:103`.

`Noora().singleChoicePrompt` requires options to conform to `CustomStringConvertible & Equatable` — `InteractiveDeeplinkChoice` satisfies both. Mirror the exact call shape used by `Open.selectDeeplink` at `SimTool.swift:1007-1011`.

- [ ] **Step 2: Register the subcommand and make it the default**

In the root configuration (`SimTool.swift:18-37`): add `Interactive.self` to `subcommands` (after `Open.self`) and change `defaultSubcommand: Devices.self` to `defaultSubcommand: Interactive.self`.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: success, no warnings about the new code.

- [ ] **Step 4: Verify the non-TTY guard and help output**

Run: `swift run simtool < /dev/null; echo "exit=$?"`
Expected: error message "Interactive mode needs a terminal..." and non-zero exit.

Run: `swift run simtool --help`
Expected: help output listing `interactive` among subcommands; `(default)` marker on `interactive` if ArgumentParser renders one.

Run: `swift run simtool devices --json | head -c 200`
Expected: JSON device list (explicit subcommand unaffected).

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all tests PASS.

---

### Task 3: Documentation

**Files:**
- Modify: `README.md` (Basic Usage section)

- [ ] **Step 1: Document the interactive mode**

In the "Basic Usage" section of `README.md`, after the existing `serve` example block, add:

```markdown
Run `simtool` with no subcommand (or `simtool interactive`) in a terminal to
pick and open configured deeplinks in a loop. Requires a `deeplinks:` list in
`.simtool.yml`; select `Exit` or press Ctrl+C to leave. Non-interactive
callers should keep using explicit subcommands such as `simtool devices` —
bare `simtool` no longer defaults to `devices`.
```

- [ ] **Step 2: Verify formatting**

Run: `head -80 README.md`
Expected: the new paragraph renders in place, no broken fences.

---

### Task 4: Final verification (no commit)

- [ ] **Step 1: Full build and tests**

Run: `swift build && swift test`
Expected: build succeeds, all tests pass.

- [ ] **Step 2: Manual smoke test (requires a terminal + a project with `.simtool.yml`)**

This step needs a real TTY, so the engineer runs it by hand: in a directory with a `.simtool.yml` containing deeplinks, run `swift run simtool`, open a deeplink, confirm the prompt returns, then choose Exit. If no such project is at hand, note it as manually unverified in the final report.

- [ ] **Step 3: Do NOT commit**

Per user instruction, leave all changes uncommitted in the working tree.
