import XCTest
@testable import SimToolCore

final class InteractiveDeeplinksTests: XCTestCase {
    private func makeConfig(deeplinks: [ProjectConfig.Deeplink]) -> ProjectConfig {
        ProjectConfig(
            simulator: "iPhone 16 Pro",
            bundleId: "com.example.MyApp",
            build: .init(workspace: "/tmp/App.xcworkspace", scheme: "App"),
            deeplinks: deeplinks,
            sourcePath: "/tmp/.simtool/config.yml"
        )
    }

    func testChoicesListDeeplinksInConfigOrderWithExitLast() {
        let details = ProjectConfig.Deeplink(name: "Details", url: "myapp://items/42")
        let settings = ProjectConfig.Deeplink(name: "Settings", url: "myapp://settings?section=general")
        let choices = InteractiveDeeplinkChoice.choices(for: makeConfig(deeplinks: [details, settings]))
        XCTAssertEqual(choices, [.deeplink(details), .deeplink(settings), .exit])
    }

    func testDeeplinkChoiceDescriptionMatchesDeeplink() {
        let link = ProjectConfig.Deeplink(name: "Details", url: "myapp://items/42")
        XCTAssertEqual(InteractiveDeeplinkChoice.deeplink(link).description, link.description)
    }

    func testExitChoiceDescription() {
        XCTAssertEqual(InteractiveDeeplinkChoice.exit.description, "Exit")
    }
}
