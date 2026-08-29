//
//  DepthMesh.swift
//  SpatialMemory — the geometry that makes it a place instead of a cutout
//
//  A grid displaced along view rays by a depth map. Every pixel sits at its own
//  distance, so the whole frame has relief rather than one silhouette sliding
//  over a backdrop.
//
//  THE PART THAT MATTERS: triangles spanning a large depth jump are DROPPED.
//  Without that, the mesh stretches between the subject's edge and the wall
//  behind them, and leaning sideways pulls the person into taffy. Dropping them
//  tears the mesh at exactly the silhouettes — and the holes are what the
//  inpainted backdrop is for. That is the whole trick of layered depth imaging,
//  and it is four lines.
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import RealityKit
import simd

public enum DepthMeshError: LocalizedError {
    case degenerate

    public var errorDescription: String? {
        switch self {
        case .degenerate:
            return "Every triangle spanned a depth discontinuity; nothing left to draw."
        }
    }
}

public enum DepthMesh {

    /// Builds the displaced, torn mesh.
    ///
    /// - Parameters:
    ///   - nearDistance: metres from the viewer at depth 0.
    ///   - farDistance: metres at depth 1. Keep it inside the backdrop's radius
    ///     or the far surfaces will punch through it.
    ///   - tearThreshold: normalized depth difference above which a triangle is
    ///     discarded, EXPRESSED AT A 192-CELL GRID and rescaled to whatever grid
    ///     actually arrives. Lower tears more eagerly — cleaner silhouettes, more
    ///     holes for the backdrop to fill. 0.15 is the working default and
    ///     matches `MemoryContainerOptions.tearThreshold`.
    ///
    ///     The rescaling is not a nicety. A tear fires on the depth step between
    ///     two adjacent cells, so spreading the same silhouette over twice as
    ///     many cells halves every step. Hold the threshold fixed and raise the
    ///     grid from 192 to 384 and the mesh stops tearing ENTIRELY — the
    ///     subject smears into the wall behind them and nothing in the code
    ///     looks wrong. Anchoring the number to a reference grid means it keeps
    ///     meaning what it meant when you tuned it.
    /// Which cells a layer is allowed to draw.
    public enum Coverage: Sendable, Equatable {
        /// Everything. The background layer, which must be a continuous surface
        /// with no holes — it is what the foreground's holes look through to.
        case whole
        /// Only cells nearer than the threshold. The foreground layer: the
        /// people and the objects in front, and nothing else.
        case nearerThan(Float)

        func admits(_ d: Float) -> Bool {
            switch self {
            case .whole:                 return true
            case let .nearerThan(limit): return d < limit
            }
        }
    }

