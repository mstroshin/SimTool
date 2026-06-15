import XCTest
@testable import SimToolCore

final class XcodebuildProgressTests: XCTestCase {
    func testCompileLines() {
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "SwiftCompile normal arm64 Compiling\\ ContentView.swift /Users/dev/App/ContentView.swift (in target 'App' from project 'App')"),
            "Compiling ContentView.swift"
        )
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "CompileC /out/foo.o /Users/dev/App/foo.m normal arm64 objective-c com.apple.compilers.llvm.clang.1_0.compiler"),
            "Compiling foo.m"
        )
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "CompileSwiftSources normal arm64 com.apple.xcode.tools.swift.compiler (in target 'App' from project 'App')"),
            "Compiling sources"
        )
    }

    func testLinkSignAndPlistLines() {
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "Ld /Users/dev/DerivedData/App-abc/Build/Products/Debug-iphonesimulator/App.app/App normal (in target 'App' from project 'App')"),
            "Linking App"
        )
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "CodeSign /Users/dev/DerivedData/App-abc/Build/Products/Debug-iphonesimulator/App.app (in target 'App' from project 'App')"),
            "Signing App.app"
        )
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "ProcessInfoPlistFile /out/Info.plist /in/Info.plist (in target 'App' from project 'App')"),
            "Processing Info.plist"
        )
    }

    func testResourceScriptAndPlanningLines() {
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "CompileAssetCatalog /out /Users/dev/App/Assets.xcassets (in target 'App' from project 'App')"),
            "Compiling asset catalogs"
        )
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "CompileStoryboard /Users/dev/App/Main.storyboard (in target 'App' from project 'App')"),
            "Compiling Main.storyboard"
        )
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "PhaseScriptExecution Run\\ SwiftLint /Users/dev/DerivedData/Script-ABC.sh (in target 'App' from project 'App')"),
            "Running script Run SwiftLint"
        )
        XCTAssertEqual(
            XcodebuildProgress.status(forLine: "CpResource /out/Settings.bundle /in/Settings.bundle (in target 'App' from project 'App')"),
            "Copying resources"
        )
        XCTAssertEqual(XcodebuildProgress.status(forLine: "Resolve Package Graph"), "Resolving packages")
        XCTAssertEqual(XcodebuildProgress.status(forLine: "Build description signature: 4cd4b2d"), "Planning build")
        XCTAssertEqual(XcodebuildProgress.status(forLine: "Planning build"), "Planning build")
    }

    func testTokenizerEdgeCasesDoNotCrash() {
        XCTAssertEqual(XcodebuildProgress.status(forLine: "Ld /path/App\\"), "Linking App\\")
        XCTAssertEqual(XcodebuildProgress.status(forLine: "Ld /path/App\\ "), "Linking App ")
        XCTAssertEqual(XcodebuildProgress.status(forLine: "Ld  /path/App  normal"), "Linking App")
        XCTAssertNil(XcodebuildProgress.status(forLine: "\\"))
    }

    func testUnknownAndIndentedLinesReturnNil() {
        XCTAssertNil(XcodebuildProgress.status(forLine: "    cd /Users/dev/App"))
        XCTAssertNil(XcodebuildProgress.status(forLine: "\texport SDKROOT=iphonesimulator"))
        XCTAssertNil(XcodebuildProgress.status(forLine: "warning: deprecated API"))
        XCTAssertNil(XcodebuildProgress.status(forLine: "** BUILD SUCCEEDED **"))
        XCTAssertNil(XcodebuildProgress.status(forLine: ""))
    }
}
