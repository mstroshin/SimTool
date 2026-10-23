import Foundation
import XCTest
@testable import SimToolCLI
@testable import SimToolCore

final class SimulatorHoldTests: XCTestCase {
    private func config(idleTimeout: TimeInterval?) -> ProjectConfig {
        ProjectConfig(simulator: "booted", bundleId: "com.example", build: ProjectConfig.Build(scheme: "App"), idleTimeout: idleTimeout)
    }

    // The flag wins, then the environment, then the project's config.
    func testTheIdleTimeoutComesFromTheFlagThenTheEnvironmentThenTheConfig() throws {
        let environment = ["SIMTOOL_IDLE_TIMEOUT": "5m"]
        XCTAssertEqual(try SimulatorHold.idleTimeout(flag: "30s", config: config(idleTimeout: 60), environment: environment), 30)
        XCTAssertEqual(try SimulatorHold.idleTimeout(flag: nil, config: config(idleTimeout: 60), environment: environment), 300)
        XCTAssertEqual(try SimulatorHold.idleTimeout(flag: nil, config: config(idleTimeout: 60), environment: [:]), 60)
        XCTAssertNil(try SimulatorHold.idleTimeout(flag: nil, config: nil, environment: [:]), "the default")
        XCTAssertEqual(try SimulatorHold.idleTimeout(flag: "off", config: nil, environment: [:]), 0)
    }

    // A typo in the environment is said, not silently replaced by the default.
    func testABadTimeoutFails() {
        XCTAssertThrowsError(try SimulatorHold.idleTimeout(flag: nil, config: nil, environment: ["SIMTOOL_IDLE_TIMEOUT": "soon"])) { error in
            XCTAssertTrue("\(error)".contains("SIMTOOL_IDLE_TIMEOUT=soon"), "\(error)")
        }
        XCTAssertThrowsError(try SimulatorHold.idleTimeout(flag: "1 hour", config: nil, environment: [:]))
    }

    func testTheBootNoteSaysWhenSimToolShutsItDownAgain() {
        let device = SimulatorDevice(udid: "AAAA", name: "SimTool-idle-a", runtime: "", state: "Shutdown", isAvailable: true)
        XCTAssertTrue(SimulatorHold.bootNote(device, idleTimeout: nil).contains("after 15 min unused"))
        XCTAssertFalse(SimulatorHold.bootNote(device, idleTimeout: 0).contains("unused"), "off: it stays up")
    }

    // A detached server runs under the timeout its caller was given.
    func testADetachedServerGetsTheIdleTimeout() throws {
        let args = detachedServerArguments(
            parameters: ServeParameters(device: nil, host: "127.0.0.1", port: 3200),
            sessionId: "abc",
            app: nil,
            verbose: false,
            reclaimPort: true,
            config: nil,
            idleTimeout: "2m"
        )
        XCTAssertEqual(Array(args.suffix(2)), ["--idle-timeout", "2m"])
        XCTAssertEqual(try Serve.parse(args.dropFirst().map { $0 }).idleTimeout, "2m", "the child parses it")
        XCTAssertFalse(detachedServerArguments(
            parameters: ServeParameters(device: nil, host: "127.0.0.1", port: 3200),
            sessionId: "abc", app: nil, verbose: false, reclaimPort: true, config: nil
        ).contains("--idle-timeout"))
    }

    func testTheKeptServerNoteSaysItStopsByItself() {
        let note = ServerAutostart.keptNote(url: "http://127.0.0.1:3203", sessionId: "E0D12083-7907", idleTimeout: 600)
        XCTAssertTrue(note.contains("Left unused for 10 min, it stops by itself"), note)
        XCTAssertFalse(ServerAutostart.keptNote(url: "u", sessionId: "s", idleTimeout: 0).contains("unused"))
    }

    // A dead server of an older SimTool names what it booted; only the boot it
    // knew is its to shut down, not one a person started after it died.
    func testOnlyABootFromBeforeTheSessionIsItsToShutDown() {
        let snapshot = SimulatorProcessSnapshot.parse("\(getpid()) launchd_sim /Devices/AAAA/data/var/run/launchd_bootstrap.plist")
        let session = SessionInfo(sessionId: "s", pid: 1, device: SimulatorDevice(udid: "AAAA", name: "", runtime: "", state: "Booted", isAvailable: true), url: "", api: "", startedAt: Date(), bootedDevices: ["AAAA"])
        XCTAssertTrue(isBootOf("AAAA", knownTo: [session], in: snapshot))
        var older = session
        older.startedAt = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(isBootOf("AAAA", knownTo: [older], in: snapshot), "booted again after that session")
        XCTAssertFalse(isBootOf("BBBB", knownTo: [session], in: snapshot), "not booted")
    }

    func testReapParses() throws {
        let reap = try Reap.parse(["--all", "--dry-run", "--json"])
        XCTAssertTrue(reap.all)
        XCTAssertTrue(reap.dryRun)
        XCTAssertFalse(try Reap.parse([]).watch)
        XCTAssertEqual(try Run.parse(["--idle-timeout", "off"]).idleTimeout, "off")
    }
}
