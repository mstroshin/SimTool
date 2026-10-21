import XCTest
@testable import SimToolStream

final class FramebufferSurfaceSelectorTests: XCTestCase {
    typealias Size = FramebufferSurfaceSelector.Size

    // What an iPhone Duo publishes on Xcode 27.2: the inner panel, the cover,
    // Device Hub's resizable scene, and TV-out and CarPlay without a surface.
    let duoSurfaces = [Size(width: 2007, height: 2853), Size(width: 1398, height: 2034), Size(width: 7680, height: 4320), Size(width: 0, height: 0)]
    let duoScreens = [Size(width: 1398, height: 2034), Size(width: 2007, height: 2853)]

    func testAFoldableAtRestStreamsItsCoverNeverTheResizableScene() {
        XCTAssertEqual(FramebufferSurfaceSelector.select(duoSurfaces, screens: duoScreens), 1)
    }

    func testTheLitPanelIsPinnedWhicheverWayItsFramebufferTurns() {
        XCTAssertEqual(FramebufferSurfaceSelector.select(duoSurfaces, screens: duoScreens, preferred: Size(width: 2007, height: 2853)), 0)
        XCTAssertEqual(FramebufferSurfaceSelector.select(duoSurfaces, screens: duoScreens, preferred: Size(width: 2853, height: 2007)), 0)
        XCTAssertEqual(FramebufferSurfaceSelector.select(duoSurfaces, screens: duoScreens, preferred: Size(width: 1398, height: 2034)), 1)
    }

    func testAPreferredPanelWithNoSurfaceFallsBackToTheDevicesOwnScreen() {
        let coverOnly = [Size(width: 1398, height: 2034), Size(width: 7680, height: 4320)]
        XCTAssertEqual(FramebufferSurfaceSelector.select(coverOnly, screens: duoScreens, preferred: Size(width: 2007, height: 2853)), 0)
    }

    func testAPhoneStreamsItsScreenAndWithoutDeclaredSizesTheLargest() {
        let phone = [Size(width: 7680, height: 4320), Size(width: 1206, height: 2622)]
        XCTAssertEqual(FramebufferSurfaceSelector.select(phone, screens: [Size(width: 1206, height: 2622)]), 1)
        XCTAssertEqual(FramebufferSurfaceSelector.select(phone, screens: []), 0, "unknown screens keep the largest-surface rule")
        XCTAssertNil(FramebufferSurfaceSelector.select([Size(width: 0, height: 0)], screens: []))
    }
}
