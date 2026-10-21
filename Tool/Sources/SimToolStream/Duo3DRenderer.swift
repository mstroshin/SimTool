import CoreGraphics
import Foundation
import Metal
import RealityKit
import simd

/// Renders an iPhone Duo in 3D from the device model the user's Xcode ships
/// (Device Hub's own `V68.usdz`, loaded at run time, never copied), folded to a
/// hinge angle, its screens textured with the live panels.
///
/// The model loading, the fold clip, the screen materials, the camera and the
/// screen projection follow serve-sim's `DuoRenderer` / `DuoScreenProjection`
/// (https://github.com/EvanBacon/serve-sim, Apache-2.0); see
/// THIRD_PARTY_NOTICES.md. The shell keeps the model's own Light or Dark
/// finish, lit by a generated studio environment instead of serve-sim's
/// private RealityKit lighting and Apple's material table.
@available(macOS 15.0, *)
@MainActor
public final class Duo3DRenderer {
    public enum Panel: String, Sendable { case cover, inner }

    public struct Frame {
        public var texture: MTLTexture
        /// Where each panel's picture lands on the frame: per leaf four corners
        /// (normalized frame coordinates, top-left origin) and the part of the
        /// panel's framebuffer it shows, `[x, y, w, h]`.
        public var pieces: [[[Double]]]
    }

    public static let coverMaterial = "YqugYDOqMSOpqyA"
    public static let innerMaterial = "CvyXbAGXoolRUYl"
    public static let foldClip = "l_over_r"

    public let width: Int
    public let height: Int
    private let renderer: RealityRenderer
    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private let wrapper = Entity()
    private let rest = Entity()
    private let subject: Entity
    private let controller: AnimationPlaybackController
    private let flatBounds: BoundingBox
    private let cameraDistance: Float
    private let fieldOfView: Float = 2 * atan(36 / (2 * 200.0)) * 180 / .pi
    private let output: MTLTexture
    private let cameraOutput: RealityRenderer.CameraOutput
    private var screens: [Panel: (model: ModelEntity, index: Int)] = [:]
    private var textures: [Panel: LowLevelTexture] = [:]
    private let projections: [Panel: Duo3DScreenProjection]
    private var lastAngle = Double.nan

