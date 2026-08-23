import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Splices the frames of a scrolled screen into one tall picture — the page a
/// user would see if the phone were long enough to show it whole.
///
/// Frames are aligned by their pixels, never by how far the swipe was asked to
/// travel: inertia, rubber banding and lists that snap all mean the content
/// moves some other distance than the gesture requested. Two rules shape the
/// result:
///
/// - **The earlier frame wins.** Each frame contributes only the rows below
///   what its predecessor already showed, so a navigation bar that collapses
///   after the first scroll stays the way it was first seen instead of
///   reappearing, shrunk, partway down the page.
/// - **Chrome is spliced once.** Rows that scrolling never moves — status bar,
///   navigation bar, tab bar — are the window's furniture, not the page: the
///   top ones come from the first frame, the bottom ones are appended from the
///   last, and every frame in between contributes only its scrolling middle.
///   Without that rule a tab bar would band the picture once per scroll.
public enum LongScreenshot {
    /// Rows at the top and bottom of a frame that scrolling leaves untouched.
    public struct Chrome: Equatable, Sendable {
        public var top: Int
        public var bottom: Int

        public init(top: Int, bottom: Int) {
            self.top = top
            self.bottom = bottom
        }

        public static let none = Chrome(top: 0, bottom: 0)
    }

    public struct Stitched: Sendable {
        public var png: Data
        /// Frames that made it into the picture. One means the screen did not
        /// scroll and the picture is a plain screenshot.
        public var frames: Int
        /// How many screenfuls tall the result is, chrome included.
        public var viewports: Double
    }

    /// One frame reduced to what alignment needs: 8-bit luminance with columns
    /// thinned out. Rows keep full resolution — the alignment answer *is* a row
    /// count, and rounding it would blur every seam.
    struct Grid {
        var width: Int
        var height: Int
        var pixels: [UInt8]
    }

    /// Columns the alignment grid keeps. Enough to tell one row of a list from
    /// the next, few enough that scanning every candidate offset across a
    /// full-height frame stays cheap.
    static let gridColumns = 96
    /// Mean per-pixel luminance difference under which two rows count as the
    /// same row. Generous on purpose: a clock ticking over a minute or an
    /// antialiased edge must not unfreeze the status bar.
    static let sameRowTolerance = 3.0
    /// Mean per-pixel difference under which an alignment is believed. Above
    /// it the frames share no common region — an animation, a reload, or a
    /// swipe that overshot the whole viewport — and splicing them would invent
    /// content that was never on screen.
    static let alignmentTolerance = 9.0
    /// Neither edge of a frame may claim more than this share of its height as
    /// chrome, and the two together no more than `chromeCeiling`. A screen with
    /// a large flat background repeats identical rows far past its furniture.
    static let chromeLimit = 0.30
    static let chromeCeiling = 0.55
    /// The frames must keep at least this share of the scrolling band in
    /// common. A shorter overlap makes the match a coincidence of a few rows.
    static let minimumOverlap = 0.2

    // MARK: - Public API

