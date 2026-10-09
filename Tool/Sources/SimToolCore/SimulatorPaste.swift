import Foundation
import UniformTypeIdentifiers

/// Writes text or an image onto a simulator's general pasteboard.
public enum SimulatorPasteboardClient {
    public static func copy(_ text: String, deviceUDID: String) async throws {
        // Through a file rather than stdin: ProcessRunner fills the stdin pipe
        // (~64 KB) before the child starts reading, so a pasted log would hang.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("simtool-paste-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let devicectl = try await devicectlCopy(file, type: nil, deviceUDID: deviceUDID)
        if devicectl.status == 0 { return }
        guard predatesCoreDevicePasteboard(devicectl) else {
            throw SimToolError("Cannot write the simulator pasteboard: \(failureDetail(devicectl, fallback: "devicectl pasteboard copy failed"))")
        }
        let simctl = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"exec /usr/bin/xcrun simctl pbcopy "$1" < "$2""#, "sh", deviceUDID, file.path],
            timeoutSeconds: 30
        )
        guard simctl.status == 0 else {
            throw SimToolError("Cannot write the simulator pasteboard: \(failureDetail(simctl, fallback: "simctl pbcopy failed"))")
        }
    }

    /// Puts an image file on the pasteboard as the given UTI (`public.png`, …).
    public static func copyImage(at file: URL, type: String, deviceUDID: String) async throws {
        let devicectl = try await devicectlCopy(file, type: type, deviceUDID: deviceUDID)
        if devicectl.status == 0 { return }
        if predatesCoreDevicePasteboard(devicectl) {
            throw SimToolError("Pasting images needs Xcode 27 or newer: older Xcode's `simctl pbcopy` carries only text.")
        }
        throw SimToolError("Cannot write the simulator pasteboard: \(failureDetail(devicectl, fallback: "devicectl pasteboard copy failed"))")
    }

    // Since Xcode 27 the simulator pasteboard belongs to CoreDevice. `simctl
    // pbcopy` still exits 0 there, but CoreSimulatorBridge drops the write
    // ("the CoreDevice pasteboard stack is in use"), so devicectl goes first.
    private static func devicectlCopy(_ file: URL, type: String?, deviceUDID: String) async throws -> ProcessOutput {
        var arguments = ["devicectl", "device", "pasteboard", "copy", "--device", deviceUDID, "--file", file.path, "--quiet"]
        if let type { arguments += ["--type", type] }
        return try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: arguments,
            timeoutSeconds: 30
        )
    }

    /// 64: this devicectl has no `pasteboard` subcommand; 72: xcrun finds no
    /// devicectl at all. Either way the Xcode predates the CoreDevice
    /// pasteboard, and `simctl pbcopy` is the one that works.
    private static func predatesCoreDevicePasteboard(_ output: ProcessOutput) -> Bool {
        output.status == 64 || output.status == 72
    }

    private static func failureDetail(_ output: ProcessOutput, fallback: String) -> String {
        let detail = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? fallback : detail
    }
}

extension SimulatorInputClient {
    /// Pastes text into the focused field: the text goes onto the simulator
    /// pasteboard and ⌘V is pressed on the simulator keyboard. Unlike
    /// `typeText`, which AXe limits to US-keyboard characters, any Unicode text
    /// arrives intact. Throws when nothing visibly changed and no keyboard is
    /// up, because ⌘V without a focused field does nothing and says nothing.
    public static func paste(_ text: String, deviceUDID: String) async throws -> ProcessOutput {
        guard !text.isEmpty else { throw SimToolError("Paste requires non-empty text") }
        let outcome = try await pressPaste(deviceUDID: deviceUDID) {
            try await SimulatorPasteboardClient.copy(text, deviceUDID: deviceUDID)
        }
        switch outcome {
        case .changed:
            return message("Pasted \(text.count) characters.")
        case .unverifiable:
            return message("Sent ⌘V; the accessibility tree was unavailable to confirm the paste.")
        case let .unchanged(keyboardVisible: true, allowed):
            // A focused field whose text accessibility does not expose (web
            // content, custom text views): the paste most likely landed.
            return message("Sent ⌘V to the focused field; its text is not visible to accessibility, so the paste is unconfirmed.\(allowHint(allowed))")
        case let .unchanged(keyboardVisible: false, allowed):
            throw SimToolError("Nothing was pasted: no text field changed after ⌘V and no keyboard is up. Tap a text field in the simulator, then paste again.\(allowHint(allowed))")
        }
    }

