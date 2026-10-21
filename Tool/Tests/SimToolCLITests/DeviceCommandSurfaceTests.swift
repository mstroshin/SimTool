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

    func testPermissionsKeychainAppAndRotate() throws {
        let names = SimTool.configuration.subcommands.map { $0.configuration.commandName ?? "" }
        XCTAssertTrue(names.contains("permissions"))
        XCTAssertTrue(names.contains("keychain"))
        let grant = try Permissions.parse(["grant", "camera", "--app", "com.example.app"])
        XCTAssertEqual(grant.decision, "grant")
        XCTAssertEqual(grant.permission, "camera")
        XCTAssertNil(try Permissions.parse([]).decision)
        XCTAssertEqual(try Keychain.parse(["add-root-cert", "ca.pem"]).file, "ca.pem")
        XCTAssertThrowsError(try Keychain.parse(["add-root-cert"]))
        XCTAssertThrowsError(try Keychain.parse(["reset", "ca.pem"]))
        XCTAssertThrowsError(try Keychain.parse(["wipe"]))
        let appNames = AppCommand.configuration.subcommands.map { $0.configuration.commandName ?? "" }
        XCTAssertTrue(appNames.contains("info"))
        XCTAssertTrue(appNames.contains("install"))
        XCTAssertEqual(try AppCommand.Info.parse(["--reveal", "data"]).reveal, "data")
        XCTAssertEqual(try AppCommand.Install.parse(["Build/My.app"]).path, "Build/My.app")
        let inputNames = Input.configuration.subcommands.map { $0.configuration.commandName ?? "" }
        XCTAssertTrue(inputNames.contains("rotate"))
        XCTAssertEqual(try Input.Rotate.parse(["left"]).orientation, "left")
        XCTAssertNil(try Input.Rotate.parse([]).orientation)
    }

    func testTheCameraTakesAFileTheWebcamOffOrNothing() throws {
        let names = SimTool.configuration.subcommands.map { $0.configuration.commandName ?? "" }
        XCTAssertTrue(names.contains("camera"))
        XCTAssertNil(try Camera.parse([]).source)
        XCTAssertEqual(try Camera.parse(["fixtures/code.png"]).source, "fixtures/code.png")
        let webcam = try Camera.parse(["webcam", "--camera", "iPhone"])
        XCTAssertEqual(webcam.source, "webcam")
        XCTAssertEqual(webcam.camera, "iPhone")
        XCTAssertThrowsError(try Camera.parse(["code.png", "--camera", "iPhone"]), "--camera goes with webcam")
    }

    func testALocationTakesAnActionAndItsPoints() throws {
        let route = try Location.parse(["route", "1,2", "3,4", "--speed", "15"])
        XCTAssertEqual(route.action, "route")
        XCTAssertEqual(route.points, ["1,2", "3,4"])
        XCTAssertEqual(route.speed, 15)
        XCTAssertNil(try Location.parse([]).action)
    }
}
