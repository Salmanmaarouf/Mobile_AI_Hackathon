//
//  ImmersiveSurround.swift
//  SpatialMemory — the room the photograph carries on into
//
//  ============================================================================
//  WHY THIS EXISTS
//
//  Apple's spatial scene solves the photograph. It does not solve the 40°-plus
//  of peripheral vision the photograph never covered: a phone camera sees about
//  63°, a headset shows past 100°, and the difference is black.
//
//  `MemoryAmbience.ambientSphere` fills that with a darkened blur of the photo.
//  Cheap, and it stops the void — but it is a wash, not content. This does the
//  other thing: pads the photograph onto a wider canvas and asks the filler to
//  CONTINUE it into the border, so walls, floor and furniture carry on past the
//  frame edge instead of dissolving.
//
//  It is the same operation `MemoryPipeline` already performs for its own
//  backdrop (`outpaintSurround`), lifted out so it can be used on its own —
//  because when Apple's renderer wins, the pipeline that owned it never runs.
//
//  LaMa is the right model for it. A border continuation with intact photograph
//  on the inner edge is the same shape of problem as a hole with context on
//  both sides, and LaMa has no text conditioning — so it cannot invent a person
//  into your periphery. That matters more here than anywhere: the periphery is
//  where you are least likely to look straight at it and most likely to believe
//  it.
//
//  GEOMETRY, because the number is easy to get wrong
//
//  Padding the canvas by N does NOT widen the field of view by N. The frame is
//  a rectilinear projection, so it is the TANGENT that scales:
//
//      tan(θ_wide / 2) = N · tan(θ_photo / 2)
//      θ_wide = 2 · atan( N · tan(θ_photo / 2) )
//
//  Worked: θ_photo = 63°, N = 2.6
//      tan(31.5°)          = 0.6128
//      2.6 × 0.6128        = 1.5933
//      atan(1.5933)        = 57.89°
//      θ_wide              = 115.8°
//
//  Taking the linear shortcut (63 × 2.6 = 164°) would size the plane nearly
//  half again too wide and the continuation would not line up with the photo it
//  is continuing.
//
//  Deliberately standalone, in the manner of `MemoryAmbience` and
//  `AppleSpatialScene`: nothing imports it, and deleting the file leaves
//  everything else exactly as it was.
//  ============================================================================
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import RealityKit
import simd

#if canImport(UIKit)
// `UnlitMaterial.BaseColor(tint:texture:)` takes a UIColor on visionOS, and
// this package builds with member-import visibility, so the tint needs UIKit
// imported here rather than inherited from RealityKit.
import UIKit
#endif

@MainActor
public enum ImmersiveSurround {

    public struct Options: Sendable {

        /// Canvas size as a multiple of the photograph, per axis. See the
        /// tangent relation above for what this does to the field of view:
        /// 2.0 ≈ 101°, 2.6 ≈ 116°, 4.0 ≈ 136° from a 63° source.
        ///
        /// Past roughly 3 the filler is inventing more of the frame than the
        /// camera caught, and the result depends entirely on there being
        /// continuable structure at the photograph's edges. A room continues
        /// well; a face against a blurred background does not.
        public var overscan: Float

        /// Metres from the viewer to the surround. Sits behind Apple's scene,
        /// which defaults to 2 m out.
        public var distance: Float

        /// The immersive space's origin is the floor, so this lifts the
        /// surround to eye height rather than centring it on the wearer's feet.
        public var eyeHeight: Float

        /// Brightness multiplier. The surround is peripheral and should stay
        /// there — at 1.0 it competes with the sharp scene in front of it.
        public var level: CGFloat

        /// Longest edge the photograph is reduced to before padding. The padded
        /// canvas is this times `overscan`, and that is what gets uploaded to
        /// the filler and turned into a texture — so it drives cost, latency
        /// and GPU memory together. 1280 × 2.6 ≈ a 3.3k canvas.
        public var sourceLongEdge: Int

        /// Width of the ramp between photograph and continuation, as a fraction
        /// of the canvas. Without it the seam is a rectangle the eye finds.
        public var feather: CGFloat

        public init(
            overscan: Float = 2.6,
            distance: Float = 6,
            eyeHeight: Float = 1.5,
            level: CGFloat = 0.78,
            sourceLongEdge: Int = 1280,
            feather: CGFloat = 0.012
        ) {
            self.overscan = max(overscan, 1.01)
            self.distance = max(distance, 0.5)
            self.eyeHeight = eyeHeight
            self.level = level
            self.sourceLongEdge = max(sourceLongEdge, 256)
            self.feather = feather
        }

