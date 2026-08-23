import CoreGraphics
import Foundation
import XCTest
@testable import SimToolCore

/// The splice is checked against a synthetic page: rows carry pseudo-random
/// grey values, so the frames can only line up one way and any misalignment
/// shows as a wrong row value rather than as a picture that merely looks odd.
final class LongScreenshotTests: XCTestCase {
    private let width = 120
    private let viewport = 400
    private let topChrome = 60
    private let bottomChrome = 40
    private var band: Int { viewport - topChrome - bottomChrome }

    // MARK: - Fixtures

    /// A page row's grey, stable for a given row and unlike its neighbours'.
    private func pageRow(_ y: Int) -> UInt8 {
        var state = UInt64(y &+ 1) &* 6_364_136_223_846_793_005
        state ^= state >> 33
        state = state &* 0xff51_afd7_ed55_8ccd
        return UInt8(truncatingIfNeeded: state >> 29)
    }

    /// Rows of flat grey, optionally with a dark vertical bar drawn over them —
    /// a stand-in for the scroll indicator.
    private func png(rows: [UInt8], stripe: Range<Int>? = nil, over: Range<Int>? = nil) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * rows.count * 4)
        for (y, value) in rows.enumerated() {
            for x in 0..<width {
                let base = (y * width + x) * 4
                let grey = stripe?.contains(x) == true && over?.contains(y) == true ? 30 : value
                pixels[base] = grey
                pixels[base + 1] = grey
                pixels[base + 2] = grey
                pixels[base + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width,
            height: rows.count,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return try LongScreenshot.encode(image)
    }

    /// One screenful of the page: furniture, the slice of the page scrolled to
    /// `offset`, furniture again.
    private func frame(offset: Int, header: Int? = nil) throws -> Data {
        let header = header ?? topChrome
        let content = viewport - header - bottomChrome
        var rows = [UInt8](repeating: 200, count: header)
        rows += (0..<content).map { pageRow(offset + $0) }
        rows += [UInt8](repeating: 60, count: bottomChrome)
        return try png(rows: rows)
    }

    private func rows(of png: Data) throws -> [UInt8] {
        let image = try XCTUnwrap(LongScreenshot.decode(png))
        let grid = try XCTUnwrap(LongScreenshot.grid(of: image))
        return (0..<grid.height).map { grid.pixels[$0 * grid.width + grid.width / 2] }
    }

    // MARK: - Alignment

    /// Measured to within a row or two: the boundary is judged over a window of
    /// rows and then rounded outwards, so the furniture may claim a row of page
    /// but never leaves a row of itself behind in one.
    func testChromeIsTheRowsScrollingLeavesAlone() throws {
        let first = try XCTUnwrap(LongScreenshot.grid(of: XCTUnwrap(LongScreenshot.decode(frame(offset: 0)))))
        let second = try XCTUnwrap(LongScreenshot.grid(of: XCTUnwrap(LongScreenshot.decode(frame(offset: 137)))))
        let chrome = LongScreenshot.chrome(between: first, and: second)
        XCTAssertTrue((topChrome...(topChrome + 2)).contains(chrome.top), "top \(chrome.top)")
        XCTAssertTrue((bottomChrome...(bottomChrome + 2)).contains(chrome.bottom), "bottom \(chrome.bottom)")
    }

    func testOffsetFindsHowFarTheContentActuallyMoved() throws {
        let chrome = LongScreenshot.Chrome(top: topChrome, bottom: bottomChrome)
        for moved in [7, 96, 137, 211] {
            let first = try XCTUnwrap(LongScreenshot.grid(of: XCTUnwrap(LongScreenshot.decode(frame(offset: 0)))))
            let second = try XCTUnwrap(LongScreenshot.grid(of: XCTUnwrap(LongScreenshot.decode(frame(offset: moved)))))
            XCTAssertEqual(LongScreenshot.offset(from: first, to: second, chrome: chrome), moved, "moved \(moved)")
        }
    }

    func testFramesWithNothingInCommonDoNotAlign() throws {
        let chrome = LongScreenshot.Chrome(top: topChrome, bottom: bottomChrome)
        let first = try XCTUnwrap(LongScreenshot.grid(of: XCTUnwrap(LongScreenshot.decode(frame(offset: 0)))))
        // Further than a whole band: the two frames share no content, and
        // splicing them would invent the rows in between.
        let second = try XCTUnwrap(LongScreenshot.grid(of: XCTUnwrap(LongScreenshot.decode(frame(offset: band + 50)))))
        XCTAssertNil(LongScreenshot.offset(from: first, to: second, chrome: chrome))
    }

    func testSettledSpotsAPageThatStoppedMoving() throws {
        XCTAssertTrue(LongScreenshot.settled(try frame(offset: 240), try frame(offset: 240)))
        XCTAssertFalse(LongScreenshot.settled(try frame(offset: 240), try frame(offset: 268)))
    }

    /// What the shutter waits for. A sliver of one column — a scroll indicator
    /// on its way out — is a change worth waiting through, and averaged over a
    /// frame it disappears, which is why `settled` is not the test here.
    func testSteadyNoticesWhatAnAverageWouldMiss() throws {
        var plain = [UInt8](repeating: 200, count: topChrome)
        plain += (0..<band).map { pageRow(240 + $0) }
        plain += [UInt8](repeating: 60, count: bottomChrome)
        let indicator = try png(rows: plain, stripe: (width - 4)..<(width - 1), over: 100..<380)

        XCTAssertTrue(LongScreenshot.steady(try png(rows: plain), try png(rows: plain)))
        XCTAssertFalse(LongScreenshot.steady(try png(rows: plain), indicator))
        XCTAssertTrue(LongScreenshot.settled(try png(rows: plain), indicator), "an average shrugs this off")
    }

    // MARK: - Splice

    func testStitchRebuildsThePageOnceWithChromeAtItsEnds() throws {
        let offsets = [0, 137, 233, 400]
        let stitched = try LongScreenshot.stitch(frames: offsets.map { try frame(offset: $0) })
        let produced = try rows(of: stitched.png)

        var expected = [UInt8](repeating: 200, count: topChrome)
        expected += (0..<(offsets[offsets.count - 1] + band)).map(pageRow)
        expected += [UInt8](repeating: 60, count: bottomChrome)

        XCTAssertEqual(produced.count, expected.count)
        XCTAssertEqual(produced, expected)
        XCTAssertEqual(stitched.frames, offsets.count)
        XCTAssertEqual(stitched.viewports, Double(expected.count) / Double(viewport), accuracy: 0.01)
    }

    /// The header shrinks after the first scroll. The first frame is the one
    /// that saw it whole, so the picture keeps its version and the page below
    /// still runs without a repeat or a gap.
    func testTheFirstFrameKeepsItsHeaderWhenTheBarCollapses() throws {
        let tall = 100
        let frames = [
            try frame(offset: 0, header: tall),
            try frame(offset: 96),
            try frame(offset: 205),
        ]
        let produced = try rows(of: try LongScreenshot.stitch(frames: frames).png)

        var expected = [UInt8](repeating: 200, count: tall)
        expected += (0..<(205 + band)).map(pageRow)
        expected += [UInt8](repeating: 60, count: bottomChrome)
        XCTAssertEqual(produced, expected)
    }

    func testStitchStopsAtTheFrameItCannotPlace() throws {
        let frames = [
            try frame(offset: 0),
            try frame(offset: 120),
            // A jump past the whole band — a relaunch, a modal, a swipe that
            // flew. Everything after it is dropped rather than guessed at.
            try frame(offset: 120 + band + 80),
            try frame(offset: 120 + band + 200),
        ]
        let stitched = try LongScreenshot.stitch(frames: frames)
        var expected = [UInt8](repeating: 200, count: topChrome)
        expected += (0..<(120 + band)).map(pageRow)
        expected += [UInt8](repeating: 60, count: bottomChrome)
        XCTAssertEqual(try rows(of: stitched.png), expected)
        XCTAssertEqual(stitched.frames, 2)
    }

    func testASingleFrameIsPassedThroughUntouched() throws {
        let only = try frame(offset: 0)
        let stitched = try LongScreenshot.stitch(frames: [only])
        XCTAssertEqual(stitched.png, only)
        XCTAssertEqual(stitched.frames, 1)
        XCTAssertEqual(stitched.viewports, 1)
    }

    func testViewportHeightScalesTheResultByAScreenful() throws {
        let stitched = try LongScreenshot.stitch(
            frames: [try frame(offset: 0), try frame(offset: 150)],
            viewportHeight: 200
        )
        let image = try XCTUnwrap(LongScreenshot.decode(stitched.png))
        // Half the source viewport, so half of everything.
        XCTAssertEqual(image.width, width / 2)
        XCTAssertEqual(image.height, (viewport + 150) / 2)
    }
}
