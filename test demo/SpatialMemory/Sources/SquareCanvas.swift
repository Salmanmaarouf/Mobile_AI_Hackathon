//
//  SquareCanvas.swift
//  SpatialMemory — PHASE 2a: Aspect-preserving square projection
//
//  The edits endpoint demands a square PNG. Centre-cropping to square would
//  throw away the parts of the frame the user actually wants to look around in,
//  so we letterbox instead and mark the pad bars as "do not edit" in the mask.
//  After the round trip we crop the pad back off and restore the source aspect.
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public struct SquareCanvas: Sendable {

    /// Side length of the square working canvas, in pixels.
    public let side: CGFloat
    /// Pixel dimensions of the original frame.
    public let sourceSize: CGSize
    /// Uniform scale that maps source pixels onto canvas pixels.
    public let scale: CGFloat
    /// Where the scaled frame sits inside the square (Core Image bottom-left origin).
    public let inset: CGRect

    public init(sourceSize: CGSize, side: Int) {
        precondition(sourceSize.width > 0 && sourceSize.height > 0, "degenerate source size")
        let s = CGFloat(side)
        self.side = s
        self.sourceSize = sourceSize

        // Aspect-FIT (not fill): the whole frame survives, bars appear on the
        // short axis.
        self.scale = min(s / sourceSize.width, s / sourceSize.height)

        let w = (sourceSize.width * scale).rounded()
        let h = (sourceSize.height * scale).rounded()
        self.inset = CGRect(
            x: ((s - w) / 2).rounded(),
            y: ((s - h) / 2).rounded(),
            width: w,
            height: h
        )
    }

    public var squareExtent: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }

    /// How the pad region outside `inset` is filled.
    public enum Pad {
        /// Repeat the frame's edge pixels outward. Gives the model plausible
        /// context in the bars instead of a hard black seam that it would try to
        /// "explain" by bending the scene.
        case clampEdges
        /// Opaque black. Correct for the *mask* upload: alpha 1 == do not edit.
        case opaqueBlack
        /// Transparent. Only useful if you deliberately want the model to invent
        /// content in the bars too (an outpainting effect).
        case clear
    }

    // MARK: - Forward projection (source space -> square canvas)

    public func project(_ image: CGImage, pad: Pad) -> CIImage {
        project(image.ci, pad: pad)
    }

    public func project(_ image: CIImage, pad: Pad) -> CIImage {
        let placed = image
            .normalizedToOrigin()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .normalizedToOrigin()
            .transformed(by: CGAffineTransform(translationX: inset.origin.x,
                                               y: inset.origin.y))

        let backdrop: CIImage
        switch pad {
        case .clampEdges:
            // Clamp BEFORE the crop so the edge pixels tile outward across the
            // whole square, then let the placed image sit on top of it.
            backdrop = placed.clampedToExtent().cropped(to: squareExtent)
        case .opaqueBlack:
            backdrop = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
                .cropped(to: squareExtent)
        case .clear:
            backdrop = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: squareExtent)
        }

        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = placed
        composite.backgroundImage = backdrop
        return (composite.outputImage ?? placed).cropped(to: squareExtent)
    }

    // MARK: - Inverse projection (square canvas -> source space)

    /// Crops the pad bars away and rescales back to the original pixel size.
    ///
    /// `returnedSide` is the side of the image the API actually gave us back,
    /// which may differ from `side` if the encoder had to step down the ladder
    /// to satisfy the byte budget.
    public func unproject(_ square: CGImage, returnedSide: CGFloat? = nil) throws -> CGImage {
        let actual = returnedSide ?? CGFloat(square.width)

        // Ratio between what came back and the canvas we authored `inset` against.
        let k = actual / side
        let cropRect = CGRect(
            x: (inset.origin.x * k).rounded(),
            y: (inset.origin.y * k).rounded(),
            width: (inset.width * k).rounded(),
            height: (inset.height * k).rounded()
        )

        let cropped = square.ci
            .cropped(to: cropRect)
            .normalizedToOrigin()

        // Lanczos back up (or down) to the exact source pixel grid.
        let sx = sourceSize.width / cropRect.width
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = cropped
        f.scale = Float(sx)
        // aspectRatio multiplies the Y scale relative to X. Our crop preserved
        // the source aspect, so this is 1 — but compute it rather than assume,
        // because rounding above can leave a sub-pixel discrepancy.
        let sy = sourceSize.height / cropRect.height
        f.aspectRatio = Float(sy / sx)

        guard let scaled = f.outputImage else { throw ImagingError.rasterizationFailed }
        return try scaled
            .normalizedToOrigin()
            .render(cropping: CGRect(origin: .zero, size: sourceSize))
    }
}