    /// - Parameters:
    ///   - contourThreshold: depth contour that must never be spanned by a
    ///     triangle, whatever `tearThreshold` says. Pass the same value the
    ///     near-field matte was cut at and every foreground object gets a
    ///     complete, closed tear around it.
    ///
    ///     This exists because a gradient test alone is at the mercy of the
    ///     guide. `GuidedDepthRefinement` sharpens the depth edge by snapping it
    ///     to a luminance edge, and where there is no luminance edge — black
    ///     hair against a dark panel — it has nothing to snap to, so the depth
    ///     stays soft, the gradient stays under the threshold, and that stretch
    ///     of the outline does not tear while its neighbours do. The result is
    ///     the hair-like fringe of spikes, not a cut. A contour test does not
    ///     care about contrast: either the two ends of the triangle are on
    ///     opposite sides of the near/far decision or they are not.
    ///   - coverage: restricts which cells this layer draws at all.
    @MainActor
    public static func generate(
        depth: DepthMap,
        layout: ParallaxLayout,
        nearDistance: Float,
        farDistance: Float,
        tearThreshold: Float = 0.15,
        contourThreshold: Float? = nil,
        coverage: Coverage = .whole
    ) throws -> MeshResource {

        let w = depth.width
        let h = depth.height
        precondition(w > 1 && h > 1, "depth map too small to mesh")

        // See the note on `tearThreshold`: the parameter is quoted at a 192-cell
        // long edge, and one cell's share of a silhouette shrinks as the grid
        // grows.
        let effectiveTear = tearThreshold * (Self.referenceGrid / Float(max(w, h)))

        let tanH = tan(layout.horizontalFOV / 2)
        let tanV = tan(layout.verticalFOV / 2)
        let span = farDistance - nearDistance

        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var uvs = [SIMD2<Float>]()
        positions.reserveCapacity(w * h)
        normals.reserveCapacity(w * h)
        uvs.reserveCapacity(w * h)

        for y in 0..<h {
            let tv = Float(y) / Float(h - 1)
            let ndcY = (0.5 - tv) * 2          // +1 at the top row
            for x in 0..<w {
                let tu = Float(x) / Float(w - 1)
                let ndcX = (tu - 0.5) * 2      // −1 at the left column

                let d = nearDistance + span * depth.value(x: x, y: y)

                // Straight pinhole inversion, not a radial placement. A point at
                // image position (ndcX, ndcY) and z-depth d sits at
                //     (ndcX · tanH · d,  ndcY · tanV · d,  −d)
                // which guarantees that from the origin the displaced mesh
                // projects EXACTLY onto the original photograph, whatever the
                // depth map says. Get this wrong and the image warps as soon as
                // there is any relief at all.
                positions.append(SIMD3(ndcX * tanH * d, ndcY * tanV * d, -d))

                // Unlit ignores normals; a lit material swapped in later will not.
                let p = SIMD3<Float>(ndcX * tanH, ndcY * tanV, -1)
                normals.append(-simd_normalize(p))

                // v flipped: RealityKit's meshes put v = 0 at the bottom.
                uvs.append(SIMD2(tu, 1 - tv))
            }
        }

        // ------------------------------------------------------------------
        // Index buffer, with tearing.
        //
        // Winding [a, c, b] / [b, c, d] is counter-clockwise as seen from the
        // origin — the same derivation as the backdrop in ParallaxGeometry.
        // ------------------------------------------------------------------
        var indices = [UInt32]()
        indices.reserveCapacity(w * h * 6)

        for y in 0..<(h - 1) {
            for x in 0..<(w - 1) {
                let d00 = depth.value(x: x,     y: y)
                let d10 = depth.value(x: x + 1, y: y)
                let d01 = depth.value(x: x,     y: y + 1)
                let d11 = depth.value(x: x + 1, y: y + 1)

                let a = UInt32(y * w + x)
                let b = a + 1
                let c = a + UInt32(w)
                let e = c + 1

                // Each triangle is judged on its own, so a quad straddling a
                // silhouette can keep the half that lies on solid ground.
                if admits(d00, d01, d10, coverage, effectiveTear, contourThreshold) {
                    indices.append(contentsOf: [a, c, b])
                }
                if admits(d10, d01, d11, coverage, effectiveTear, contourThreshold) {
                    indices.append(contentsOf: [b, c, e])
                }
            }
        }

        guard indices.isEmpty == false else { throw DepthMeshError.degenerate }

        var descriptor = MeshDescriptor(name: "SpatialMemoryDepthMesh")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(from: [descriptor])
    }

    /// The grid the `tearThreshold` parameter is quoted against.
    static let referenceGrid: Float = 192

    /// Every reason a triangle survives, in one place.
    @inline(__always)
    static func admits(
        _ a: Float, _ b: Float, _ c: Float,
        _ coverage: Coverage,
        _ tear: Float,
        _ contour: Float?
    ) -> Bool {
        // 1. the layer has to own all three corners
        guard coverage.admits(a), coverage.admits(b), coverage.admits(c) else { return false }
        // 2. no triangle may span the near/far contour, at any contrast
        if let contour {
            let near = (a < contour, b < contour, c < contour)
            if !(near.0 == near.1 && near.1 == near.2) { return false }
        }
        // 3. and no triangle may span a depth cliff
        return maxSpread(a, b, c) <= tear
    }

    @inline(__always)
    static func maxSpread(_ a: Float, _ b: Float, _ c: Float) -> Float {
        max(a, max(b, c)) - min(a, min(b, c))
    }

    // MARK: - Deriving the inpainting mask from depth

    /// Everything nearer than `threshold`, grown outward, as a full-resolution
    /// matte.
    ///
    /// This replaces the segmentation mask when depth is available, and it is
    /// strictly better for this job: what needs inventing behind the subject is
    /// whatever the near geometry occludes, which is a depth question, not a
    /// "which pixels are a person" question. It also works in the simulator,
    /// where Vision does not.
    ///
    /// - Parameters:
    ///   - threshold: normalized depth below which a pixel counts as near.
    ///   - dilation: how far to grow the region, as a fraction of the long edge.
    ///     The hole must be a little larger than the subject or the fill leaves
    ///     a rim of the subject's own colour around them.
    public static func nearFieldMatte(
        depth: DepthMap,
        matching size: CGSize,
        threshold: Float = 0.42,
        dilation: CGFloat = 0.012,
        feather: CGFloat = 0.008
    ) throws -> CGImage {

        let w = depth.width, h = depth.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            bytes[i] = depth.values[i] < threshold ? 255 : 0
        }

        // CGBitmapContext rows run top-down, and DepthMap is top-left origin, so
        // writing straight through preserves orientation.
        let gray = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &bytes,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: gray,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let small = context.makeImage() else {
            throw ImagingError.rasterizationFailed
        }

