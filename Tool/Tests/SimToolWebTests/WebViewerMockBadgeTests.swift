import XCTest
@testable import SimToolWeb

final class WebViewerMockBadgeTests: XCTestCase {
    func testHTMLContainsMockedStylingAndBadgeLogic() {
        let html = WebViewer.html()
        XCTAssertTrue(html.contains(".network-row.mocked"), "missing mocked row CSS")
        XCTAssertTrue(html.contains("event.mocked"), "missing mocked badge logic")
        XCTAssertTrue(html.contains("🎭"), "missing mocked badge glyph")
    }
}
