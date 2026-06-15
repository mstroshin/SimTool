import XCTest
@testable import SimToolStream

final class H264EncoderTests: XCTestCase {
    func testDownscalesLongestSideToCapPreservingAspect() {
        let size = H264Encoder.encodeSize(sourceWidth: 1206, sourceHeight: 2622, maxDimension: 1280)
        XCTAssertEqual(max(size.width, size.height), 1280, "longest side should be clamped to the cap")
        XCTAssertEqual(size.width % 2, 0, "width must be even for 4:2:0 H.264")
        XCTAssertEqual(size.height % 2, 0, "height must be even for 4:2:0 H.264")
        let sourceAspect = 1206.0 / 2622.0
        let targetAspect = Double(size.width) / Double(size.height)
        XCTAssertEqual(targetAspect, sourceAspect, accuracy: 0.01, "aspect ratio must be preserved")
    }

    func testDownscaleHandlesLandscape() {
        let size = H264Encoder.encodeSize(sourceWidth: 2622, sourceHeight: 1206, maxDimension: 1280)
        XCTAssertEqual(max(size.width, size.height), 1280)
        XCTAssertEqual(size.width % 2, 0)
        XCTAssertEqual(size.height % 2, 0)
    }

    func testSmallSourceIsNotUpscaledButForcedEven() {
        let size = H264Encoder.encodeSize(sourceWidth: 801, sourceHeight: 601, maxDimension: 1280)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }

    func testZeroCapKeepsSourceEven() {
        let size = H264Encoder.encodeSize(sourceWidth: 1207, sourceHeight: 2623, maxDimension: 0)
        XCTAssertEqual(size.width, 1206)
        XCTAssertEqual(size.height, 2622)
    }
}
