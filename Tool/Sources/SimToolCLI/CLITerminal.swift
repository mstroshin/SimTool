import Darwin
import Dispatch
import Foundation
import Noora

/// Single owner of process signal handling. Noora's default Terminal would
/// trap SIGINT/SIGTERM/SIGQUIT/SIGHUP and call exit(0), so interrupted runs
/// read as success to CI and shells. Instead, every Noora instance is built
/// with `signalBehavior: .none` and this trap exits with the shell convention
/// 128 + signal number, restoring the cursor the spinner may have hidden.
///
/// Server sessions register an *async* cleanup step (shut down simulators we
/// booted, stop the server, drop the session) that must run before exiting.
/// Spawning `simctl shutdown` and awaiting it is not async-signal-safe, so the
/// C handler does the bare minimum — record the signal and poke a self-pipe —
/// while a dispatch source on a normal thread runs the real cleanup with a hard
/// time cap. A second signal during cleanup forces an immediate exit.
final class SignalTrap: @unchecked Sendable {
    static let shared = SignalTrap()

    /// Max time the graceful cleanup may take before we exit anyway, so a hung
    /// simctl or server can never wedge the process open.
    private static let cleanupDeadline: DispatchTimeInterval = .seconds(8)

    private let lock = NSLock()
    private var cleanup: (@Sendable () async -> Void)?
    private let queue = DispatchQueue(label: "tech.simtool.signal-trap")
    private var source: DispatchSourceRead?

    func installOnce() {
        _ = Self.installed
    }

    func installCleanup(_ cleanup: @escaping @Sendable () async -> Void) {
        lock.lock()
        self.cleanup = cleanup
        lock.unlock()
        installOnce()
    }

    /// Runs on the dispatch queue (a normal thread), not in the signal handler,
    /// so awaiting async work and blocking on a semaphore are both safe here.
    fileprivate func runCleanupAndExit(_ signalNumber: Int32) {
        lock.lock()
        let cleanup = self.cleanup
        lock.unlock()
        if let cleanup {
            let done = DispatchSemaphore(value: 0)
            Task {
                await cleanup()
                done.signal()
            }
            _ = done.wait(timeout: .now() + Self.cleanupDeadline)
        }
        Self.restoreCursor()
        _exit(128 + signalNumber)
    }

    private static func restoreCursor() {
        guard isatty(STDOUT_FILENO) == 1 else { return }
        cursorShowSequence.withUnsafeBufferPointer { buffer in
            _ = write(STDOUT_FILENO, buffer.baseAddress, buffer.count)
        }
    }

    private static let installed: Void = {
        // Force lazy globals now: touching them inside a signal handler would
        // allocate, which is not async-signal-safe.
        _ = cursorShowSequence.count
        _ = SignalTrap.shared

        // Self-pipe: the C handler writes the signal number here; the dispatch
        // source below reads it on a normal thread and runs the real cleanup.
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return }
        signalPipeRead = fds[0]
        signalPipeWrite = fds[1]
        for fd in fds {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC) // never leak the pipe into children
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: signalPipeRead, queue: SignalTrap.shared.queue)
        source.setEventHandler {
            var byte: UInt8 = 0
            guard read(signalPipeRead, &byte, 1) == 1 else { return }
            SignalTrap.shared.runCleanupAndExit(Int32(byte))
        }
        source.resume()
        SignalTrap.shared.source = source

        for signalNumber in [SIGINT, SIGTERM, SIGQUIT, SIGHUP] {
            signal(signalNumber) { signalNumber in
                // Async-signal-safe only. A second signal (e.g. impatient Ctrl-C
                // while cleanup runs) bails out immediately.
                if signalAlreadyHandled != 0 {
                    _exit(128 + signalNumber)
                }
                signalAlreadyHandled = 1
                var byte = UInt8(truncatingIfNeeded: signalNumber)
                _ = write(signalPipeWrite, &byte, 1)
            }
        }
    }()
}

// Touched from the C signal handler, so these are plain globals with
// async-signal-safe access patterns (a single atomic write, a single pipe write).
private nonisolated(unsafe) var signalPipeRead: Int32 = -1
private nonisolated(unsafe) var signalPipeWrite: Int32 = -1
private nonisolated(unsafe) var signalAlreadyHandled: sig_atomic_t = 0

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
