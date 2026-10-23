import XCTest
@testable import SimToolCore

final class SimulatorLeaseTests: XCTestCase {
    private var root: URL!
    private var store: SimulatorLeaseStore!
    private let start = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lease-tests-\(UUID().uuidString)", isDirectory: true)
        store = SimulatorLeaseStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func device(_ udid: String = "AAAA-1111", name: String = "SimTool-idle-test", state: String = "Booted") -> SimulatorDevice {
        SimulatorDevice(udid: udid, name: name, runtime: "iOS-27-0", state: state, isAvailable: true)
    }

    private func lease(lastUsed: TimeInterval = 0, timeout: TimeInterval? = nil, bootPID: Int32? = 500) -> SimulatorLease {
        SimulatorLease(udid: "AAAA-1111", name: "SimTool-idle-test", bootedBySimTool: true, bootPID: bootPID, takenAt: start, lastUsedAt: start.addingTimeInterval(lastUsed), idleTimeout: timeout)
    }

    // MARK: - Store

    // Every SimTool process sees the same leases: they are files.
    func testALeaseTakenByOneStoreIsReadByAnother() {
        store.take(device(), booted: true, bootPID: 500, idleTimeout: 60, now: start)
        let other = SimulatorLeaseStore(root: root)
        let read = other.lease(udid: "AAAA-1111")
        XCTAssertEqual(read?.bootedBySimTool, true)
        XCTAssertEqual(read?.bootPID, 500)
        XCTAssertEqual(read?.idleTimeout, 60)
        XCTAssertEqual(other.list().map(\.udid), ["AAAA-1111"])
    }

    // A server adopting what SimTool booted keeps it SimTool-booted, keeps the
    // timeout it was taken with, and renews it.
    func testTakingAHeldSimulatorAgainRenewsIt() {
        store.take(device(), booted: true, bootPID: 500, idleTimeout: 60, now: start)
        let renewed = store.take(device(), booted: false, bootPID: 500, idleTimeout: nil, now: start.addingTimeInterval(30))
        XCTAssertTrue(renewed.bootedBySimTool)
        XCTAssertEqual(renewed.idleTimeout, 60)
        XCTAssertEqual(renewed.takenAt, start)
        XCTAssertEqual(renewed.lastUsedAt, start.addingTimeInterval(30))
    }

    // A lease covers one boot: one left from a boot that ended is not carried
    // over to the next.
    func testALeaseFromAnEndedBootIsReplaced() {
        store.take(device(), booted: true, bootPID: 500, now: start)
        let next = store.take(device(), booted: false, bootPID: 900, now: start.addingTimeInterval(10))
        XCTAssertFalse(next.bootedBySimTool)
        XCTAssertEqual(next.bootPID, 900)
        XCTAssertEqual(next.takenAt, start.addingTimeInterval(10))
    }

    // Using a simulator does not make it SimTool's.
    func testTouchRenewsOnlyAHeldSimulator() {
        XCTAssertNil(store.touch(udid: "AAAA-1111", at: start))
        XCTAssertNil(store.lease(udid: "AAAA-1111"))
        store.take(device(), booted: true, bootPID: 500, now: start)
        store.touch(udid: "AAAA-1111", at: start.addingTimeInterval(100))
        store.touch(udid: "AAAA-1111", at: start.addingTimeInterval(50))
        XCTAssertEqual(store.lease(udid: "AAAA-1111")?.lastUsedAt, start.addingTimeInterval(100), "an older use never winds it back")
    }

    // MARK: - Idle timeout

