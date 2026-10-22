import Foundation
import XCTest
@testable import SimToolCore

final class XcodebuildLogScannerTests: XCTestCase {
    private let products = "/Users/me/Work/App/DerivedData/Build/Products"

    func testTaskLinesNameTheTopLevelAppTheyWrite() {
        func apps(_ line: String, configuration: String = "Debug") -> [String] {
            XcodebuildLogScanner.appBundles(inTaskLine: line, configuration: configuration)
        }
        let app = "\(products)/Debug-iphonesimulator/App.app"
        XCTAssertEqual(apps("CodeSign \(app) (in target 'App' from project 'App')"), [app])
        XCTAssertEqual(apps("Touch \(app) (in target 'App' from project 'App')"), [app])
        XCTAssertEqual(apps("ProcessInfoPlistFile \(app)/Info.plist /Users/me/Work/App/Derived/InfoPlists/App-Info.plist (in target 'App' from project 'App')"), [app])
        XCTAssertEqual(apps("CpResource \(app)/message.txt /Users/me/Work/App/Resources/message.txt (in target 'App' from project 'App')"), [app])
        // A nested bundle names the app it is in.
        XCTAssertEqual(apps("CodeSign \(app)/PlugIns/Widget.appex (in target 'Widget' from project 'App')"), [app])
        // xcodebuild escapes spaces in task lines.
        XCTAssertEqual(
            apps(#"CodeSign /Users/me/My\ Work/DD/Build/Products/Debug-iphonesimulator/My\ App.app (in target 'My App' from project 'App')"#),
            ["/Users/me/My Work/DD/Build/Products/Debug-iphonesimulator/My App.app"]
        )
        XCTAssertEqual(apps("Validate \"\(app)\" (in target 'App' from project 'App')"), [app])
        // Not a top-level app of this configuration on the simulator.
        XCTAssertEqual(apps("CodeSign \(products)/Release-iphonesimulator/App.app (in target 'App' from project 'App')"), [])
        XCTAssertEqual(apps("CodeSign \(products)/Debug-watchsimulator/Watch.app (in target 'Watch' from project 'App')"), [])
        XCTAssertEqual(apps("CodeSign \(products)/Debug-iphonesimulator/Widget.appex (in target 'Widget' from project 'App')"), [])
        XCTAssertEqual(apps("Ld \(products)/Debug-iphonesimulator/Kit.framework/Kit normal (in target 'Kit' from project 'App')"), [])
        // Commands under a task are indented: the task line already said it.
        XCTAssertEqual(apps("    /usr/bin/codesign --force --sign - \(app)"), [])
        XCTAssertEqual(apps("Release build of \(app)", configuration: "Release"), [])
        XCTAssertEqual(apps("Validate \(products)/Beta-iphonesimulator/App.app (in target 'App' from project 'App')", configuration: "Beta"), ["\(products)/Beta-iphonesimulator/App.app"])
    }

    func testScannerKeepsErrorsAndAppsOutOfAStreamedLog() {
        let scanner = XcodebuildLogScanner(configuration: "Debug", maxErrorLines: 2)
        let app = "\(products)/Debug-iphonesimulator/App.app"
        for line in [
            "note: Building targets in dependency order",
            "MkDir \(app) (in target 'App' from project 'App')",
            "SwiftCompile normal arm64 /Users/me/Work/App/Sources/A.swift (in target 'App' from project 'App')",
            "/Users/me/Work/App/Sources/A.swift:3:5: error: cannot find 'x' in scope",
            "    func load(completion: @escaping (Result<Data, Error>) -> Void, isLoading:error:)",
            "/Users/me/Work/App/Sources/B.swift:9:1: error: expected '}'",
            "ld: symbol(s) not found for architecture arm64",
            "clang: error: linker command failed with exit code 1",
            "CodeSign \(app) (in target 'App' from project 'App')",
            "CodeSign \(app)/PlugIns/Widget.appex (in target 'Widget' from project 'App')",
        ] {
            scanner.consume(line)
        }
        XCTAssertEqual(scanner.builtApps.map(\.path), [app], "named once, however often")
        XCTAssertEqual(scanner.failureLines, [
            "/Users/me/Work/App/Sources/B.swift:9:1: error: expected '}'",
            "clang: error: linker command failed with exit code 1",
        ], "the last ones, within the bound")
    }

    func testStreamedFailureDetailReadsLikeTheBufferedOne() {
        let stdout = """
        CompileSwift normal arm64 /p/A.swift
        /p/A.swift:3:5: error: cannot find 'x' in scope
        Ld /p/App normal
        """
        let stderr = "** BUILD FAILED **\n"
        let scanner = XcodebuildLogScanner(configuration: "Debug")
        stdout.split(separator: "\n").forEach { scanner.consume(String($0)) }
        XCTAssertEqual(
            XcodebuildFailure.detail(stdoutErrorLines: scanner.failureLines, stdoutTail: stdout, stderr: stderr),
            XcodebuildFailure.detail(stdout: stdout, stderr: stderr)
        )
        // Nothing recognized and no summary: the end of stdout.
        XCTAssertEqual(XcodebuildFailure.detail(stdoutErrorLines: [], stdoutTail: "…last words\n", stderr: ""), "…last words")
    }
}
