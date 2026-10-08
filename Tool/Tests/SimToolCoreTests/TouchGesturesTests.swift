@testable import SimToolCore
import XCTest

final class TouchGesturesTests: XCTestCase {
    private let screen = SimulatorScreenSize(width: 400, height: 800, scale: 2)

    // MARK: - helper commands

    func testLiveEventsEncodeOneAndTwoFingerCommands() {
        XCTAssertEqual(LiveTouchEvent(phase: .down, first: TouchRatio(x: 0.5, y: 0.25)).helperLine, "down 0.50000 0.25000")
        XCTAssertEqual(LiveTouchEvent(phase: .move, first: TouchRatio(x: 0.1, y: 0.2)).helperLine, "move 0.10000 0.20000")
        XCTAssertEqual(LiveTouchEvent(phase: .up, first: TouchRatio(x: 1, y: 0)).helperLine, "up 1.00000 0.00000")
        XCTAssertEqual(
            LiveTouchEvent(phase: .move, first: TouchRatio(x: 0.3, y: 0.4), second: TouchRatio(x: 0.7, y: 0.6)).helperLine,
            "move2 0.30000 0.40000 0.70000 0.60000"
        )
        XCTAssertEqual(
            LiveTouchEvent(phase: .up, first: TouchRatio(x: 0.3, y: 0.4), second: TouchRatio(x: 0.7, y: 0.6)).helperLine,
            "up2 0.30000 0.40000 0.70000 0.60000"
        )
    }

    func testRatiosAreClampedToTheScreen() {
        let ratio = TouchRatio(x: -0.2, y: 1.7)
        XCTAssertEqual(ratio.x, 0)
        XCTAssertEqual(ratio.y, 1)
        XCTAssertEqual(SimulatorDirectInputCommand.tap(x: 1.4, y: 0.5).line, "tap 1.00000 0.50000")
    }

    func testPathEncodesPhaseMillisecondsAndRatios() {
        let path = TouchPath(samples: [
            .init(phase: .down, time: 0, point: TouchRatio(x: 0.5, y: 0.75)),
            .init(phase: .move, time: 0.017, point: TouchRatio(x: 0.5, y: 0.7)),
            .init(phase: .up, time: 0.0345, point: TouchRatio(x: 0.5, y: 0.7)),
        ])
        XCTAssertEqual(path.helperLine, "path d,0,0.50000,0.75000 m,17,0.50000,0.70000 u,35,0.50000,0.70000")
        XCTAssertEqual(path.duration, 0.0345, accuracy: 1e-9)
    }

    func testScreenSizeAnswerParses() {
        XCTAssertEqual(
            SimulatorDirectInputCommand.screenSize(fromAnswer: "ok 402.000 874.000 3.000"),
            SimulatorScreenSize(width: 402, height: 874, scale: 3)
        )
        XCTAssertNil(SimulatorDirectInputCommand.screenSize(fromAnswer: "ok"))
        XCTAssertNil(SimulatorDirectInputCommand.screenSize(fromAnswer: "err"))
        XCTAssertNil(SimulatorDirectInputCommand.screenSize(fromAnswer: "ok 0 874 3"))
    }

    // MARK: - stroke compilation

    func testTapAndLongPressAreADownAndAnUpApart() {
        let tap = TouchStroke.tap(at: TouchPoint(x: 100, y: 200)).path(on: screen)
        XCTAssertEqual(tap.samples.map(\.phase), [.down, .up])
        XCTAssertEqual(tap.samples.last?.time ?? 0, TouchStroke.tapPress, accuracy: 1e-9)
        XCTAssertEqual(tap.samples.first?.point, TouchRatio(x: 0.25, y: 0.25))

        let press = TouchStroke.longPress(at: TouchPoint(x: 100, y: 200), duration: 1.2).path(on: screen)
        XCTAssertEqual(press.samples.map(\.phase), [.down, .up])
        XCTAssertEqual(press.duration, 1.2, accuracy: 1e-9)
    }

    func testMovesNeverComeFasterThanTheBuilderTakes() {
        let strokes = [
            TouchStroke.fling(from: TouchPoint(x: 200, y: 600), to: TouchPoint(x: 200, y: 400), velocity: FlingSpeed.fast),
            TouchStroke.scroll(from: TouchPoint(x: 200, y: 600), to: TouchPoint(x: 200, y: 100)),
            TouchStroke.drag(from: TouchPoint(x: 100, y: 100), to: TouchPoint(x: 300, y: 500)),
        ]
        for stroke in strokes {
            let times = stroke.path(on: screen).samples.filter { $0.phase != .up }.map(\.time)
            for (previous, next) in zip(times, times.dropFirst()) {
                XCTAssertGreaterThanOrEqual(next - previous, TouchStroke.sampleInterval - 1e-9, "\(stroke)")
            }
        }
    }

    func testFlingLiftsInMotionAtItsSpeed() {
        let from = TouchPoint(x: 200, y: 600), to = TouchPoint(x: 200, y: 400)
        let path = TouchStroke.fling(from: from, to: to, velocity: 1000).path(on: screen)
        let moves = path.samples.filter { $0.phase == .move }
        XCTAssertEqual(path.samples.last?.phase, .up)
        // No rest: the up shares the last move's moment and position.
        XCTAssertEqual(path.samples.last?.time, moves.last?.time)
        XCTAssertEqual(moves.last?.point, screen.ratio(to))
        XCTAssertEqual(path.duration, 0.2, accuracy: 0.001)
        // Evenly spread: the speed at lift-off is the stroke's speed.
        let intervals = zip(moves, moves.dropFirst()).map { $1.time - $0.time }
        XCTAssertEqual(intervals.max() ?? 0, intervals.min() ?? 0, accuracy: 1e-9)
    }