    func testIdleTimeoutsParse() throws {
        XCTAssertEqual(try SimulatorIdleTimeout.parse("900"), 900)
        XCTAssertEqual(try SimulatorIdleTimeout.parse("15m"), 900)
        XCTAssertEqual(try SimulatorIdleTimeout.parse("1.5h"), 5_400)
        XCTAssertEqual(try SimulatorIdleTimeout.parse("45s"), 45)
        XCTAssertEqual(try SimulatorIdleTimeout.parse("off"), 0)
        XCTAssertEqual(try SimulatorIdleTimeout.parse("false"), 0, "an unquoted `off` read as YAML 1.1")
        XCTAssertEqual(try SimulatorIdleTimeout.parse("0"), 0)
        XCTAssertThrowsError(try SimulatorIdleTimeout.parse("soon"))
        XCTAssertThrowsError(try SimulatorIdleTimeout.parse("-5m"))
        XCTAssertThrowsError(try SimulatorIdleTimeout.parse("30d"))
    }

    func testTheEnvironmentNamesATimeoutOnlyWhenValid() {
        XCTAssertEqual(SimulatorIdleTimeout.fromEnvironment(["SIMTOOL_IDLE_TIMEOUT": "2m"]), 120)
        XCTAssertNil(SimulatorIdleTimeout.fromEnvironment(["SIMTOOL_IDLE_TIMEOUT": "soon"]))
        XCTAssertNil(SimulatorIdleTimeout.fromEnvironment([:]))
    }

    func testTimeoutsAndDurationsRead() {
        XCTAssertEqual(SimulatorIdleTimeout.describe(900), "15 min")
        XCTAssertEqual(SimulatorIdleTimeout.describe(0), "off")
        XCTAssertEqual(SimulatorIdleTimeout.describe(90), "90 s")
        XCTAssertEqual(SimulatorIdleTimeout.duration(0), "0 s")
        XCTAssertEqual(SimulatorIdleTimeout.duration(9_000), "2.5 h")
    }

    func testALeaseIsIdleOnlyAfterItsWholeTimeout() {
        let held = lease(timeout: 60)
        XCTAssertFalse(held.isIdle(at: start.addingTimeInterval(59)))
        XCTAssertTrue(held.isIdle(at: start.addingTimeInterval(60)))
        XCTAssertFalse(lease(timeout: 0).isIdle(at: start.addingTimeInterval(86_400)), "off is never")
        XCTAssertEqual(lease().effectiveIdleTimeout, SimulatorIdleTimeout.defaultSeconds)
    }

    // MARK: - Process snapshot

    private let ps = """
      1 /sbin/launchd
    501 launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/AAAA-1111/data/var/run/launchd_bootstrap.plist
    502 launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/BBBB-2222/data/var/run/launchd_bootstrap.plist
    610 /Users/me/Library/Developer/CoreSimulator/Devices/AAAA-1111/data/Containers/Bundle/Application/X/App.app/App
    700 /Applications/Xcode 27.app/Contents/Developer/usr/bin/xcodebuild test -workspace A.xcworkspace -destination platform=iOS Simulator,id=bbbb-2222
    701 /usr/bin/xcodebuild test -destination platform=iOS Simulator,name=SimTool-idle-test 2 -quiet
    702 /usr/bin/xcrun simctl spawn AAAA-1111 notifyutil -g key
    703 xcodebuild -destination platform=iOS Simulator,name=iPhone 16 Pro test
    """

    func testTheBootIsTheSimulatorsLaunchdSim() {
        let snapshot = SimulatorProcessSnapshot.parse(ps)
        XCTAssertEqual(snapshot.bootPID(of: "AAAA-1111"), 501)
        XCTAssertEqual(snapshot.bootPID(of: "bbbb-2222"), 502)
        XCTAssertNil(snapshot.bootPID(of: "CCCC-3333"))
    }

    // A test run on the simulator is use SimTool cannot see in its own
    // traffic; anything else naming it — its own processes, a simctl — is not.
    func testAnXcodebuildOnTheSimulatorIsUseOutsideSimTool() {
        let snapshot = SimulatorProcessSnapshot.parse(ps)
        XCTAssertNotNil(snapshot.externalUse(of: device("BBBB-2222", name: "Other")), "by UDID, from an Xcode path with a space")
        XCTAssertNil(snapshot.externalUse(of: device("AAAA-1111", name: "SimTool-idle-test")), "name=SimTool-idle-test 2 is another simulator")
        XCTAssertNotNil(snapshot.externalUse(of: device("CCCC-3333", name: "SimTool-idle-test 2")), "by name, up to the next option")
        XCTAssertNotNil(snapshot.externalUse(of: device("DDDD-4444", name: "iPhone 16 Pro")), "by name, up to the action")
        XCTAssertNil(snapshot.externalUse(of: device("EEEE-5555", name: "iPhone 16")), "iPhone 16 Pro is another simulator")
    }

