import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SimToolCore

final class ScreenshotTests: XCTestCase {
    func testDownscaleCapsLongestEdgePreservingAspectRatio() throws {
        let png = try makePNG(width: 100, height: 200)

        let scaled = try SimulatorScreenshotClient.downscaled(pngData: png, maxDimension: 50)

        let size = try pngSize(scaled)
        XCTAssertEqual(size.height, 50)
        XCTAssertEqual(size.width, 25)
    }

    func testDownscaleReturnsOriginalDataWhenAlreadyWithinBounds() throws {
        let png = try makePNG(width: 30, height: 40)

        let scaled = try SimulatorScreenshotClient.downscaled(pngData: png, maxDimension: 50)

        XCTAssertEqual(scaled, png, "an image within bounds must pass through untouched")
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pngSize(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (
            width: try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
            height: try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        )
    }
}
