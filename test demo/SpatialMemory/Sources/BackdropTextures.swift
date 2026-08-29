//
//  BackdropTextures.swift
//  SpatialMemory — making the backdrop fill the world instead of floating in it
//
//  A photograph reconstructed at its true field of view subtends about 63°.
//  A headset sees well past 100°. So a geometrically correct reconstruction is
//  a rectangle hanging in blackness — accurate, and not immersive.
//
//  The honest fix is not to stretch the photo past its real FOV, which would
//  wreck the perspective the whole pipeline exists to preserve. It is to stop
//  the frame from ending. Three textures do that:
//
//    padded     the photo, centred on a larger canvas whose border is a heavy
//               blur of the photo's own edges — so the frame dissolves outward
//               instead of stopping
//    vignette   an opacity ramp, solid across the photo and falling to zero at
//               the canvas rim, so there is no cut edge anywhere
//    ambient    a tiny, heavily darkened wash of the same photo, painted on a
//               large enclosing sphere so the periphery is lit by the memory's
//               own colours rather than by black
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum BackdropTextures {

    /// `@unchecked Sendable`: CGImage is an immutable CF value; see ImagingCore.swift.
    public struct Result: @unchecked Sendable {
        /// Opaque RGB. Sharp in the middle, blurred continuation in the border.
        public let padded: CGImage
        /// Grayscale opacity ramp, same dimensions as `padded`.
        public let vignette: CGImage
        /// Small, blurred, darkened wash for the surround sphere.
        public let ambient: CGImage
        /// How much larger `padded` is than the source, per axis. The mesh needs
        /// the same number or the texture will not line up.
        public let overscan: Float
    }

    /// - Parameters:
    ///   - overscan: canvas size as a multiple of the source. 1.0 disables
    ///     padding entirely (and with it the soft rim). 1.45 is a good balance:
    ///     enough border to dissolve into, not so much that the blurred region
    ///     dominates.
    ///   - ambientSide: long edge of the surround texture. Deliberately tiny —
    ///     it is stretched across a 14 m sphere, so bilinear filtering does the
    ///     smoothing for free and costs nothing to upload.
    ///   - ambientLevel: multiplier on the surround's brightness. Below ~0.5 it
    ///     reads as ambience; above that it competes with the photograph.
    public static func make(
        from background: CGImage,
        overscan: Float = 1.45,
        ambientSide: Int = 128,
        ambientLevel: CGFloat = 0.42
    ) throws -> Result {

        let w = CGFloat(background.width)
        let h = CGFloat(background.height)
        let ov = CGFloat(max(overscan, 1.0))

        let cw = (w * ov).rounded()
        let ch = (h * ov).rounded()
        let canvas = CGRect(x: 0, y: 0, width: cw, height: ch)
        let inset = CGRect(
            x: ((cw - w) / 2).rounded(),
            y: ((ch - h) / 2).rounded(),
            width: w,
            height: h
        )

        // Half-width of the border, in pixels. Everything below is expressed as
        // a fraction of this so behaviour is identical at any resolution.
        let pad = max(min(inset.origin.x, inset.origin.y), 1)

        let source = background.ci.normalizedToOrigin()
        let placed = source.transformed(
            by: CGAffineTransform(translationX: inset.origin.x, y: inset.origin.y)
        )

        // ---- padded --------------------------------------------------------
        // Clamp the photo's edge pixels across the whole canvas, blur them hard,
        // then drop the sharp photo back on top. The border becomes a plausible
        // out-of-focus continuation rather than a repeated smear.
        let surroundBlur = CIFilter.gaussianBlur()
        surroundBlur.inputImage = placed.clampedToExtent()
        surroundBlur.radius = Float(pad * 0.55)
        let surround = (surroundBlur.outputImage ?? placed).cropped(to: canvas)

        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = placed
        composite.backgroundImage = surround
        let paddedCI = (composite.outputImage ?? surround).cropped(to: canvas)

        // ---- vignette ------------------------------------------------------
        // A white rectangle, blurred. Blurring a FINITE rect over nothing gives
        // exactly a soft rectangular falloff, corners included, in one filter.
        //
        // The rect is grown halfway into the border first, and sigma is chosen
        // so 3σ ≈ the remaining half. The photograph therefore stays completely
        // opaque — a naive blur centred on the photo's own edge would eat
        // hundreds of pixels of real content into the fade.
        let solidRect = inset.insetBy(dx: -pad * 0.5, dy: -pad * 0.5)
        let solid = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: solidRect)

        let rampBlur = CIFilter.gaussianBlur()
        rampBlur.inputImage = solid
        rampBlur.radius = Float(pad * 0.16)          // 3σ ≈ 0.48 · pad
        let ramp = (rampBlur.outputImage ?? solid).cropped(to: canvas)

        // Flatten over black so the ramp lives in luminance as well as alpha —
        // an opacity texture is sampled as a scalar, not composited.
        let onBlack = CIFilter.sourceOverCompositing()
        onBlack.inputImage = ramp
        onBlack.backgroundImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: canvas)
        let vignetteCI = (onBlack.outputImage ?? ramp).cropped(to: canvas)

        // ---- ambient -------------------------------------------------------
        let scale = CGFloat(ambientSide) / max(w, h)
        let shrink = CIFilter.lanczosScaleTransform()
        shrink.inputImage = source
        shrink.scale = Float(scale)
        shrink.aspectRatio = 1
        let small = (shrink.outputImage ?? source).normalizedToOrigin()
        let smallExtent = small.extent

        let soften = CIFilter.gaussianBlur()
        soften.inputImage = small.clampedToExtent()
        soften.radius = Float(max(CGFloat(ambientSide) * 0.06, 1))
        let softened = (soften.outputImage ?? small).cropped(to: smallExtent)

        let dim = CIFilter.colorMatrix()
        dim.inputImage = softened
        dim.rVector = CIVector(x: ambientLevel, y: 0, z: 0, w: 0)
        dim.gVector = CIVector(x: 0, y: ambientLevel, z: 0, w: 0)
        dim.bVector = CIVector(x: 0, y: 0, z: ambientLevel, w: 0)
        dim.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        dim.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        let ambientCI = (dim.outputImage ?? softened).cropped(to: smallExtent)

        return Result(
            padded: try paddedCI.render(cropping: canvas),
            vignette: try vignetteCI.render(cropping: canvas),
            ambient: try ambientCI.render(cropping: smallExtent),
            overscan: Float(ov)
        )
    }
}
