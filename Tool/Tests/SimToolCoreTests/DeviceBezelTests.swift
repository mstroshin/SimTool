import CoreGraphics
import Foundation
@testable import SimToolCore
import XCTest

// A screenshot "with the bezel" is the screen inside the device as Simulator
// draws it, from the DeviceKit chrome the Mac has. These build small chromes of
// their own, so nothing depends on the installed Xcode.
final class DeviceBezelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bezel-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `<root>/<name>.devicechrome` with `chrome.json` and a PDF of `size` and `colour` per image.
    private func makeChrome(_ name: String, json: String, images: [String: (size: CGSize, gray: CGFloat)]) throws {
        let resources = root.appendingPathComponent(name + ".devicechrome/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: resources.appendingPathComponent("chrome.json"))
        for (image, spec) in images {
            var box = CGRect(origin: .zero, size: spec.size)
            let context = try XCTUnwrap(CGContext(resources.appendingPathComponent(image + ".pdf") as CFURL, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(srgbRed: spec.gray, green: spec.gray, blue: spec.gray, alpha: 1))
            context.fill(box)
            context.endPDFPage()
            context.closePDF()
        }
    }

    private let phoneJSON = """
    {"images": {"composite": "Body", "sizing": {"leftWidth": 10, "rightWidth": 10, "topHeight": 12, "bottomHeight": 12}},
     "paths": {"simpleOutsideBorder": {"cornerRadiusX": 20, "cornerRadiusY": 20}},
     "inputs": [
       {"name": "volume-up", "image": "Button", "onTop": false, "anchor": "left", "align": "leading", "offsets": {"normal": {"x": 4, "y": 30}}},
       {"name": "power", "image": "Button", "onTop": false, "anchor": "right", "align": "leading", "offsets": {"normal": {"x": -4, "y": 40}}}
     ]}
    """

    func testTheScreenSitsTheChromesSizingInsideTheBodyAndTheButtonsHangOffItsEdges() throws {
        try makeChrome("phone99", json: phoneJSON, images: ["Body": (CGSize(width: 120, height: 224), 0.2), "Button": (CGSize(width: 8, height: 20), 0.4)])
        let bezel = DeviceBezel(screen: CGSize(width: 100, height: 200), cornerRadii: [10, 10, 10, 10], chrome: "com.apple.dt.devicekit.chrome.phone99", searchRoots: [root])
        XCTAssertTrue(bezel.isDeviceChrome)
        let layout = bezel.layout
        // The left button sticks out 4 pt, so the picture starts 4 pt left of the body.
        XCTAssertEqual(layout.body, CGRect(x: 4, y: 0, width: 120, height: 224))
        XCTAssertEqual(layout.screen, CGRect(x: 14, y: 12, width: 100, height: 200))
        XCTAssertEqual(layout.buttons.map(\.frame), [CGRect(x: 0, y: 30, width: 8, height: 20), CGRect(x: 120, y: 40, width: 8, height: 20)])
        XCTAssertEqual(layout.size, CGSize(width: 128, height: 224))
    }

    func testAComposedScreenshotShowsTheScreenInsideTheBodyAndClearAroundIt() throws {
        try makeChrome("phone99", json: phoneJSON, images: ["Body": (CGSize(width: 120, height: 224), 0.2), "Button": (CGSize(width: 8, height: 20), 0.4)])
        let bezel = DeviceBezel(screen: CGSize(width: 100, height: 200), cornerRadii: [10, 10, 10, 10], chrome: "com.apple.dt.devicekit.chrome.phone99", searchRoots: [root])
        let screenshot = try XCTUnwrap(solid(width: 300, height: 600, red: 1))
        let image = try XCTUnwrap(bezel.compose(screenshot: screenshot))
        XCTAssertEqual([image.width, image.height], [384, 672], "the screenshot sets the scale: 3 px a point")
        let pixels = try rgba(image)
        // Points × 3, from the top-left.
        XCTAssertEqual(pixels.at(64 * 3, 112 * 3), [255, 0, 0, 255], "the screen's middle is the screenshot")
        XCTAssertEqual(Int(pixels.at(14 * 3 + 1, 12 * 3 + 1)[0]), 51, accuracy: 6, "the screen's corner is cut: the body shows there")
        XCTAssertEqual(pixels.at(2 * 3, 2 * 3)[3], 0, "around the device the picture is clear")
        XCTAssertEqual(Int(pixels.at(1 * 3, 40 * 3)[0]), 102, accuracy: 6, "a side button shows beside the body")
    }

    func testTheMaskIsTheScreenWithItsCornersCut() throws {
        try makeChrome("phone99", json: phoneJSON, images: ["Body": (CGSize(width: 120, height: 224), 0.2), "Button": (CGSize(width: 8, height: 20), 0.4)])
        let bezel = DeviceBezel(screen: CGSize(width: 100, height: 200), cornerRadii: [10, 10, 10, 10], chrome: "com.apple.dt.devicekit.chrome.phone99", searchRoots: [root])
        let mask = try rgba(try XCTUnwrap(bezel.screenMask(scale: 2)))
        XCTAssertEqual(mask.at(64 * 2, 112 * 2)[3], 255)
        XCTAssertEqual(mask.at(14 * 2 + 1, 12 * 2 + 1)[3], 0)
        XCTAssertEqual(mask.at(5 * 2, 112 * 2)[3], 0)
    }

    // A video encoder takes even sides only.
    func testThePictureHasEvenPixelSides() throws {
        let bezel = DeviceBezel(screen: CGSize(width: 100.4, height: 201), cornerRadii: nil, chrome: nil, searchRoots: [root])
        let size = bezel.pixelSize(scale: 3)
        XCTAssertEqual(size.width % 2, 0)
        XCTAssertEqual(size.height % 2, 0)
    }

    // A chrome of eight pieces and no composite (`phone13`): corners as drawn, edges stretched.
    func testAChromeOfPiecesFramesTheScreenToo() throws {
        let json = """
        {"images": {"topLeft": "TL", "top": "T", "topRight": "TR", "right": "R", "bottomRight": "BR", "bottom": "B", "bottomLeft": "BL", "left": "L",
                    "sizing": {"leftWidth": 8, "rightWidth": 8, "topHeight": 8, "bottomHeight": 8}}}
        """
        var images: [String: (size: CGSize, gray: CGFloat)] = [:]
        for corner in ["TL", "TR", "BR", "BL"] { images[corner] = (CGSize(width: 24, height: 24), 0.3) }
        for edge in ["T", "B"] { images[edge] = (CGSize(width: 1, height: 24), 0.3) }
        for edge in ["L", "R"] { images[edge] = (CGSize(width: 24, height: 1), 0.3) }
        try makeChrome("phone98", json: json, images: images)
        let bezel = DeviceBezel(screen: CGSize(width: 60, height: 100), cornerRadii: [6, 6, 6, 6], chrome: "com.apple.dt.devicekit.chrome.phone98", searchRoots: [root])
        XCTAssertTrue(bezel.isDeviceChrome)
        XCTAssertEqual(bezel.layout.screen, CGRect(x: 8, y: 8, width: 60, height: 100))
        let pixels = try rgba(try XCTUnwrap(bezel.compose(screenshot: try XCTUnwrap(solid(width: 60, height: 100, red: 1)))))
        XCTAssertEqual(Int(pixels.at(2, 50)[0]), 77, accuracy: 6, "the left edge is drawn")
        XCTAssertEqual(pixels.at(38, 58), [255, 0, 0, 255])
    }

    // No chrome on this Mac for the device: a plain drawn frame, never a missing picture.
    func testWithoutTheDevicesChromeTheFrameIsDrawn() throws {
        let bezel = DeviceBezel(screen: CGSize(width: 100, height: 200), cornerRadii: [20, 20, 20, 20], chrome: "com.apple.dt.devicekit.chrome.phone404", searchRoots: [root])
        XCTAssertFalse(bezel.isDeviceChrome)
        XCTAssertEqual(bezel.layout.screen, CGRect(x: 18, y: 18, width: 100, height: 200))
        let image = try XCTUnwrap(bezel.compose(screenshot: try XCTUnwrap(solid(width: 200, height: 400, red: 1))))
        XCTAssertEqual([image.width, image.height], [272, 472])
        let pixels = try rgba(image)
        XCTAssertEqual(pixels.at(136, 236), [255, 0, 0, 255])
        XCTAssertLessThan(pixels.at(8, 236)[0], 40, "the frame is dark")
    }

    // MARK: - Pixels

    private func solid(width: Int, height: Int, red: CGFloat) -> CGImage? {
        guard let context = DeviceBezel.context(size: (width, height)) else { return nil }
        context.setFillColor(CGColor(srgbRed: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private struct Pixels {
        var data: [UInt8], width: Int
        /// RGBA at x, y from the top-left.
        func at(_ x: Int, _ y: Int) -> [UInt8] { Array(data[(y * width + x) * 4..<(y * width + x) * 4 + 4]) }
    }

    private func rgba(_ image: CGImage) throws -> Pixels {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Pixels(data: data, width: image.width)
    }
}