        let extent = CGRect(origin: .zero, size: size)
        let longEdge = max(size.width, size.height)

        // Up to full resolution.
        let up = CIFilter.lanczosScaleTransform()
        up.inputImage = small.ci
        up.scale = Float(size.width / CGFloat(w))
        up.aspectRatio = Float((size.height / CGFloat(h)) / (size.width / CGFloat(w)))
        var matte = (up.outputImage ?? small.ci).normalizedToOrigin().cropped(to: extent)

        matte = MaskAlgebra.splatRedToAllChannels(matte)

        // Grow, then soften. Opposite order to the segmentation chain, and on
        // purpose: there we shrank to avoid a halo of background colour, here we
        // grow so the fill has room to work behind the subject's edge.
        if dilation > 0 {
            let grow = CIFilter.morphologyMaximum()
            grow.inputImage = matte.clampedToExtent()
            grow.radius = Float(longEdge * dilation)
            matte = (grow.outputImage ?? matte).cropped(to: extent)
        }
        if feather > 0 {
            let soften = CIFilter.gaussianBlur()
            soften.inputImage = matte.clampedToExtent()
            soften.radius = Float(longEdge * feather)
            matte = (soften.outputImage ?? matte).cropped(to: extent)
        }

        return try matte.render(cropping: extent)
    }

    /// The ribbon of background that a moving viewer actually uncovers, as an
    /// inpainting mask.
    ///
    /// ============================================================================
    /// This is the difference between asking a model for something it is good at
    /// and asking it for something nothing is good at.
    ///
    /// `nearFieldMatte` marks the WHOLE near field. On a group photo that is
    /// most of the frame, and handing LaMa a mask that size asks it to invent an
    /// entire room from a thin border of surviving pixels. Its honest answer to
    /// a request with no context is smooth low-frequency colour — which arrives
    /// looking like flat grey shapes in the silhouettes of the people removed.
    /// No error, no failure, exactly what the model does when the mask is too
    /// big: there is nothing to continue.
    ///
    /// But almost none of that region is ever seen. Occlusion is only revealed
    /// at the EDGES of near geometry, and only as far as the viewer's parallax
    /// carries them. For a head movement `d`, the background slides against the
    /// foreground by
    ///
    ///     disparity_px ≈ f_px · d · (1/Z_near − 1/Z_far)
    ///
    /// At a 63° lens with layers at 1.5 m and 5 m, on a 1024 px upload:
    ///
    ///      5 cm lean →  19 px →  1.9% of the width
    ///     10 cm lean →  39 px →  3.8%
    ///     20 cm lean →  78 px →  7.6%
    ///
    /// Everything deeper inside a person's outline than that stays hidden behind
    /// them no matter how the viewer moves. Asking for it is asking a model to
    /// invent a room nobody will ever look at, at the cost of the part they
    /// will.
    ///
    /// The width matters more than it looks, because a ribbon around a large
    /// subject is not much smaller than the subject. Measured against five
    /// people filling a 1024 × 890 frame:
    ///
    ///     band 0.08  →  mask shrinks 30%   (still a blob; still grey)
    ///     band 0.05  →  mask shrinks 52%
    ///     band 0.04  →  mask shrinks 61%   ← default, ≈ a 10 cm lean
    ///     band 0.03  →  mask shrinks 70%
    ///
    /// 0.04 is the default because "look around" is a seated head movement, not
    /// a walk. Widen it if leaning further reveals the subject's own pixels
    /// behind their edge; narrow it if the fill still comes back featureless.
    ///
    /// So the mask becomes a ribbon tracing each silhouette. The model gets
    /// context on both sides of a narrow gap, which is precisely the regime LaMa
    /// was built for and where it holds straight edges across the hole.
    /// ============================================================================
    ///
    /// - Parameters:
    ///   - bandFraction: ribbon width as a fraction of the long edge. Derive it
    ///     from the formula above if you change the layer distances; wider costs
    ///     the model context, narrower shows the subject's own pixels behind
    ///     their edge when the viewer leans further than you budgeted for.
    ///   - outerFraction: how far the ribbon also extends OUTSIDE the silhouette,
    ///     so the seam between model and photograph never lands exactly on the
    ///     edge the eye is already drawn to.
    public static func occlusionBand(
        depth: DepthMap,
        matching size: CGSize,
        threshold: Float = 0.42,
        bandFraction: CGFloat = 0.04,
        outerFraction: CGFloat = 0.012,
        feather: CGFloat = 0.006
    ) throws -> CGImage {

        let w = depth.width, h = depth.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            bytes[i] = depth.values[i] < threshold ? 255 : 0
        }

        let gray = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &bytes,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: gray,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let small = context.makeImage() else {
            throw ImagingError.rasterizationFailed
        }

        let extent = CGRect(origin: .zero, size: size)
        let longEdge = max(size.width, size.height)

        let up = CIFilter.lanczosScaleTransform()
        up.inputImage = small.ci
        up.scale = Float(size.width / CGFloat(w))
        up.aspectRatio = Float((size.height / CGFloat(h)) / (size.width / CGFloat(w)))
        var field = (up.outputImage ?? small.ci).normalizedToOrigin().cropped(to: extent)
        field = MaskAlgebra.splatRedToAllChannels(field)

        // Outer boundary: the silhouette, grown a little.
        var outer = field
        if outerFraction > 0 {
            let grow = CIFilter.morphologyMaximum()
            grow.inputImage = field.clampedToExtent()
            grow.radius = Float(longEdge * outerFraction)
            outer = (grow.outputImage ?? field).cropped(to: extent)
        }

        // Inner boundary: the silhouette, shrunk by the parallax budget. What is
        // still inside after that erosion is never uncovered, so it is not asked
        // for.
        let shrink = CIFilter.morphologyMinimum()
        shrink.inputImage = field.clampedToExtent()
        shrink.radius = Float(longEdge * bandFraction)
        let inner = (shrink.outputImage ?? field).cropped(to: extent)

        // ribbon = outer AND NOT inner
        var band = MatteCompositor.blend(
            input: outer,
            background: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: extent),
            mask: MaskAlgebra.invert(inner).cropped(to: extent),
            extent: extent
        )

        if feather > 0 {
            let soften = CIFilter.gaussianBlur()
            soften.inputImage = band.clampedToExtent()
            soften.radius = Float(longEdge * feather)
            band = (soften.outputImage ?? band).cropped(to: extent)
        }

        // Into the project's mask convention: black RGB, alpha 0 over the gap.
        let asMask = MaskAlgebra.inpaintAlphaMask(fromMatte: band).cropped(to: extent)
        return try asMask.render(cropping: extent)
    }

    /// Everything DEEPER inside the near field than the occlusion ribbon — the
    /// part of a subject's footprint that parallax never uncovers.
    ///
    /// The counterpart to `occlusionBand`, and it exists because asking the
    /// model for less created a new problem. If the ribbon is all that gets
    /// repainted, the background layer keeps the photograph's own pixels
    /// everywhere else — including the people. The background layer sits at the
    /// FILLED depth, several metres behind where those people actually stood, so
    /// each of them is drawn twice at two different distances and the second
    /// copy slides out from behind the first as soon as the viewer moves. That
    /// is the ghost.
    ///
    /// Nobody ever sees this region, so it does not need a model's attention —
    /// it only needs to stop being a face. `LocalBackgroundFiller.pushPull`
    /// floods it with colour carried in from the ribbon, which by then holds the
    /// model's real continuation, so the two agree at the seam.
    public static func nearFieldCore(
        depth: DepthMap,
        matching size: CGSize,
        threshold: Float = 0.42,
        bandFraction: CGFloat = 0.04,
        feather: CGFloat = 0.004
    ) throws -> CGImage {

        let w = depth.width, h = depth.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            bytes[i] = depth.values[i] < threshold ? 255 : 0
        }

        let gray = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &bytes,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: gray,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let small = context.makeImage() else {
            throw ImagingError.rasterizationFailed
        }

        let extent = CGRect(origin: .zero, size: size)
        let longEdge = max(size.width, size.height)

        let up = CIFilter.lanczosScaleTransform()
        up.inputImage = small.ci
        up.scale = Float(size.width / CGFloat(w))
        up.aspectRatio = Float((size.height / CGFloat(h)) / (size.width / CGFloat(w)))
        var field = (up.outputImage ?? small.ci).normalizedToOrigin().cropped(to: extent)
        field = MaskAlgebra.splatRedToAllChannels(field)

        // Erode by slightly LESS than the ribbon's width, so the core and the
        // ribbon overlap rather than meeting exactly. A hairline of untouched
        // photograph between them would be a hairline of the subject's face.
        let shrink = CIFilter.morphologyMinimum()
        shrink.inputImage = field.clampedToExtent()
        shrink.radius = Float(longEdge * bandFraction * 0.85)
        var core = (shrink.outputImage ?? field).cropped(to: extent)

        if feather > 0 {
            let soften = CIFilter.gaussianBlur()
            soften.inputImage = core.clampedToExtent()
            soften.radius = Float(longEdge * feather)
            core = (soften.outputImage ?? core).cropped(to: extent)
        }

        return try MaskAlgebra.inpaintAlphaMask(fromMatte: core)
            .cropped(to: extent)
            .render(cropping: extent)
    }
}