        public static let `default` = Options()
    }

    // MARK: - Building

    /// Continues `image` outward with `filler` and returns a plane carrying the
    /// result, sized and placed so the photograph's own pixels land exactly
    /// where they would have without the padding.
    ///
    /// - Parameter sourceData: the original file bytes, for the EXIF field of
    ///   view. Without them the angle falls back to 63°, and a surround built
    ///   on the wrong FOV is subtly the wrong size — the continuation will not
    ///   sit flush against the photograph it continues.
    /// - Parameter prompt: passed through to the filler. LaMa ignores it; a
    ///   language-conditioned filler does not.
    public static func make(
        from image: CGImage,
        sourceData: Data? = nil,
        filler: any BackgroundFilling,
        prompt: String,
        options: Options = .default
    ) async throws -> Entity {

        // Reduce first. Everything downstream — the padded canvas, the upload,
        // the returned raster, the texture — is a multiple of this size, so
        // doing it here is what keeps a 12-megapixel photo from becoming a
        // 300-megapixel texture.
        let reduced = try fitted(image, longEdge: options.sourceLongEdge)

        let textures = try BackdropTextures.make(from: reduced, overscan: options.overscan)

        // The blurred border BackdropTextures produced is the fallback. If the
        // filler is unavailable or refuses, the surround is still built — a
        // blurred continuation beats a black void, and it beats no surround.
        var canvas = textures.padded
        if let ring = try? MemoryPipeline.overscanRingMask(
            canvas: textures.padded.size,
            overscan: CGFloat(textures.overscan),
            feather: options.feather
        ) {
            try Task.checkCancellation()
            if let painted = try? await filler.fill(
                plate: textures.padded,
                mask: ring,
                prompt: prompt
            ),
               let merged = try? MemoryPipeline.composite(
                   fill: painted,
                   over: textures.padded,
                   hole: ring
               ) {
                canvas = merged
            }
        }

        return try await plane(
            showing: canvas,
            photographFOV: sourceData.flatMap(ImageDecoder.horizontalFOV(fromEXIFIn:)),
            overscan: textures.overscan,
            options: options
        )
    }

    // MARK: - Geometry

    private static func plane(
        showing canvas: CGImage,
        photographFOV: Float?,
        overscan: Float,
        options: Options
    ) async throws -> Entity {

        // 63° ≈ a 28 mm-equivalent phone main camera, and the same default the
        // pipeline uses when EXIF carries no focal length.
        let photograph = photographFOV ?? (63.0 * .pi / 180.0)

        // The tangent relation from the header. Clamped below π so a large
        // overscan cannot produce a degenerate or reversed frustum.
        let widened = min(2 * atan(overscan * tan(photograph / 2)), .pi * 0.98)

        // `ParallaxLayout` owns this derivation — W = 2 · D · tan(θ/2), H = W /
        // aspect — so the size comes from there rather than being restated.
        // Its foreground layer is unused here; it only has to satisfy the
        // initializer's ordering precondition.
        let layout = ParallaxLayout(
            horizontalFOV: widened,
            aspect: Float(canvas.aspectRatio),
            backgroundDistance: options.distance,
            foregroundDistance: options.distance * 0.25
        )
        let size = layout.backgroundSize

        let texture = try await TextureFactory.make(
            canvas,
            name: "memory.surround.\(UUID().uuidString)",
            semantic: .color
        )

        var material = UnlitMaterial()
        material.color = .init(
            tint: UIColor(white: options.level, alpha: 1),
            texture: .init(texture)
        )
        material.blending = .opaque

        let entity = ModelEntity(
            mesh: .generatePlane(width: size.x, height: size.y),
            materials: [material]
        )
        entity.name = "MemoryImmersiveSurround"
        // generatePlane faces +Z, and the viewer looks down −Z, so no rotation.
        entity.position = [0, options.eyeHeight, -options.distance]
        return entity
    }

    // MARK: - Reduction

    /// Scales the long edge down to `longEdge`, preserving aspect. Returns the
    /// original when it is already small enough.
    private static func fitted(_ image: CGImage, longEdge: Int) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > longEdge else { return image }

        let scale = CGFloat(longEdge) / CGFloat(longest)
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image.ci
        f.scale = Float(scale)
        f.aspectRatio = 1

        guard let scaled = f.outputImage else { throw ImagingError.rasterizationFailed }
        let target = CGRect(
            x: 0,
            y: 0,
            width: (CGFloat(image.width) * scale).rounded(),
            height: (CGFloat(image.height) * scale).rounded()
        )
        return try scaled.normalizedToOrigin().render(cropping: target)
    }
}
