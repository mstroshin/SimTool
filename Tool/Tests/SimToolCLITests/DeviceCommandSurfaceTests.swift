import ArgumentParser
@testable import SimToolCLI
import XCTest

// The settings commands read a setting without a value and change it with one.
final class DeviceCommandSurfaceTests: XCTestCase {
    func testTheSettingsCommandsAreTopLevel() {
        let names = SimTool.configuration.subcommands.map { $0.configuration.commandName ?? "" }
        for name in ["ui", "debug", "biometrics", "push", "status-bar", "location", "settings"] {
            XCTAssertTrue(names.contains(name), "missing simtool \(name)")
        }
    }

    func testUIAndDebugTakeASettingAndAnOptionalValue() throws {
        let read = try UI.parse(["appearance"])
        XCTAssertEqual(read.setting, "appearance")
        XCTAssertNil(read.value)
        let change = try UI.parse(["text-size", "ax2", "--json"])
        XCTAssertEqual(change.value, "ax2")
        XCTAssertTrue(change.common.json)
        let debug = try Debug.parse(["color-blended", "on", "--device", "iPhone 17"])
        XCTAssertEqual(debug.option, "color-blended")
        XCTAssertEqual(debug.state, "on")
        XCTAssertNil(try Debug.parse([]).option)
    }

    func testAPushTakesExactlyOnePayload() throws {
        XCTAssertEqual(try Push.parse(["--alert", "Hi", "--app", "com.example.app"]).alert, "Hi")
        XCTAssertEqual(try Push.parse(["payload.json"]).file, "payload.json")
        XCTAssertThrowsError(try Push.parse([]))
        XCTAssertThrowsError(try Push.parse(["payload.json", "--alert", "Hi"]))
    }

    func testTheStatusBarTakesAPresetOrFields() throws {
        let fields = try StatusBar.parse(["--time", "9:41", "--battery-level", "20", "--battery-state", "discharging"])
        XCTAssertEqual(fields.fields.time, "9:41")
        XCTAssertEqual(fields.fields.batteryLevel, 20)
        XCTAssertTrue(try StatusBar.parse([]).fields.isEmpty)
        XCTAssertEqual(try StatusBar.parse(["clean"]).preset, "clean")
        XCTAssertThrowsError(try StatusBar.parse(["tidy"]))
        XCTAssertThrowsError(try StatusBar.parse(["clear", "--time", "9:41"]))
    }

    func testALocationTakesAnActionAndItsPoints() throws {
        let route = try Location.parse(["route", "1,2", "3,4", "--speed", "15"])
        XCTAssertEqual(route.action, "route")
        XCTAssertEqual(route.points, ["1,2", "3,4"])
        XCTAssertEqual(route.speed, 15)
        XCTAssertNil(try Location.parse([]).action)
    }
}
