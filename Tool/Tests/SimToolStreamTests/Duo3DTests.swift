import Metal
import SimToolCore
import XCTest
@testable import SimToolStream

final class AVCCEnvelopeReaderTests: XCTestCase {
    func testEnvelopesComeBackWholeHoweverTheBytesArrive() {
        let stream = AVCCEnvelope.description(avcc: Data([1, 2, 3])) + AVCCEnvelope.projection(json: Data(#"{"panel":"inner"}"#.utf8)) + AVCCEnvelope.keyframe(avcc: Data(repeating: 7, count: 40))
        var reader = AVCCEnvelopeReader()
        var envelopes: [AVCCEnvelopeReader.Envelope] = []
        for start in stride(from: 0, to: stream.count, by: 3) {
            envelopes += reader.push(stream.subdata(in: start..<min(stream.count, start + 3)))
        }
        XCTAssertEqual(envelopes.map(\.tag), [AVCCEnvelope.descriptionTag, AVCCEnvelope.projectionTag, AVCCEnvelope.keyframeTag])
        XCTAssertEqual(String(decoding: envelopes[1].payload, as: UTF8.self), #"{"panel":"inner"}"#)
        XCTAssertEqual(envelopes.reduce(Data()) { $0 + $1.bytes }, stream, "relayed as they came")
    }
}

/// Renders Xcode's own iPhone Duo model when the selected Xcode has one —
/// it is never part of SimTool — and checks the projection lands where the
/// picture does.
final class Duo3DRendererTests: XCTestCase {
    @MainActor
    func testTheProjectionLandsWhereThePanelsPictureIsDrawn() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("RealityKit renders offscreen from macOS 15") }
        let layout = SimulatorDisplayLayout(displays: [
            SimulatorDisplay(id: "primary", screenID: 1, role: "cover", width: 1398, height: 2034, scale: 3),
            SimulatorDisplay(id: "primary-1", screenID: 3, role: "inner", width: 2007, height: 2853, scale: 3),
        ], productClass: "V68")
        guard let model = Duo3DModel.locate(layout: layout, developerDir: DeveloperFrameworks.developerDir()).url else {
            throw XCTSkip("the selected Xcode has no iPhone Duo model")
        }
        let renderer = try await Duo3DRenderer(modelURL: model, dark: true, width: 400, height: 360)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // The inner panel's framebuffer: red on its top half, blue below.
        try renderer.show(try Self.halves(device: device, width: 2007, height: 2853), on: .inner)
        _ = try await renderer.render(hinge: 130, panel: .inner)
        let frame = try await renderer.render(hinge: 130, panel: .inner)
        XCTAssertEqual(frame.pieces.count, 2, "the inner panel folds across its middle")
        let pixels = try Self.read(frame.texture, device: device)
        for piece in frame.pieces {
            let region = piece[4]
            // The middle of each leaf: its framebuffer half's colour.
            let corners = piece.prefix(4)
            let x = corners.map { $0[0] }.reduce(0, +) / 4, y = corners.map { $0[1] }.reduce(0, +) / 4
            let (blue, green, red) = Self.pixel(pixels, x: x, y: y, width: frame.texture.width, height: frame.texture.height)
            if region[1] < 0.5 {
                XCTAssertGreaterThan(Int(red), Int(blue) + 60, "the top half is red: \(region)")
            } else {
                XCTAssertGreaterThan(Int(blue), Int(red) + 60, "the bottom half is blue: \(region)")
            }
            XCTAssertLessThan(green, 120)
        }
    }

    private static func halves(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let at = (row * width + column) * 4
                if row < height / 2 { bytes[at + 2] = 255 } else { bytes[at] = 255 }
                bytes[at + 3] = 255
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    private static func read(_ texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        descriptor.storageMode = .shared
        let copy = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        copy.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }

    /// BGRA at a frame fraction (Metal's rows run top-down).
    private static func pixel(_ bytes: [UInt8], x: Double, y: Double, width: Int, height: Int) -> (UInt8, UInt8, UInt8) {
        let column = min(width - 1, max(0, Int(x * Double(width))))
        let row = min(height - 1, max(0, Int(y * Double(height))))
        let at = (row * width + column) * 4
        return (bytes[at], bytes[at + 1], bytes[at + 2])
    }
}