    /// Splices `frames` — screenshots of one screen taken top to bottom — into
    /// a single picture. `viewportHeight`, when given, scales the result so one
    /// screenful is that many pixels tall, which keeps a long picture's detail
    /// comparable to a plain screenshot's.
    ///
    /// Alignment stops at the first frame that shares nothing with the one
    /// before it: a short, correct picture beats a tall one with invented
    /// content in the middle.
    public static func stitch(frames pngs: [Data], viewportHeight: Int? = nil) throws -> Stitched {
        guard let first = pngs.first else { throw SimToolError("No frames to stitch") }
        let images = try pngs.map { png -> CGImage in
            guard let image = decode(png) else { throw SimToolError("A frame is not a decodable image") }
            return image
        }
        let size = CGSize(width: images[0].width, height: images[0].height)
        guard images.allSatisfy({ CGSize(width: $0.width, height: $0.height) == size }) else {
            throw SimToolError("Frames of the same screen differ in size")
        }
        guard images.count > 1 else {
            guard let viewportHeight else { return Stitched(png: first, frames: 1, viewports: 1) }
            let scaled = try resized(images[0], byHeightOf: images[0].height, to: viewportHeight)
            return Stitched(png: try encode(scaled), frames: 1, viewports: 1)
        }
        let grids = images.compactMap { grid(of: $0) }
        guard grids.count == images.count else { throw SimToolError("Failed to read frame pixels") }

        let chrome = chrome(of: grids)
        // What each frame adds under what the picture already shows. The first
        // frame brings everything down to the bottom chrome; the rest bring the
        // rows the scroll revealed.
        let frameHeight = images[0].height
        let contentBottom = frameHeight - chrome.bottom
        var slices: [(image: CGImage, top: Int, height: Int)] = [
            (images[0], 0, contentBottom),
        ]
        for index in 1..<images.count {
            guard let shift = offset(from: grids[index - 1], to: grids[index], chrome: chrome), shift > 0 else { break }
            slices.append((images[index], contentBottom - shift, shift))
        }
        // The bottom furniture, once, from the last frame that made it in.
        if chrome.bottom > 0, let last = slices.last?.image {
            slices.append((last, contentBottom, chrome.bottom))
        }

        let total = slices.reduce(0) { $0 + $1.height }
        let composed = try compose(slices: slices, width: images[0].width, height: total)
        let scaled = try viewportHeight.map { try resized(composed, byHeightOf: frameHeight, to: $0) } ?? composed
        return Stitched(
            png: try encode(scaled),
            frames: slices.count - (chrome.bottom > 0 ? 1 : 0),
            viewports: Double(total) / Double(frameHeight)
        )
    }

    /// True when a scroll moved nothing: the two frames differ only by what
    /// never holds still anyway, so the page has hit its bottom.
    public static func settled(_ a: Data, _ b: Data) -> Bool {
        guard let first = decode(a), let second = decode(b),
              let left = grid(of: first), let right = grid(of: second),
              left.height == right.height, left.width == right.width else { return false }
        return meanDifference(left, right, rows: 0..<left.height, against: 0) <= sameRowTolerance
    }

    /// True when two frames of a screen that is no longer moving agree
    /// everywhere that would show.
    ///
    /// A different question from ``settled``'s, and a stricter one: a scroll
    /// indicator fading out redraws a sliver of a single column, which is
    /// nothing to an average taken over the whole frame and quite enough to
    /// print a grey stripe down the picture from a seam. Counting the pixels
    /// that visibly changed catches it while leaving room for the clock to
    /// turn over.
    public static func steady(_ a: Data, _ b: Data) -> Bool {
        guard let first = decode(a), let second = decode(b),
              let left = grid(of: first), let right = grid(of: second),
              left.height == right.height, left.width == right.width else { return false }
        var changed = 0
        let budget = Int(Double(left.pixels.count) * 0.001)
        for index in 0..<left.pixels.count
        where abs(Int(left.pixels[index]) - Int(right.pixels[index])) > 24 {
            changed += 1
            if changed > budget { return false }
        }
        return true
    }

    // MARK: - Alignment

    /// The chrome shared by a run of frames, measured on a pair the collapsing
    /// header has already settled over: between the first two frames a large
    /// title is still shrinking, and a navigation bar caught mid-collapse would
    /// read as scrolling content and land in the band.
    static func chrome(of grids: [Grid]) -> Chrome {
        guard grids.count > 1 else { return .none }
        // The pair after the first, by which a collapsing header has settled —
        // then the opening pair, for a run of two frames or one whose later
        // frames turn out to share nothing.
        for (left, right) in grids.count > 2 ? [(1, 2), (0, 1)] : [(0, 1)] {
            let found = chrome(between: grids[left], and: grids[right])
            if found != .none { return found }
        }
        return .none
    }