    // MARK: - Policy

    private func verdict(
        _ lease: SimulatorLease,
        state: String? = "Booted",
        bootPID: Int32? = 500,
        servers: [Int32] = [],
        use: String? = nil,
        after: TimeInterval,
        scope: SimulatorLeasePolicy.Scope = .idle
    ) -> SimulatorLeasePolicy.Verdict {
        SimulatorLeasePolicy.verdict(
            for: lease,
            device: state.map { device(state: $0) },
            currentBootPID: bootPID,
            liveServers: servers,
            externalUse: use,
            now: start.addingTimeInterval(after),
            scope: scope
        )
    }

    func testAnIdleSimulatorNobodyServesIsShutDown() {
        XCTAssertEqual(verdict(lease(timeout: 60), after: 30), .keep)
        guard case .shutDown = verdict(lease(timeout: 60), after: 61) else { return XCTFail("idle for its timeout") }
        XCTAssertEqual(verdict(lease(timeout: 0), after: 86_400), .keep, "a timeout of off keeps it up")
    }

    // A server stops itself when its simulator goes idle; the reaper steps in
    // only for one that has not, a while later.
    func testAServerOnAnIdleSimulatorIsGivenTimeToStopItself() {
        XCTAssertEqual(verdict(lease(timeout: 60), servers: [42], after: 90), .keep)
        guard case let .stopServers(pids, _) = verdict(lease(timeout: 60), servers: [42], after: 60 + SimulatorLeasePolicy.serverGrace) else {
            return XCTFail("a server that outstays its simulator's lease is stopped")
        }
        XCTAssertEqual(pids, [42])
    }

    func testASimulatorThatIsNotSimToolsAnyMoreIsLetGo() {
        guard case .release = verdict(lease(), state: nil, after: 0) else { return XCTFail("gone") }
        guard case .release = verdict(lease(), state: "Shutdown", after: 10_000) else { return XCTFail("shut down elsewhere") }
        guard case .release = verdict(lease(bootPID: 500), bootPID: 900, after: 10_000) else {
            return XCTFail("booted again by someone else: theirs now")
        }
        XCTAssertEqual(verdict(lease(), state: "Booting", after: 10_000), .keep)
    }

    func testUseOutsideSimToolKeepsItUp() {
        guard case .inUse = verdict(lease(timeout: 60), use: "xcodebuild", after: 10_000) else { return XCTFail("a test run is going") }
        guard case .inUse = verdict(lease(timeout: 60), use: "xcodebuild", after: 10_000, scope: .all) else {
            return XCTFail("not even by request")
        }
    }

    func testScopesBeyondIdle() {
        guard case .shutDown = verdict(lease(timeout: 600), after: SimulatorLeasePolicy.recentUse, scope: .unserved) else {
            return XCTFail("the reaper stopping")
        }
        XCTAssertEqual(verdict(lease(timeout: 600), after: 30, scope: .unserved), .keep, "a command is using it right now")
        XCTAssertEqual(verdict(lease(timeout: 600), servers: [42], after: 1_000, scope: .unserved), .keep, "a served one goes with its server")
        guard case .stopServers = verdict(lease(timeout: 600), servers: [42], after: 1, scope: .all) else { return XCTFail("--all") }
    }

    // MARK: - Sweep

    private final class Effects: @unchecked Sendable {
        var shutDown: [String] = []
        var shutDownWorks = true
        var stopped: [Int32] = []
        var devices: [SimulatorDevice]? = []
        var sessions: [SessionInfo] = []
        var ps = ""
        /// Runs while the pass lists simulators: after it read the leases.
        var duringListing: () -> Void = {}
    }