    func testScrollSlowsDownAndRestsWithAOnePixelTremorBeforeLifting() {
        let from = TouchPoint(x: 200, y: 600), to = TouchPoint(x: 200, y: 300)
        let stroke = TouchStroke.scroll(from: from, to: to)
        let path = stroke.path(on: screen)
        let moves = path.samples.filter { $0.phase == .move }

        // The finger reaches `to` and the last steps before it are shorter: it slows down.
        let arrival = moves.firstIndex { $0.point == screen.ratio(to) }!
        let steps = zip(moves[..<arrival], moves[1...arrival]).map { abs($1.point.y - $0.point.y) }
        XCTAssertLessThan(steps.last!, steps.first! / 2)

        // Then it rests: alternating one device pixel across the movement, never along it.
        let rest = moves[(arrival + 1)...]
        XCTAssertGreaterThanOrEqual(rest.count, Int(TouchStroke.scrollHold / TouchStroke.sampleInterval) - 1)
        let pixel = 1 / screen.scale / screen.width
        for sample in rest {
            XCTAssertEqual(sample.point.y, screen.ratio(to).y, accuracy: 1e-12)
            XCTAssertTrue(abs(sample.point.x - screen.ratio(to).x) < 1e-12 || abs(sample.point.x - screen.ratio(to).x - pixel) < 1e-12)
        }
        XCTAssertTrue(rest.contains { $0.point != screen.ratio(to) })
        XCTAssertEqual(path.samples.last?.point, screen.ratio(to))
        XCTAssertEqual(path.duration - (moves[arrival].time), TouchStroke.scrollHold, accuracy: 1e-9)
    }

    func testDragPressesBeforeMoving() {
        let path = TouchStroke.drag(from: TouchPoint(x: 100, y: 100), to: TouchPoint(x: 100, y: 400)).path(on: screen)
        let firstMove = path.samples.first { $0.phase == .move }!
        XCTAssertGreaterThanOrEqual(firstMove.time, TouchStroke.dragPress)
        // 300 pt at 300 pt/s, plus the ease-out's extra half, plus press and hold.
        XCTAssertEqual(
            path.duration,
            TouchStroke.dragPress + 1 + TouchStroke.easeOut / 2 + TouchStroke.dragHold,
            accuracy: 0.001
        )
    }

    // MARK: - direction gestures

    func testDirectionGesturesStartAQuarterInsideAndTravelHalfTheScreen() {
        let up = TouchGeometry.scroll(.up, on: screen)
        XCTAssertEqual(up.from, TouchPoint(x: 200, y: 600))
        XCTAssertEqual(up.to, TouchPoint(x: 200, y: 200))
        XCTAssertEqual(up.hold, TouchStroke.scrollHold)

        let right = TouchGeometry.scroll(.right, on: screen)
        XCTAssertEqual(right.from, TouchPoint(x: 100, y: 400))
        XCTAssertEqual(right.to, TouchPoint(x: 300, y: 400))
    }

    func testAScrollByDistanceAddsThePanSlop() {
        let stroke = TouchGeometry.scroll(.down, distance: 100, from: TouchPoint(x: 150, y: 300), on: screen)
        XCTAssertEqual(stroke.from, TouchPoint(x: 150, y: 300))
        XCTAssertEqual(stroke.to, TouchPoint(x: 150, y: 300 + 100 + TouchStroke.panSlop))
    }

    func testGesturesStayClearOfTheEdges() {
        let stroke = TouchGeometry.scroll(.up, distance: 2000, from: TouchPoint(x: 5, y: 795), on: screen)
        XCTAssertEqual(stroke.from, TouchPoint(x: TouchGeometry.edgeMargin, y: 800 - TouchGeometry.edgeMargin))
        XCTAssertEqual(stroke.to.y, TouchGeometry.edgeMargin)
    }

    func testFlingTravelsTwoHundredPointsAtItsSpeed() {
        let stroke = TouchGeometry.fling(.left, velocity: FlingSpeed.slow, on: screen)
        XCTAssertEqual(stroke.from, TouchPoint(x: 300, y: 400))
        XCTAssertEqual(stroke.to, TouchPoint(x: 100, y: 400))
        XCTAssertEqual(stroke.velocity, 750)
        XCTAssertEqual(stroke.hold, 0)
    }

    func testFlingSpeedNames() {
        XCTAssertEqual(FlingSpeed.parse("slow"), 750)
        XCTAssertEqual(FlingSpeed.parse("Normal"), 1000)
        XCTAssertEqual(FlingSpeed.parse("fast"), 1250)
        XCTAssertEqual(FlingSpeed.parse("1800"), 1800)
        XCTAssertNil(FlingSpeed.parse("-5"))
        XCTAssertNil(FlingSpeed.parse("warp"))
    }

    func testShortMovesStillGetOneStep() {
        let path = TouchStroke.fling(from: TouchPoint(x: 100, y: 100), to: TouchPoint(x: 100, y: 102)).path(on: screen)
        XCTAssertEqual(path.samples.map(\.phase), [.down, .move, .up])
        XCTAssertEqual(path.samples[1].time, TouchStroke.sampleInterval, accuracy: 1e-9)
    }
}