    /// A row belongs to the window rather than to the page when it did not
    /// travel with the content, and there are two ways not to travel: standing
    /// still (an opaque navigation or tab bar) and refusing to line up with
    /// where the content went (a home indicator or a translucent bar the page
    /// slid underneath, which changes with the content behind it yet never
    /// moves). Only the first is visible without knowing the scroll distance,
    /// which is why the alignment runs first, on the middle of the frame where
    /// neither edge's furniture reaches.
    static func chrome(between a: Grid, and b: Grid) -> Chrome {
        guard a.height == b.height, a.width == b.width else { return .none }
        let inset = Int(Double(a.height) * 0.2)
        // Without a scroll distance only the standing-still half of the test is
        // available; furniture the page slides under goes unnoticed, which is
        // the old behaviour rather than a wrong one.
        let shift = offset(from: a, to: b, chrome: Chrome(top: inset, bottom: inset))

        /// Judged over a three-row window: single rows of unrelated content
        /// land within tolerance of each other often enough that a row at a
        /// time would find furniture in the middle of the page.
        func window(_ row: Int) -> Range<Int> {
            max(0, row - 1)..<min(a.height, row + 2)
        }
        func stands(still row: Int) -> Bool {
            meanDifference(a, b, rows: window(row), against: 0) <= sameRowTolerance
        }
        /// Whether the row of `a` found the content it should have handed down
        /// to `b`, and the mirror of that question for `b`'s rows.
        func travelled(inFirst row: Int) -> Bool {
            guard let shift, row - shift >= 0 else { return true }
            return meanDifference(a, b, rows: window(row), against: -shift) <= alignmentTolerance
        }
        func travelled(inSecond row: Int) -> Bool {
            guard let shift, row + shift < a.height else { return true }
            return meanDifference(b, a, rows: window(row), against: shift) <= alignmentTolerance
        }

        // How far the furniture reaches, not how long its unbroken run is: a
        // home indicator floats above the bottom edge, and the page showing
        // through beneath it belongs to the last frame just as the indicator
        // does. The gap that may be bridged is small enough that furniture
        // never links up with the page beyond it.
        let limit = Int(Double(a.height) * chromeLimit)
        let bridge = max(4, Int(Double(a.height) * 0.015))
        var top = 0
        var slack = bridge
        for row in 0..<limit {
            if stands(still: row) || !travelled(inSecond: row) {
                top = row + 1
                slack = bridge
            } else {
                slack -= 1
                if slack < 0 { break }
            }
        }
        var bottom = 0
        slack = bridge
        for row in ((a.height - limit)..<a.height).reversed() {
            if stands(still: row) || !travelled(inFirst: row) {
                bottom = a.height - row
                slack = bridge
            } else {
                slack -= 1
                if slack < 0 { break }
            }
        }
        // The three-row window blurs the boundary by up to a row either way, so
        // round outwards: a row of page claimed as furniture is spliced from a
        // neighbouring frame and looks the same, while a row of furniture left
        // in the page prints the edge of a home indicator across the middle of
        // the picture, once per seam.
        if top > 0 { top = min(limit, top + 1) }
        if bottom > 0 { bottom = min(limit, bottom + 1) }
        // A flat background repeats identical rows well past the furniture.
        // Leaving those rows in the band costs a little alignment noise;
        // cutting live content out of the picture costs the content.
        guard Double(top + bottom) <= Double(a.height) * chromeCeiling else { return .none }
        return Chrome(top: top, bottom: bottom)
    }

    /// How many rows the content moved between two frames, or nil when they
    /// share no believable overlap. Searched coarsely first, then refined, so
    /// the cost stays linear in frame height rather than quadratic.
    static func offset(from previous: Grid, to next: Grid, chrome: Chrome) -> Int? {
        let start = chrome.top
        let end = previous.height - chrome.bottom
        let band = end - start
        guard band > 16 else { return nil }
        let ceiling = band - Int(Double(band) * minimumOverlap)
        guard ceiling > 1 else { return nil }

        var best = (shift: 0, score: Double.greatestFiniteMagnitude)
        let coarse = max(1, band / 160)
        var shift = coarse
        while shift <= ceiling {
            let score = alignmentScore(previous, next, band: start..<end, shift: shift, rowStride: coarse * 2)
            if score < best.score { best = (shift, score) }
            shift += coarse
        }
        guard best.shift > 0 else { return nil }
        var refined = (shift: best.shift, score: Double.greatestFiniteMagnitude)
        for candidate in max(1, best.shift - coarse)...min(ceiling, best.shift + coarse) {
            let score = alignmentScore(previous, next, band: start..<end, shift: candidate, rowStride: 1)
            if score < refined.score { refined = (candidate, score) }
        }
        return refined.score <= alignmentTolerance ? refined.shift : nil
    }

