import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The device drawn around its screen — the picture Simulator and Device Hub
/// show — for screenshots and recordings "with the bezel".
///
/// Xcode installs a DeviceKit chrome per device family
/// (`/Library/Developer/DeviceKit/Chrome/phone11.devicechrome`): vector PDFs of
/// the body and of each side button, and `chrome.json` saying how they fit
/// around a screen. A device type's `capabilities.plist` names its chrome per
/// screen. SimTool ships none of it: the chrome is read from the Mac at run
/// time, and a device whose chrome is missing gets a plain drawn frame.
public struct DeviceBezel: @unchecked Sendable {
    /// Everything in points, from the picture's top-left corner.
    public struct Layout: Equatable, Sendable {
        public var size: CGSize
        public var body: CGRect
        public var screen: CGRect
        /// Each side button: its image, where it sits, and whether the body covers it.
        public var buttons: [Button]

        public struct Button: Equatable, Sendable {
            public var image: String
            public var frame: CGRect
            public var onTop: Bool
        }
    }

    public let layout: Layout
    /// The screen's corner radii in points, clockwise from its top-left.
    public let cornerRadii: [Double]
    private let chrome: DeviceChrome?

    /// The bezel around a screen of `screen` points: its device's chrome when
    /// the Mac has it, a drawn frame otherwise.
    public init(screen: CGSize, cornerRadii: [Double]?, chrome identifier: String?, searchRoots: [URL] = DeviceChrome.searchRoots) {
        let radii = cornerRadii?.count == 4 ? cornerRadii! : [0, 0, 0, 0]
        self.cornerRadii = radii
        let chrome = identifier.flatMap { DeviceChrome.load(identifier: $0, searchRoots: searchRoots) }
        self.chrome = chrome
        self.layout = chrome?.layout(screen: screen) ?? Self.plainLayout(screen: screen)
    }

    /// Whether this is the device's own chrome, not the drawn stand-in.
    public var isDeviceChrome: Bool { chrome != nil }

