import Foundation

/// A key of a hardware keyboard, by its USB HID usage on the keyboard page
/// (0x07) — what the simulator's keyboard takes. A key, not a character: the
/// simulated device's own layout decides what it types, as with a real
/// keyboard attached to an iPhone, and as in Simulator.app.
public struct KeyboardKey: Hashable, Sendable {
    public let usage: UInt32

    public init?(usage: UInt32) {
        guard (1...255).contains(usage) else { return nil }
        self.usage = usage
    }

    private init(_ usage: UInt32) {
        self.usage = usage
    }

    /// The physical key a browser names in `KeyboardEvent.code`, whatever
    /// layout the Mac types with.
    public init?(webCode: String) {
        guard let usage = Self.webCodes[webCode] else { return nil }
        self.init(usage)
    }

    public static let v = KeyboardKey(0x19)
    public static let leftCommand = KeyboardKey(0xE3)

    static let webCodes: [String: UInt32] = {
        var codes: [String: UInt32] = [:]
        for (offset, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            codes["Key\(letter)"] = 0x04 + UInt32(offset)
        }
        for digit in 1...9 {
            codes["Digit\(digit)"] = 0x1E + UInt32(digit - 1)
            codes["Numpad\(digit)"] = 0x59 + UInt32(digit - 1)
        }
        codes["Digit0"] = 0x27
        codes["Numpad0"] = 0x62
        for number in 1...12 {
            codes["F\(number)"] = 0x3A + UInt32(number - 1)
        }
        for number in 13...24 {
            codes["F\(number)"] = 0x68 + UInt32(number - 13)
        }
        let named: [String: UInt32] = [
            "Enter": 0x28, "Escape": 0x29, "Backspace": 0x2A, "Tab": 0x2B, "Space": 0x2C,
            "Minus": 0x2D, "Equal": 0x2E, "BracketLeft": 0x2F, "BracketRight": 0x30, "Backslash": 0x31,
            "Semicolon": 0x33, "Quote": 0x34, "Backquote": 0x35, "Comma": 0x36, "Period": 0x37,
            "Slash": 0x38, "CapsLock": 0x39,
            "PrintScreen": 0x46, "ScrollLock": 0x47, "Pause": 0x48, "Insert": 0x49, "Home": 0x4A,
            "PageUp": 0x4B, "Delete": 0x4C, "End": 0x4D, "PageDown": 0x4E,
            "ArrowRight": 0x4F, "ArrowLeft": 0x50, "ArrowDown": 0x51, "ArrowUp": 0x52,
            // A Mac keyboard's Clear key reports NumLock.
            "NumLock": 0x53, "NumpadDivide": 0x54, "NumpadMultiply": 0x55, "NumpadSubtract": 0x56,
            "NumpadAdd": 0x57, "NumpadEnter": 0x58, "NumpadDecimal": 0x63, "NumpadEqual": 0x67,
            "NumpadComma": 0x85,
            // The ISO key left of Z (§ or < on European Macs) and the JIS keys.
            "IntlBackslash": 0x64, "IntlRo": 0x87, "IntlYen": 0x89, "KanaMode": 0x88,
            "Convert": 0x8A, "NonConvert": 0x8B, "Lang1": 0x90, "Lang2": 0x91,
            "ContextMenu": 0x65, "Help": 0x75,
            "ControlLeft": 0xE0, "ShiftLeft": 0xE1, "AltLeft": 0xE2, "MetaLeft": 0xE3,
            "ControlRight": 0xE4, "ShiftRight": 0xE5, "AltRight": 0xE6, "MetaRight": 0xE7,
            // Older Firefox names the ⌘ keys OS.
            "OSLeft": 0xE3, "OSRight": 0xE7,
        ]
        codes.merge(named) { current, _ in current }
        return codes
    }()
}

/// One key going down or up as the viewer's keyboard sends it: streamed to
/// the helper and never answered, like the live finger.
public struct LiveKeyEvent: Equatable, Sendable {
    public var key: KeyboardKey
    public var isDown: Bool

    public init(key: KeyboardKey, isDown: Bool) {
        self.key = key
        self.isDown = isDown
    }

    var helperLine: String { "key \(key.usage) \(isDown ? 1 : 0)" }
}

extension SimulatorInputClient {
    /// Simulator.app's Toggle Software Keyboard (⌘K), which Device Hub sends
    /// as the Eject key of a hardware keyboard: iOS shows the software keyboard
    /// a hardware keyboard keeps hidden, or hides it again.
    public static func toggleSoftwareKeyboard(deviceUDID: String) async throws -> ProcessOutput {
        try await SimulatorDirectInputClient.shared.toggleSoftwareKeyboard(deviceUDID: deviceUDID)
        return ProcessOutput(status: 0)
    }

    /// Simulator.app's Connect Hardware Keyboard (⇧⌘K): connected, iOS treats
    /// typing as coming from a hardware keyboard and keeps the software one out
    /// of the way; disconnected, the software keyboard comes up for every field.
    public static func setHardwareKeyboard(connected: Bool, deviceUDID: String) async throws -> ProcessOutput {
        if connected {
            // Apps hide the software keyboard only while the keyboard daemon's
            // automatic minimization is on, and a new simulator leaves it unset
            // until it once sees a hardware keyboard attach.
            _ = try? await ProcessRunner.runXcrun([
                "simctl", "spawn", deviceUDID, "defaults", "write", "com.apple.keyboard.preferences",
                "AutomaticMinimizationEnabled", "-bool", "YES",
            ])
        }
        try await SimulatorDirectInputClient.shared.setHardwareKeyboard(connected: connected, deviceUDID: deviceUDID)
        return ProcessOutput(status: 0)
    }
}