    public init(modelURL: URL, dark: Bool, width: Int = 1200, height: Int = 1080) async throws {
        // RealityKit's engine must be made on the main actor, before the
        // catalog's nonisolated load runs.
        renderer = try RealityRenderer()
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue() else {
            throw Duo3DError("No Metal device to render the 3D preview on")
        }
        self.device = device
        self.commands = commands
        self.width = width
        self.height = height
        let catalog = try await Entity.ConfigurationCatalog(from: modelURL)
        let loaded = try await Entity(from: catalog, configurations: ["color": dark ? "Dark" : "Light"])
        subject = loaded.findEntity(named: "root") ?? loaded
        guard let clip = subject.availableAnimations.first(where: { $0.name == Self.foldClip && $0.definition.duration.isFinite }) else {
            throw Duo3DError("The device model has no fold animation (\(Self.foldClip))")
        }
        guard let cover = Self.screen(in: subject, named: Self.coverMaterial), let inner = Self.screen(in: subject, named: Self.innerMaterial) else {
            throw Duo3DError("The device model has no screen materials")
        }
        screens = [.cover: cover, .inner: inner]
        // The inner panel's framebuffer is portrait under a landscape picture:
        // its screen's texture coordinates are turned a quarter to match.
        try Self.turnTexture(on: inner.0, material: inner.1)
        projections = [
            .cover: try Duo3DScreenProjection(model: cover.0, material: cover.1, leaves: [SIMD4(0, 0, 1, 1)]),
            .inner: try Duo3DScreenProjection(model: inner.0, material: inner.1, leaves: [SIMD4(0, 0.5, 1, 0.5), SIMD4(0, 0, 1, 0.5)]),
        ]
        subject.removeFromParent()
        rest.addChild(subject)
        wrapper.addChild(rest)
        rest.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        subject.position -= subject.visualBounds(relativeTo: rest).center
        flatBounds = subject.visualBounds(relativeTo: wrapper)
        cameraDistance = max(flatBounds.extents.x, flatBounds.extents.y) * 1.8 * tan(35 * .pi / 360) / tan(fieldOfView * .pi / 360)
        renderer.entities.append(wrapper)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = fieldOfView
        camera.camera.near = 0.001
        camera.camera.far = 10000
        camera.position = [0, 0, cameraDistance]
        renderer.entities.append(camera)
        renderer.activeCamera = camera
        renderer.lighting.resource = try await EnvironmentResource(equirectangular: Self.studio())
        renderer.cameraSettings.antialiasing = .none
        renderer.cameraSettings.colorBackground = .color(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let output = device.makeTexture(descriptor: descriptor) else { throw Duo3DError("Cannot allocate the 3D frame") }
        self.output = output
        cameraOutput = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: output))
        controller = subject.playAnimation(clip, transitionDuration: 0, startsPaused: true)
        for panel in [Panel.cover, .inner] { blank(panel) }
    }

    /// Shows a panel's live picture: `source` is its framebuffer, as an sRGB
    /// BGRA texture. Copied on the GPU into the screen's texture.
    public func show(_ source: MTLTexture, on panel: Panel) throws {
        let texture = try lowLevelTexture(for: panel, width: source.width, height: source.height)
        guard let buffer = commands.makeCommandBuffer() else { return }
        let target = texture.replace(using: buffer)
        guard let blit = buffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, to: target)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilScheduled()
    }

    /// A panel that is off: black glass.
    public func blank(_ panel: Panel) {
        guard let (model, index) = screens[panel] else { return }
        textures[panel] = nil
        var material = UnlitMaterial(color: .black)
        material.color = .init(tint: .black)
        model.model?.materials[index] = material
    }

    /// The device folded to `hinge` degrees (0 closed, 180 open), seen square
    /// on: an open device faces the camera with both leaves, a closed one with
    /// its cover. `panel` is the lit one, whose picture the frame's pieces map.
    public func render(hinge: Double, panel: Panel, roll: Double = 0) async throws -> Frame {
        let angle = min(180, max(0, hinge))
        let raise = Float((180 - angle) * .pi / 180)
        let yaw = simd_quatf(angle: -min(raise, Float(angle * .pi / 180)) / 2, axis: [0, 1, 0])
        controller.time = (180 - angle) / 180 * 5
        rest.orientation = yaw * simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        wrapper.orientation = simd_quatf(angle: Float(roll * .pi / 180), axis: [0, 0, 1])
        let fold = simd_quatf(angle: raise, axis: [0, 1, 0])
        let half = flatBounds.extents.x / 2
        let xs = [fold.act([-half, 0, 0]), SIMD3<Float>(0, 0, 0), [half, 0, 0]].map { yaw.act($0).x }
        rest.position.x = -((xs.min() ?? 0) + (xs.max() ?? 0)) / 2
        // Skinning settles an update after the clip's time moves.
        let passes = lastAngle == angle ? 1 : 2
        lastAngle = angle
        for _ in 0..<passes {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try renderer.updateAndRender(deltaTime: 1 / 60, cameraOutput: cameraOutput, onComplete: { _ in continuation.resume() })
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let pieces = projections[panel]?.pieces(cameraDistance: cameraDistance, fieldOfView: fieldOfView, aspect: Float(width) / Float(height)) ?? []
        return Frame(texture: output, pieces: pieces)
    }

    private func lowLevelTexture(for panel: Panel, width: Int, height: Int) throws -> LowLevelTexture {
        if let texture = textures[panel], texture.descriptor.width == width, texture.descriptor.height == height { return texture }
        guard let (model, index) = screens[panel] else { throw Duo3DError("No \(panel) screen in the model") }
        let texture = try LowLevelTexture(descriptor: .init(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, depth: 1, mipmapLevelCount: 1, textureUsage: [.shaderRead, .shaderWrite]))
        let resource = try TextureResource(from: texture)
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(resource))
        model.model?.materials[index] = material
        textures[panel] = texture
        return texture
    }

    private static func screen(in entity: Entity, named name: String) -> (ModelEntity, Int)? {
        if let model = entity as? ModelEntity, let index = model.model?.materials.firstIndex(where: { $0.name == name }) { return (model, index) }
        for child in entity.children { if let found = screen(in: child, named: name) { return found } }
        return nil
    }

    private static func turnTexture(on entity: ModelEntity, material: Int) throws {
        guard let model = entity.model else { return }
        var contents = model.mesh.contents
        contents.models = .init(contents.models.map { mesh in
            var mesh = mesh
            mesh.parts = .init(mesh.parts.map { part in
                guard part.materialIndex == material, let coordinates = part.textureCoordinates else { return part }
                var part = part
                part.textureCoordinates = .init(coordinates.elements.map { SIMD2<Float>(1 - $0.y, $0.x) })
                return part
            })
            return mesh
        })
        try model.mesh.replace(with: contents)
        entity.model = model
    }

    /// A soft studio: a bright sky over a darker floor, for the shell to catch.
    private static func studio() throws -> CGImage {
        let width = 256, height = 128
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
                  CGColor(gray: 1.0, alpha: 1), CGColor(gray: 0.75, alpha: 1), CGColor(gray: 0.25, alpha: 1), CGColor(gray: 0.1, alpha: 1),
              ] as CFArray, locations: [0, 0.35, 0.6, 1]) else { throw Duo3DError("Cannot draw the 3D lighting") }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
        guard let image = context.makeImage() else { throw Duo3DError("Cannot draw the 3D lighting") }
        return image
    }

    private static func blackImage() throws -> CGImage {
        guard let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Duo3DError("Cannot make a blank screen")
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        guard let image = context.makeImage() else { throw Duo3DError("Cannot make a blank screen") }
        return image
    }
}