    /// Pastes an image file the same way. Only fields that take images react —
    /// a text view with attributed editing, notes or chat composers; a plain
    /// text field ignores it. To offer the image in a photo picker instead,
    /// add it with `SimulatorPhotosClient`.
    public static func pasteImage(at file: URL, deviceUDID: String) async throws -> ProcessOutput {
        guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image) else {
            throw SimToolError("\(file.lastPathComponent) is not an image file (PNG, JPEG, HEIC, GIF, …)")
        }
        guard FileManager.default.isReadableFile(atPath: file.path) else {
            throw SimToolError("Cannot read \(file.path)")
        }
        let outcome = try await pressPaste(deviceUDID: deviceUDID) {
            try await SimulatorPasteboardClient.copyImage(at: file, type: type.identifier, deviceUDID: deviceUDID)
        }
        switch outcome {
        case .changed:
            return message("Pasted the image.")
        case .unverifiable:
            return message("Sent ⌘V with the image; the accessibility tree was unavailable to confirm the paste.")
        case let .unchanged(keyboardVisible: true, allowed):
            return message("Sent ⌘V with the image, but the focused field did not change: plain text fields ignore images.\(allowHint(allowed))")
        case let .unchanged(keyboardVisible: false, allowed):
            throw SimToolError("Nothing was pasted: no text field changed after ⌘V and no keyboard is up. Tap a field that takes images, then paste again.\(allowHint(allowed))")
        }
    }

    enum PasteOutcome: Equatable {
        /// A text input's value changed — an image lands in a text view as U+FFFC.
        case changed
        case unchanged(keyboardVisible: Bool, allowed: Bool)
        /// No accessibility tree before ⌘V to compare against.
        case unverifiable
    }

    /// Writes the pasteboard, presses ⌘V and watches the text inputs for the effect.
    private static func pressPaste(
        deviceUDID: String,
        write: @Sendable () async throws -> Void
    ) async throws -> PasteOutcome {
        async let written: Void = write()
        async let processes = launchctlList(deviceUDID: deviceUDID)
        let before = await accessibilityTree(deviceUDID: deviceUDID)
        try await written

        // iOS asks "Allow Paste?" when an app reads what another process put on
        // the pasteboard, ⌘V from the simulator keyboard included. Granting the
        // foreground app "Paste from Other Apps" (Settings › Apps) skips that.
        var allowed = false
        if let pid = before.flatMap({ PasteVerification.foregroundPID(in: $0) }),
           let list = await processes,
           let app = PasteVerification.bundleID(forPID: pid, launchctlList: list) {
            let grant = try? await ProcessRunner.runXcrun(["simctl", "privacy", deviceUDID, "grant", "pasteboard", app])
            allowed = grant?.status == 0
        }

        try await SimulatorDirectInputClient.shared.press(.v, modifiers: [.leftCommand], deviceUDID: deviceUDID)

        guard let before else { return .unverifiable }
        let baseline = PasteVerification.textInputs(in: before)
        var after: AccessibilityTreePayload?
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            try? await Task.sleep(for: .milliseconds(250))
            after = await accessibilityTree(deviceUDID: deviceUDID)
            if let after, PasteVerification.textInputs(in: after) != baseline { return .changed }
        } while Date() < deadline
        return .unchanged(keyboardVisible: after.map { PasteVerification.isKeyboardVisible(in: $0) } ?? false, allowed: allowed)
    }

    private static func message(_ text: String) -> ProcessOutput {
        ProcessOutput(status: 0, stdout: Data(text.utf8))
    }

    private static func allowHint(_ allowed: Bool) -> String {
        allowed ? "" : " If iOS asks to allow pasting, choose Allow Paste."
    }

    private static func accessibilityTree(deviceUDID: String) async -> AccessibilityTreePayload? {
        try? await SimulatorAccessibilityClient.normalizedTree(deviceUDID: deviceUDID)
    }

    private static func launchctlList(deviceUDID: String) async -> String? {
        guard let output = try? await ProcessRunner.runXcrun(["simctl", "spawn", deviceUDID, "launchctl", "list"]),
              output.status == 0 else { return nil }
        return output.stdoutString
    }
}

/// Reads a paste's effect off accessibility trees taken before and after ⌘V.
enum PasteVerification {
    /// AXe reports UIKit text fields — secure and search fields included, told
    /// apart only by subrole — as `TextField`, and text views as `TextArea`.
    static let textInputTypes: Set<String> = ["TextField", "TextArea", "SearchField", "SecureTextField", "ComboBox"]

    /// Identifiers UIKit gives the software keyboard's own views; app elements
    /// do not plausibly reuse them, unlike key ids such as `delete` or `space`.
    static let keyboardIdentifiers: Set<String> = ["UIKeyboardLayoutStar Preview", "SystemInputAssistantView"]

    /// Every text input's identity and current value, in tree order. A paste
    /// that landed changes at least one value — or the screen, when the app
    /// reacts by navigating away.
    static func textInputs(in tree: AccessibilityTreePayload) -> [String] {
        var inputs: [String] = []
        func visit(_ node: AccessibilityNode) {
            if let type = node.type, textInputTypes.contains(type) {
                inputs.append([type, node.accessibilityIdentifier ?? "", node.value ?? ""].joined(separator: "\u{1F}"))
            }
            node.children.forEach(visit)
        }
        tree.roots.forEach(visit)
        return inputs
    }

    static func isKeyboardVisible(in tree: AccessibilityTreePayload) -> Bool {
        func visit(_ node: AccessibilityNode) -> Bool {
            if let id = node.accessibilityIdentifier, keyboardIdentifiers.contains(id) { return true }
            return node.children.contains(where: visit)
        }
        return tree.roots.contains(where: visit)
    }

    /// The process owning the frontmost UI: AXe roots its tree at that app.
    static func foregroundPID(in tree: AccessibilityTreePayload) -> Int? {
        tree.roots.first(where: { $0.type == "Application" })?.pid ?? tree.roots.first?.pid
    }

    /// Maps a pid to its bundle id through the simulator's `launchctl list`,
    /// where every running app is a `UIKitApplication:<bundle id>[…]` job.
    static func bundleID(forPID pid: Int, launchctlList: String) -> String? {
        let prefix = "UIKitApplication:"
        for line in launchctlList.split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3, Int(columns[0]) == pid else { continue }
            let label = columns[2]
            guard label.hasPrefix(prefix) else { return nil }
            let bundleID = label.dropFirst(prefix.count).prefix { $0 != "[" }
            return bundleID.isEmpty ? nil : String(bundleID)
        }
        return nil
    }
}