    /// Mean difference between the band of `previous` starting `shift` rows
    /// down and the top of the same band in `next` — low where the two frames
    /// show the same content.
    private static func alignmentScore(
        _ previous: Grid,
        _ next: Grid,
        band: Range<Int>,
        shift: Int,
        rowStride: Int
    ) -> Double {
        let overlap = band.count - shift
        guard overlap > 0 else { return .greatestFiniteMagnitude }
        return meanDifference(
            previous,
            next,
            rows: (band.lowerBound + shift)..<(band.lowerBound + shift + overlap),
            against: -shift,
            rowStride: rowStride
        )
    }

    /// Mean absolute luminance difference between rows of `a` and the rows of
    /// `b` sitting `displacement` further down.
    private static func meanDifference(
        _ a: Grid,
        _ b: Grid,
        rows: Range<Int>,
        against displacement: Int,
        rowStride: Int = 1
    ) -> Double {
        var total = 0
        var counted = 0
        let columnStride = max(1, a.width / 48)
        var row = rows.lowerBound
        while row < rows.upperBound {
            let mirrored = row + displacement
            guard mirrored >= 0, mirrored < b.height else { row += rowStride; continue }
            let left = row * a.width
            let right = mirrored * b.width
            var column = 0
            while column < a.width {
                total += abs(Int(a.pixels[left + column]) - Int(b.pixels[right + column]))
                counted += 1
                column += columnStride
            }
            row += rowStride
        }
        guard counted > 0 else { return .greatestFiniteMagnitude }
        return Double(total) / Double(counted)
    }

    // MARK: - Pixels

    static func decode(_ png: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Renders a frame into the luminance grid alignment reads. Row 0 of the
    /// grid is the top of the frame: a bitmap context lays its rows out top
    /// down even though its drawing origin sits at the bottom left.
    static func grid(of image: CGImage) -> Grid? {
        let width = min(gridColumns, image.width)
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return Grid(width: width, height: height, pixels: pixels)
    }

    /// Stacks the slices top to bottom. Crops are taken in image coordinates
    /// (origin top left) and drawn in context coordinates (origin bottom left),
    /// which is where the height subtraction comes from.
    private static func compose(
        slices: [(image: CGImage, top: Int, height: Int)],
        width: Int,
        height: Int
    ) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw SimToolError("Failed to allocate the stitched image") }
        var cursor = 0
        for slice in slices {
            guard slice.height > 0,
                  let crop = slice.image.cropping(to: CGRect(
                      x: 0,
                      y: slice.top,
                      width: width,
                      height: slice.height
                  )) else { continue }
            context.draw(crop, in: CGRect(
                x: 0,
                y: height - cursor - slice.height,
                width: width,
                height: slice.height
            ))
            cursor += slice.height
        }
        guard let composed = context.makeImage() else { throw SimToolError("Failed to render the stitched image") }
        return composed
    }

    /// Scales the picture so that one screenful — `sourceViewport` pixels of
    /// the original — becomes `target` pixels tall.
    private static func resized(_ image: CGImage, byHeightOf sourceViewport: Int, to target: Int) throws -> CGImage {
        guard sourceViewport > 0, target > 0, sourceViewport != target else { return image }
        let scale = Double(target) / Double(sourceViewport)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw SimToolError("Failed to allocate the scaled image") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw SimToolError("Failed to scale the stitched image") }
        return scaled
    }

    static func encode(_ image: CGImage) throws -> Data {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw SimToolError("Failed to create PNG encoder") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SimToolError("Failed to encode PNG") }
        return buffer as Data
    }
}