/// A sample of a screen's surface on the model, skinned as the model folds,
/// projected to find where each leaf of the panel lands on the frame.
/// Follows serve-sim's `DuoScreenProjection` (Apache-2.0).
@available(macOS 15.0, *)
@MainActor
final class Duo3DScreenProjection {
    private struct Sample {
        let position: SIMD3<Float>
        let uv: SIMD2<Float>
        let influences: [MeshJointInfluence]
    }

    private struct Leaf {
        let samples: [Sample]
        let region: SIMD4<Float>
    }

    private let entity: ModelEntity
    private let joints: [MeshResource.Skeleton.Joint]
    private let jointIndices: [Int?]
    private let leaves: [Leaf]

    /// `leaves` split the panel's framebuffer — the inner panel folds across
    /// its middle — as `[x, y, w, h]` regions.
    init(model: ModelEntity, material: Int, leaves regions: [SIMD4<Float>]) throws {
        entity = model
        let contents = model.model!.mesh.contents
        guard let part = contents.models.flatMap({ Array($0.parts) }).first(where: { $0.materialIndex == material }),
              let coordinates = part.textureCoordinates,
              let skeletonID = part.skeletonID, let skeleton = contents.skeletons[skeletonID],
              let influences = part.jointInfluences else { throw Duo3DError("The screen has no skinned surface to project") }
        joints = skeleton.joints
        jointIndices = skeleton.joints.map { model.jointNames.firstIndex(of: $0.name) }
        let positions = Array(part.positions.elements), uvs = Array(coordinates.elements)
        let weights = Array(influences.influences.elements)
        let count = weights.count / max(1, positions.count)
        let samples = positions.indices.map { index in
            Sample(position: positions[index], uv: SIMD2(uvs[index].x, 1 - uvs[index].y), influences: Array(weights[(index * count)..<((index + 1) * count)]))
        }
        let split = regions.count > 1
        leaves = try regions.map { region in
            let candidates = split ? samples.filter { $0.uv.y > region.y + 0.02 && $0.uv.y < region.y + region.w - 0.02 } : samples
            let targets = [SIMD2<Float>(0.15, 0.2), SIMD2<Float>(0.85, 0.2), SIMD2<Float>(0.15, 0.8)]
            let picked = targets.compactMap { target in
                let uv = SIMD2(target.x, region.y + target.y * region.w)
                return candidates.min { simd_distance_squared($0.uv, uv) < simd_distance_squared($1.uv, uv) }
            }
            guard picked.count == 3 else { throw Duo3DError("The screen has too few points to project") }
            let u = picked[1].uv - picked[0].uv, v = picked[2].uv - picked[0].uv
            guard abs(u.x * v.y - u.y * v.x) > 0.000001 else { throw Duo3DError("The screen's points are degenerate") }
            return Leaf(samples: picked, region: region)
        }
    }

    func pieces(cameraDistance: Float, fieldOfView: Float, aspect: Float) -> [[[Double]]] {
        let transforms = entity.jointTransforms
        var global = [simd_float4x4](repeating: matrix_identity_float4x4, count: joints.count)
        for index in joints.indices {
            let local = jointIndices[index].flatMap { $0 < transforms.count ? transforms[$0].matrix : nil } ?? joints[index].restPoseTransform.matrix
            global[index] = joints[index].parentIndex.map { global[$0] * local } ?? local
        }
        let skin = joints.indices.map { global[$0] * joints[$0].inverseBindPoseMatrix }
        let world = entity.transformMatrix(relativeTo: nil)
        func position(_ sample: Sample) -> SIMD3<Float> {
            var point = SIMD4<Float>(repeating: 0)
            for influence in sample.influences where influence.weight > 0 {
                point += (skin[influence.jointIndex] * SIMD4(sample.position, 1)) * influence.weight
            }
            let p = world * point
            return SIMD3(p.x, p.y, p.z)
        }
        let scale: Float = 1 / tan(fieldOfView * .pi / 360)
        return leaves.map { leaf in
            let s = leaf.samples, a = position(s[0]), b = position(s[1]), c = position(s[2])
            let u = s[1].uv - s[0].uv, v = s[2].uv - s[0].uv
            let determinant = u.x * v.y - u.y * v.x
            func project(_ uv: SIMD2<Float>) -> [Double] {
                let delta = uv - s[0].uv
                let point = a + (b - a) * ((delta.x * v.y - delta.y * v.x) / determinant) + (c - a) * ((u.x * delta.y - u.y * delta.x) / determinant)
                let depth = max(0.001, cameraDistance - point.z)
                return [Double(0.5 + point.x * scale / depth / aspect / 2), Double(0.5 - point.y * scale / depth / 2)]
            }
            let r = leaf.region
            return [project(SIMD2(r.x, r.y)), project(SIMD2(r.x + r.z, r.y)), project(SIMD2(r.x + r.z, r.y + r.w)), project(SIMD2(r.x, r.y + r.w)), [Double(r.x), Double(r.y), Double(r.z), Double(r.w)]]
        }
    }
}

public struct Duo3DError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