    private func sweep(_ effects: Effects, at offset: TimeInterval) -> SimulatorLeaseSweep {
        let now = start.addingTimeInterval(offset)
        return SimulatorLeaseSweep(
            store: store,
            listDevices: {
                effects.duringListing()
                guard let devices = effects.devices else { throw SimToolError("simctl failed") }
                return devices
            },
            liveSessions: { effects.sessions },
            processes: { SimulatorProcessSnapshot.parse(effects.ps) },
            stopServer: { effects.stopped.append($0.pid) },
            shutDown: { udid in
                effects.shutDown.append(udid)
                return effects.shutDownWorks
            },
            now: { now }
        )
    }

    private func session(pid: Int32, udid: String = "AAAA-1111") -> SessionInfo {
        SessionInfo(sessionId: "s\(pid)", pid: pid, device: device(udid), url: "", api: "", startedAt: start)
    }

    func testASweepShutsDownWhatIsIdleAndKeepsTheRest() async {
        let effects = Effects()
        effects.devices = [device("AAAA-1111"), device("BBBB-2222")]
        effects.ps = ps.split(separator: "\n").filter { $0.contains("launchd_sim") }.joined(separator: "\n")
        store.take(device("AAAA-1111"), booted: true, bootPID: 501, idleTimeout: 60, now: start)
        store.take(device("BBBB-2222"), booted: false, bootPID: 502, idleTimeout: 600, now: start)

        let dry = await sweep(effects, at: 120).run(dryRun: true)
        XCTAssertEqual(dry.map(\.action), [.shutDown, .kept])
        XCTAssertEqual(effects.shutDown, [], "a dry run changes nothing")
        XCTAssertEqual(store.list().count, 2)

        let outcomes = await sweep(effects, at: 120).run()
        XCTAssertEqual(outcomes.map(\.udid), ["AAAA-1111", "BBBB-2222"])
        XCTAssertEqual(outcomes.map(\.action), [.shutDown, .kept])
        XCTAssertEqual(effects.shutDown, ["AAAA-1111"])
        XCTAssertEqual(store.list().map(\.udid), ["BBBB-2222"])
    }

    // simctl failing says nothing about any simulator.
    func testASweepThatCannotListSimulatorsKeepsEveryLease() async {
        let effects = Effects()
        effects.devices = nil
        store.take(device(), booted: true, bootPID: 501, idleTimeout: 60, now: start)
        let outcomes = await sweep(effects, at: 10_000).run()
        XCTAssertEqual(outcomes.map(\.action), [.kept])
        XCTAssertEqual(effects.shutDown, [])
        XCTAssertNotNil(store.lease(udid: "AAAA-1111"))
    }

    func testASweepStopsAServerThatOutstaysItsSimulator() async {
        let effects = Effects()
        effects.devices = [device()]
        effects.sessions = [session(pid: 42), session(pid: 43, udid: "BBBB-2222")]
        effects.ps = ps
        store.take(device(), booted: true, bootPID: 501, idleTimeout: 60, now: start)
        let outcomes = await sweep(effects, at: 60 + SimulatorLeasePolicy.serverGrace).run()
        XCTAssertEqual(outcomes.map(\.action), [.stoppedServers])
        XCTAssertEqual(effects.stopped, [42], "only the server on that simulator")
        XCTAssertEqual(effects.shutDown, ["AAAA-1111"])
        XCTAssertNil(store.lease(udid: "AAAA-1111"))
    }

    func testAnXcodebuildRenewsTheLeaseInsteadOfLosingItsSimulator() async {
        let effects = Effects()
        effects.devices = [device("BBBB-2222", name: "Other")]
        effects.ps = ps
        store.take(device("BBBB-2222", name: "Other"), booted: true, bootPID: 502, idleTimeout: 60, now: start)
        let outcomes = await sweep(effects, at: 10_000).run()
        XCTAssertEqual(outcomes.map(\.action), [.inUse])
        XCTAssertEqual(effects.shutDown, [])
        XCTAssertEqual(store.lease(udid: "BBBB-2222")?.lastUsedAt, start.addingTimeInterval(10_000))
    }

