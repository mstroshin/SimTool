import Darwin
import Foundation
import Noora

/// Single owner of process signal handling. Noora's default Terminal would
/// trap SIGINT/SIGTERM/SIGQUIT/SIGHUP and call exit(0), so interrupted runs
/// read as success to CI and shells. Instead, every Noora instance is built
/// with `signalBehavior: .none` and this trap exits with the shell convention
/// 128 + signal number, restoring the cursor the spinner may have hidden.
/// Server sessions register a cleanup step that runs before exiting.
final class SignalTrap: @unchecked Sendable {
    static let shared = SignalTrap()
    private var cleanup: (@Sendable () -> Void)?

    func installOnce() {
        _ = Self.installed
    }

    func installCleanup(_ cleanup: @escaping @Sendable () -> Void) {
        self.cleanup = cleanup
        installOnce()
    }

    private static let installed: Void = {
        // Force lazy globals now: initializing them inside a signal handler
        // would allocate, which is not async-signal-safe.
        _ = cursorShowSequence.count
        _ = SignalTrap.shared
        for signalNumber in [SIGINT, SIGTERM, SIGQUIT, SIGHUP] {
            signal(signalNumber) { signalNumber in
                SignalTrap.shared.cleanup?()
                if isatty(STDOUT_FILENO) == 1 {
                    cursorShowSequence.withUnsafeBufferPointer { buffer in
                        _ = write(STDOUT_FILENO, buffer.baseAddress, buffer.count)
                    }
                }
                _exit(128 + signalNumber)
            }
        }
    }()
}

private let cursorShowSequence: [UInt8] = Array("\u{1B}[?25h".utf8)

/// All Noora instances in this CLI must come from here so none of them
/// installs Noora's own exit(0) signal handlers.
func makeNoora(isInteractive: Bool? = nil) -> Noora {
    SignalTrap.shared.installOnce()
    if let isInteractive {
        return Noora(terminal: Terminal(isInteractive: isInteractive, signalBehavior: .none))
    }
    return Noora(terminal: Terminal(signalBehavior: .none))
}