    /// The picture at `scale` pixels per point, its pixel sides rounded up to
    /// even numbers (what a video encoder takes): the device on `background`
    /// (transparent when nil), the screen area left as the chrome draws it.
    public func render(scale: CGFloat, background: CGColor? = nil) -> CGImage? {
        guard let context = Self.context(size: pixelSize(scale: scale)) else { return nil }
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(origin: .zero, size: CGSize(width: context.width, height: context.height)))
        }
        // Points, from the top-left.
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        draw(in: context)
        return context.makeImage()
    }

    /// White where the screen shows through — its rounded corners cut — and
    /// clear elsewhere, at the same size as `render`.
    public func screenMask(scale: CGFloat) -> CGImage? {
        guard let context = Self.context(size: pixelSize(scale: scale)) else { return nil }
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        context.addPath(screenPath())
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        return context.makeImage()
    }

    /// A screenshot of this screen inside the bezel, as a PNG. The screenshot
    /// sets the scale: its width over the screen's width in points.
    public func compose(screenshot: CGImage, background: CGColor? = nil) -> CGImage? {
        let scale = CGFloat(screenshot.width) / layout.screen.width
        guard let context = Self.context(size: pixelSize(scale: scale)) else { return nil }
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(origin: .zero, size: CGSize(width: context.width, height: context.height)))
        }
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        draw(in: context)
        context.saveGState()
        context.addPath(screenPath())
        context.clip()
        Self.drawImage(screenshot, in: layout.screen, context: context)
        context.restoreGState()
        return context.makeImage()
    }

    public func pixelSize(scale: CGFloat) -> (width: Int, height: Int) {
        func even(_ value: CGFloat) -> Int { let pixels = Int(ceil(value - 0.001)); return pixels + pixels % 2 }
        return (even(layout.size.width * scale), even(layout.size.height * scale))
    }

    /// The screen's outline with its own corner radii.
    func screenPath() -> CGPath {
        let rect = layout.screen
        let limit = min(rect.width, rect.height) / 2
        let r = cornerRadii.map { min(CGFloat($0), limit) }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + r[0], y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r[1], y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r[1]), radius: r[1])
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r[2]))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r[2], y: rect.maxY), radius: r[2])
        path.addLine(to: CGPoint(x: rect.minX + r[3], y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r[3]), radius: r[3])
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r[0]))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r[0], y: rect.minY), radius: r[0])
        path.closeSubpath()
        return path
    }

    /// Body, then the screen's dark glass, with the buttons under or over it —
    /// in a context that draws points from the top-left.
    private func draw(in context: CGContext) {
        guard let chrome else { drawPlain(in: context); return }
        for button in layout.buttons where !button.onTop { chrome.drawImage(named: button.image, in: button.frame, context: context) }
        chrome.drawBody(in: layout.body, screen: layout.screen, context: context)
        for button in layout.buttons where button.onTop { chrome.drawImage(named: button.image, in: button.frame, context: context) }
    }

    // MARK: - The drawn stand-in

    static let plainBorder: CGFloat = 18

    static func plainLayout(screen: CGSize) -> Layout {
        let body = CGRect(x: 0, y: 0, width: screen.width + 2 * plainBorder, height: screen.height + 2 * plainBorder)
        return Layout(size: body.size, body: body, screen: CGRect(x: plainBorder, y: plainBorder, width: screen.width, height: screen.height), buttons: [])
    }

    private func drawPlain(in context: CGContext) {
        let radius = CGFloat(cornerRadii.max() ?? 0) + Self.plainBorder
        let body = CGPath(roundedRect: layout.body.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(body)
        context.setFillColor(CGColor(gray: 0.06, alpha: 1))
        context.fillPath()
        context.addPath(body)
        context.setStrokeColor(CGColor(gray: 0.32, alpha: 1))
        context.setLineWidth(1.5)
        context.strokePath()
        context.addPath(screenPath())
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
    }

    // MARK: - Drawing helpers

    static func context(size: (width: Int, height: Int)) -> CGContext? {
        guard size.width > 0, size.height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .high
        return context
    }

    /// An image upright in a context that draws from the top-left.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    public static func image(png data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// One DeviceKit chrome bundle: `chrome.json` and the PDFs it names.
public struct DeviceChrome: @unchecked Sendable {
    /// Where Xcode installs the chromes.
    public static let searchRoots = [
        URL(fileURLWithPath: "/Library/Developer/DeviceKit/Chrome"),
        URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/Chrome"),
    ]

    struct Description: Decodable {
        struct Images: Decodable {
            var topLeft: String?, top: String?, topRight: String?, right: String?
            var bottomRight: String?, bottom: String?, bottomLeft: String?, left: String?
            var composite: String?
            var sizing: Insets
        }
        struct Insets: Decodable {
            var leftWidth: CGFloat, rightWidth: CGFloat, topHeight: CGFloat, bottomHeight: CGFloat
        }
        struct Paths: Decodable {
            struct Border: Decodable { var cornerRadiusX: CGFloat?, cornerRadiusY: CGFloat? }
            var simpleOutsideBorder: Border?
        }
        struct Input: Decodable {
            struct Offsets: Decodable { var normal: Offset }
            struct Offset: Decodable { var x: CGFloat, y: CGFloat }
            var name: String?
            var image: String?
            var onTop: Bool?
            var anchor: String?
            var align: String?
            var offsets: Offsets?
        }
        var images: Images
        var paths: Paths?
        var inputs: [Input]?
    }

    let description: Description
    let resources: URL

    /// `com.apple.dt.devicekit.chrome.phone11` → `<root>/phone11.devicechrome`,
    /// or nil when no root has it or its description does not read.
    public static func load(identifier: String, searchRoots: [URL] = searchRoots) -> DeviceChrome? {
        let name = identifier.split(separator: ".").last.map(String.init) ?? identifier
        for root in searchRoots {
            let resources = root.appendingPathComponent(name + ".devicechrome/Contents/Resources")
            guard let data = try? Data(contentsOf: resources.appendingPathComponent("chrome.json")),
                  let description = try? JSONDecoder().decode(Description.self, from: data) else { continue }
            let chrome = DeviceChrome(description: description, resources: resources)
            guard chrome.page(description.images.composite) != nil || chrome.page(description.images.topLeft) != nil else { continue }
            return chrome
        }
        return nil
    }

    func page(_ name: String?) -> CGPDFPage? {
        guard let name, let document = CGPDFDocument(resources.appendingPathComponent(name + ".pdf") as CFURL) else { return nil }
        return document.page(at: 1)
    }

    /// The screen sits `sizing` inside the body; each side button hangs off the
    /// edge it is anchored to, `offset` in from it. The picture holds all of it.
    func layout(screen: CGSize) -> DeviceBezel.Layout {
        let sizing = description.images.sizing
        let body = CGRect(x: 0, y: 0, width: screen.width + sizing.leftWidth + sizing.rightWidth, height: screen.height + sizing.topHeight + sizing.bottomHeight)
        var buttons: [DeviceBezel.Layout.Button] = []
        for input in description.inputs ?? [] {
            guard let image = input.image, let offset = input.offsets?.normal, let size = page(image)?.getBoxRect(.mediaBox).size else { continue }
            buttons.append(.init(image: image, frame: Self.buttonFrame(size: size, anchor: input.anchor ?? "left", align: input.align ?? "leading", offset: offset, body: body), onTop: input.onTop ?? false))
        }
        let all = buttons.reduce(body) { $0.union($1.frame) }
        // The picture starts at the leftmost, topmost mark.
        let shift = CGAffineTransform(translationX: -all.minX, y: -all.minY)
        return DeviceBezel.Layout(
            size: all.size,
            body: body.applying(shift),
            screen: CGRect(x: sizing.leftWidth, y: sizing.topHeight, width: screen.width, height: screen.height).applying(shift),
            buttons: buttons.map { .init(image: $0.image, frame: $0.frame.applying(shift), onTop: $0.onTop) }
        )
    }

    static func buttonFrame(size: CGSize, anchor: String, align: String, offset: Description.Input.Offset, body: CGRect) -> CGRect {
        func along(start: CGFloat, end: CGFloat, length: CGFloat, shift: CGFloat) -> CGFloat {
            switch align {
            case "trailing": return end - shift - length
            case "center": return (start + end - length) / 2 + shift
            default: return start + shift
            }
        }
        switch anchor {
        case "right":
            return CGRect(x: body.maxX + offset.x, y: along(start: body.minY, end: body.maxY, length: size.height, shift: offset.y), width: size.width, height: size.height)
        case "top":
            return CGRect(x: along(start: body.minX, end: body.maxX, length: size.width, shift: offset.x), y: body.minY + offset.y - size.height, width: size.width, height: size.height)
        case "bottom":
            return CGRect(x: along(start: body.minX, end: body.maxX, length: size.width, shift: offset.x), y: body.maxY + offset.y, width: size.width, height: size.height)
        default:
            return CGRect(x: body.minX + offset.x - size.width, y: along(start: body.minY, end: body.maxY, length: size.height, shift: offset.y), width: size.width, height: size.height)
        }
    }

    /// The body: the composite stretched nine-slice — its corners kept, its
    /// edges stretched — or the eight pieces around a dark screen.
    func drawBody(in body: CGRect, screen: CGRect, context: CGContext) {
        let images = description.images
        if let composite = page(images.composite) {
            let box = composite.getBoxRect(.mediaBox)
            // Corners keep their curve: the cap is at least the outline's radius.
            let border = description.paths?.simpleOutsideBorder
            let radiusX = border?.cornerRadiusX ?? 0, radiusY = border?.cornerRadiusY ?? 0
            let capX = min(box.width / 2, body.width / 2, max(images.sizing.leftWidth, images.sizing.rightWidth, radiusX))
            let capY = min(box.height / 2, body.height / 2, max(images.sizing.topHeight, images.sizing.bottomHeight, radiusY))
            Self.drawNineSlice(composite, caps: (capX, capY, capX, capY), in: body, context: context)
            return
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(screen)
        let corners = [(images.topLeft, 0, 0), (images.topRight, 1, 0), (images.bottomRight, 1, 1), (images.bottomLeft, 0, 1)].compactMap { name, right, bottom -> (CGPDFPage, Int, Int)? in
            page(name).map { ($0, right, bottom) }
        }
        let cornerSize = corners.first.map { $0.0.getBoxRect(.mediaBox).size } ?? .zero
        let w = min(cornerSize.width, body.width / 2), h = min(cornerSize.height, body.height / 2)
        for (piece, right, bottom) in corners {
            let rect = CGRect(x: right == 1 ? body.maxX - w : body.minX, y: bottom == 1 ? body.maxY - h : body.minY, width: w, height: h)
            Self.drawPage(piece, from: piece.getBoxRect(.mediaBox), to: rect, context: context)
        }
        let edges: [(String?, CGRect)] = [
            (images.top, CGRect(x: body.minX + w, y: body.minY, width: body.width - 2 * w, height: h)),
            (images.bottom, CGRect(x: body.minX + w, y: body.maxY - h, width: body.width - 2 * w, height: h)),
            (images.left, CGRect(x: body.minX, y: body.minY + h, width: w, height: body.height - 2 * h)),
            (images.right, CGRect(x: body.maxX - w, y: body.minY + h, width: w, height: body.height - 2 * h)),
        ]
        for (name, rect) in edges where rect.width > 0 && rect.height > 0 {
            if let piece = page(name) { Self.drawPage(piece, from: piece.getBoxRect(.mediaBox), to: rect, context: context) }
        }
        let inside = body.insetBy(dx: w, dy: h)
        if inside.width > 0, inside.height > 0 { context.fill(inside) }
    }

    func drawImage(named name: String, in rect: CGRect, context: CGContext) {
        guard let page = page(name) else { return }
        Self.drawPage(page, from: page.getBoxRect(.mediaBox), to: rect, context: context)
    }

    /// `source` (PDF space, y up) of `page` drawn into `target` (points, y down).
    static func drawPage(_ page: CGPDFPage, from source: CGRect, to target: CGRect, context: CGContext) {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return }
        context.saveGState()
        context.clip(to: target)
        let sx = target.width / source.width, sy = target.height / source.height
        context.translateBy(x: target.minX - source.minX * sx, y: target.minY + source.maxY * sy)
        context.scaleBy(x: sx, y: -sy)
        context.drawPDFPage(page)
        context.restoreGState()
    }

    /// Nine pieces of `page`: corners `caps` big as drawn, edges stretched along, the middle both ways.
    static func drawNineSlice(_ page: CGPDFPage, caps: (left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat), in target: CGRect, context: CGContext) {
        let box = page.getBoxRect(.mediaBox)
        let sourceX = [box.minX, box.minX + caps.left, box.maxX - caps.right, box.maxX]
        // PDF space runs up: the top row is the highest.
        let sourceY = [box.maxY, box.maxY - caps.top, box.minY + caps.bottom, box.minY]
        let targetX = [target.minX, target.minX + caps.left, target.maxX - caps.right, target.maxX]
        let targetY = [target.minY, target.minY + caps.top, target.maxY - caps.bottom, target.maxY]
        for row in 0..<3 {
            for column in 0..<3 {
                let source = CGRect(x: sourceX[column], y: sourceY[row + 1], width: sourceX[column + 1] - sourceX[column], height: sourceY[row] - sourceY[row + 1])
                let destination = CGRect(x: targetX[column], y: targetY[row], width: targetX[column + 1] - targetX[column], height: targetY[row + 1] - targetY[row])
                drawPage(page, from: source, to: destination, context: context)
            }
        }
    }
}
