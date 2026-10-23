import ArgumentParser
import Foundation
import SimToolCore

struct Reap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Shut down the simulators SimTool holds that nothing has used for their idle timeout.",
        discussion: """
        SimTool holds a simulator it booted, and one a SimTool server runs on — \
        whoever booted it. Once nothing has used it for its idle timeout \
        (`idleTimeout:` in .simtool/config.yml, SIMTOOL_IDLE_TIMEOUT or \
        `serve --idle-timeout`; 15 minutes by default, `off` for never) it is \
        shut down: a server stops itself and shuts its simulator down, and a \
        reaper in the background (`simtool reap --watch`, started by SimTool \
        while it holds anything) shuts down the rest. This command runs that \
        pass now. A simulator SimTool never booted or served is never touched, \
        nor one an `xcodebuild` is running on.
        """
    )

    @Flag(help: "Shut down every simulator SimTool holds now, idle or not, stopping the SimTool servers on it.")
    var all = false

    @Flag(help: "Say what would be shut down, and change nothing.")
    var dryRun = false

    @Flag(help: .hidden)
    var watch = false

    @OptionGroup var common: CommonJSON

    struct Payload: Encodable {
        var simulators: [SimulatorLeaseSweep.Outcome]
        var dryRun: Bool
    }

    func run() async throws {
        if watch {
            await LeaseReaper.watch()
            return
        }
        let outcomes = await SimulatorLeaseSweep().run(scope: all ? .all : .idle, dryRun: dryRun)
        if common.json {
            try printJSON(Payload(simulators: outcomes, dryRun: dryRun))
        } else if outcomes.isEmpty {
            makeNoora().info("SimTool holds no simulator.")
        } else {
            makeNoora().table(
                headers: ["Simulator", dryRun ? "Would be" : "Now", "Unused", "Timeout", "Why"],
                rows: outcomes.map { outcome in
                    [
                        outcome.name,
                        Self.word(outcome.action),
                        SimulatorIdleTimeout.duration(outcome.idleSeconds),
                        SimulatorIdleTimeout.describe(outcome.idleTimeout),
                        outcome.reason ?? "",
                    ]
                }
            )
        }
    }

    static func word(_ action: SimulatorLeaseSweep.Outcome.Action) -> String {
        switch action {
        case .kept: return "held"
        case .released: return "let go"
        case .inUse: return "in use"
        case .stoppedServers: return "servers stopped, shut down"
        case .shutDown: return "shut down"
        }
    }
}