    // The pass decides on what it read seconds before it acts.
    func testASimulatorUsedWhileThePassDecidedIsKept() async {
        let effects = Effects()
        effects.devices = [device()]
        store.take(device(), booted: true, bootPID: 501, idleTimeout: 60, now: start)
        effects.duringListing = { self.store.touch(udid: "AAAA-1111", at: self.start.addingTimeInterval(100)) }
        let outcomes = await sweep(effects, at: 120).run()
        XCTAssertEqual(outcomes.map(\.action), [.kept])
        XCTAssertEqual(effects.shutDown, [])
        XCTAssertNotNil(store.lease(udid: "AAAA-1111"))
    }

    // simctl failing to shut it down must not leave it running unwatched.
    func testAFailedShutdownKeepsTheLease() async {
        let effects = Effects()
        effects.devices = [device()]
        effects.shutDownWorks = false
        store.take(device(), booted: true, bootPID: 501, idleTimeout: 60, now: start)
        let outcomes = await sweep(effects, at: 120).run()
        XCTAssertEqual(outcomes.map(\.action), [.kept])
        XCTAssertEqual(effects.shutDown, ["AAAA-1111"], "it tried")
        XCTAssertNotNil(store.lease(udid: "AAAA-1111"), "the next pass tries again")
    }

    // MARK: - A server letting go

    func testAServerStoppingShutsItsSimulatorDown() async {
        let effects = Effects()
        effects.ps = ps
        effects.sessions = [session(pid: 42)]
        store.take(device(), booted: false, bootPID: 501, now: start)
        let outcome = await sweep(effects, at: 5).release(udid: "AAAA-1111", leaving: 42)
        XCTAssertEqual(outcome?.action, .shutDown, "whoever booted it: the server held it")
        XCTAssertEqual(effects.shutDown, ["AAAA-1111"])
        XCTAssertNil(store.lease(udid: "AAAA-1111"))
    }

    func testAServerStoppingLeavesASimulatorStillInUse() async {
        let effects = Effects()
        effects.ps = ps
        effects.sessions = [session(pid: 42), session(pid: 43)]
        store.take(device(), booted: true, bootPID: 501, now: start)
        let shared = await sweep(effects, at: 5).release(udid: "AAAA-1111", leaving: 42)
        XCTAssertEqual(shared?.action, .kept, "another server is on it")

        effects.sessions = []
        store.take(device("BBBB-2222", name: "Other"), booted: true, bootPID: 502, now: start)
        let testing = await sweep(effects, at: 5).release(udid: "BBBB-2222", leaving: 42)
        XCTAssertEqual(testing?.action, .inUse, "an xcodebuild runs on it")
        XCTAssertEqual(effects.shutDown, [])
        XCTAssertNotNil(store.lease(udid: "BBBB-2222"), "left for the reaper once the run is over")
    }

    // A server stopping for want of use keeps a simulator used as it stopped.
    func testAServerStoppingForIdlenessKeepsASimulatorUsedMeanwhile() async {
        let effects = Effects()
        store.take(device(), booted: true, bootPID: 501, now: start)
        store.touch(udid: "AAAA-1111", at: start.addingTimeInterval(50))
        let outcome = await sweep(effects, at: 60).release(udid: "AAAA-1111", leaving: 42, unusedSince: start)
        XCTAssertEqual(outcome?.action, .kept)
        XCTAssertEqual(effects.shutDown, [])
    }

    func testAServerStoppingOnASimulatorSimToolDoesNotHoldTouchesNothing() async {
        let effects = Effects()
        let outcome = await sweep(effects, at: 5).release(udid: "AAAA-1111", leaving: 42)
        XCTAssertNil(outcome)
        XCTAssertEqual(effects.shutDown, [])
    }
}
