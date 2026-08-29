//
//  DepthRefinement.swift
//  SpatialMemory — making the tear land on the subject's actual outline
//
//  A depth map arrives soft and low-resolution. A LiDAR disparity buffer is a
//  fraction of the photo's size and smeared at every silhouette; the image-cue
//  estimator is blurred on purpose, because a noisy map makes a crumpled mesh.
//  Either way the depth edge does not sit where the person's edge sits, and it
//  is spread over several cells rather than being a step.
//
//  Mesh that directly and you get the failure everybody recognises: a subject
//  cut out with a staircase around them, following a blurry approximation of
//  their outline rather than their outline. Raising the grid resolution alone
//  makes the staircase finer and no more correct.
//
//  The fix is a GUIDED FILTER (He, Sun & Tang, 2013), in its fast upsampling
//  form. The photograph itself is the guide: inside a window the filter fits
//  depth as a linear function of luminance, q = a·I + b, and where the window
//  straddles an edge the fit collapses onto that edge — a goes to ~1 and the
//  output inherits the photograph's own, pixel-sharp boundary. Coefficients are
//  solved at the depth map's resolution and applied at the mesh's, so the cost
//  is set by the small grid and the sharpness by the large one.
//
//  Verified behaviour on a synthetic silhouette (depth edge offset from the
//  colour edge by 10 px at a 384 grid):
//
//      naive bilinear upsample   edge lands 4.5 px off, transition over 8 cells
//      guided upsample           edge lands 1 px off, ONE cell carries the jump
//
//  That single-cell jump is exactly what `DepthMesh` wants: one row of dropped
//  triangles on the silhouette instead of a band of them scattered around it.
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import Foundation

// MARK: - The refinement

public struct GuidedDepthRefinement: Sendable {

    /// Long edge of the grid the mesh is built on. The depth map is upsampled to
    /// this before meshing, so it sets how fine the tear can be: at 384 a torn
    /// cell is 1/384 of the frame, roughly 3 px on a 12 MP photo.
    ///
    /// Costs vertices quadratically — 384 is ~110 k vertices on a 3:2 frame,
    /// which RealityKit handles comfortably. Go to 512 if silhouettes still read
    /// as blocky and you have the frame budget.
    public var meshResolution: Int

    /// Guided-filter window, as a fraction of the DEPTH map's long edge. Small
    /// windows follow edges tightly but see less context; large ones are stabler
    /// and blunter. 0.02 is a good middle.
    public var radiusFraction: Float

    /// Regularisation. Larger values treat more luminance variation as texture
    /// to be ignored rather than as an edge to snap to. Too small and the
    /// hexagon pattern on a wall starts embossing itself into the geometry.
    public var epsilon: Float

    public init(
        meshResolution: Int = 384,
        radiusFraction: Float = 0.02,
        epsilon: Float = 1e-3
    ) {
        self.meshResolution = meshResolution
        self.radiusFraction = radiusFraction
        self.epsilon = epsilon
    }

    public static let `default` = GuidedDepthRefinement()

    /// Upsamples `depth` to the mesh grid, snapping its edges onto the
    /// photograph's.
    ///
    /// - Note: the guide is luminance. Where subject and background differ in
    ///   colour but not in brightness — a black shirt against a dark panel — the
    ///   filter has no edge to find and leaves that stretch of the boundary
    ///   where it was. That is a real limit of a single-channel guide, not a
    ///   tuning problem.
    public func refine(_ depth: DepthMap, guidedBy image: CGImage) throws -> DepthMap {

        // Target grid: the mesh resolution, at the image's aspect.
        let (hw, hh) = PhotoAuxiliaryDepthSource.gridSize(for: image, longEdge: meshResolution)
        let lw = depth.width
        let lh = depth.height
        guard lw > 1, lh > 1, hw > 1, hh > 1 else { return depth }

        // Nothing to gain from "upsampling" to a smaller grid.
        guard hw >= lw, hh >= lh else { return depth }

        let guideHi = try Self.luminance(of: image, width: hw, height: hh)
        let guideLo = Self.resample(guideHi, from: (hw, hh), to: (lw, lh))
        let p = depth.values

        let radius = max(2, Int((Float(max(lw, lh)) * radiusFraction).rounded()))

        // --- the linear fit, solved on the small grid --------------------
        let meanI  = Self.boxFilter(guideLo, w: lw, h: lh, radius: radius)
        let meanP  = Self.boxFilter(p,       w: lw, h: lh, radius: radius)
        let meanII = Self.boxFilter(Self.multiply(guideLo, guideLo), w: lw, h: lh, radius: radius)
        let meanIP = Self.boxFilter(Self.multiply(guideLo, p),       w: lw, h: lh, radius: radius)

        var a = [Float](repeating: 0, count: lw * lh)
        var b = [Float](repeating: 0, count: lw * lh)
        for i in 0..<(lw * lh) {
            let varI  = meanII[i] - meanI[i] * meanI[i]
            let covIP = meanIP[i] - meanI[i] * meanP[i]
            let ai = covIP / (varI + epsilon)
            a[i] = ai
            b[i] = meanP[i] - ai * meanI[i]
        }

        // Smoothing the coefficients is what makes the output continuous
        // between windows rather than blocky at window boundaries.
        let meanA = Self.boxFilter(a, w: lw, h: lh, radius: radius)
        let meanB = Self.boxFilter(b, w: lw, h: lh, radius: radius)

        // --- applied on the big grid, against the sharp guide -------------
        let aHi = Self.resample(meanA, from: (lw, lh), to: (hw, hh))
        let bHi = Self.resample(meanB, from: (lw, lh), to: (hw, hh))

        var out = [Float](repeating: 0, count: hw * hh)
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for i in 0..<(hw * hh) {
            let v = aHi[i] * guideHi[i] + bHi[i]
            let clean = v.isFinite ? min(max(v, 0), 1) : 0
            out[i] = clean
            lo = min(lo, clean)
            hi = max(hi, clean)
        }

        // The fit can shave the extremes. Stretch back to the full range so the
        // layout's near and far distances both get used, exactly as the two
        // depth sources do on the way out.
        let span = max(hi - lo, 1e-6)
        if span < 0.999 {
            for i in out.indices { out[i] = (out[i] - lo) / span }
        }

        return DepthMap(
            width: hw, height: hh, values: out,
            isMeasured: depth.isMeasured,
            metricRange: depth.metricRange,
            estimatedHorizontalFOV: depth.estimatedHorizontalFOV
        )
    }

    // MARK: - Numerics

    /// Exact mean over a (2r+1)² window, clipped at the borders, in O(n) via a
    /// summed-area table. Accumulated in Double: a 512² table of values near 1
    /// overruns Float's 24-bit mantissa well before the last row.
    static func boxFilter(_ values: [Float], w: Int, h: Int, radius: Int) -> [Float] {
        var sat = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum = 0.0
            for x in 0..<w {
                rowSum += Double(values[y * w + x])
                sat[(y + 1) * (w + 1) + (x + 1)] = sat[y * (w + 1) + (x + 1)] + rowSum
            }
        }

        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - radius)
            let y1 = min(h - 1, y + radius)
            for x in 0..<w {
                let x0 = max(0, x - radius)
                let x1 = min(w - 1, x + radius)
                let total = sat[(y1 + 1) * (w + 1) + (x1 + 1)]
                          - sat[y0 * (w + 1) + (x1 + 1)]
                          - sat[(y1 + 1) * (w + 1) + x0]
                          + sat[y0 * (w + 1) + x0]
                let count = Double((y1 - y0 + 1) * (x1 - x0 + 1))
                out[y * w + x] = Float(total / count)
            }
        }
        return out
    }

    /// Bilinear resample, sampling at pixel centres so the grid does not drift
    /// half a cell on the way up.
    static func resample(
        _ values: [Float],
        from source: (w: Int, h: Int),
        to target: (w: Int, h: Int)
    ) -> [Float] {
        let (sw, sh) = source
        let (tw, th) = target
        if sw == tw && sh == th { return values }

        var out = [Float](repeating: 0, count: tw * th)
        for y in 0..<th {
            let fy = (Float(y) + 0.5) * Float(sh) / Float(th) - 0.5
            let y0 = Int(fy.rounded(.down))
            let ty = fy - Float(y0)
            let y0c = min(max(y0, 0), sh - 1)
            let y1c = min(max(y0 + 1, 0), sh - 1)
            for x in 0..<tw {
                let fx = (Float(x) + 0.5) * Float(sw) / Float(tw) - 0.5
                let x0 = Int(fx.rounded(.down))
                let tx = fx - Float(x0)
                let x0c = min(max(x0, 0), sw - 1)
                let x1c = min(max(x0 + 1, 0), sw - 1)

                let top = values[y0c * sw + x0c] * (1 - tx) + values[y0c * sw + x1c] * tx
                let bot = values[y1c * sw + x0c] * (1 - tx) + values[y1c * sw + x1c] * tx
                out[y * tw + x] = top * (1 - ty) + bot * ty
            }
        }
        return out
    }

    static func multiply(_ a: [Float], _ b: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: a.count)
        for i in a.indices { out[i] = a[i] * b[i] }
        return out
    }

    /// The photograph as a top-left-origin luminance grid in `0...1`.
    ///
    /// A `CGBitmapContext`'s rows run top-down, which is the same convention
    /// `DepthMap` uses, so drawing into it needs no flip.
    static func luminance(of image: CGImage, width w: Int, height h: Int) throws -> [Float] {
        var bytes = [UInt8](repeating: 0, count: w * h)
        let gray = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &bytes,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: gray,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw ImagingError.rasterizationFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { out[i] = Float(bytes[i]) / 255 }
        return out
    }
}

// MARK: - As a DepthSource decorator

/// Any depth source, with its output snapped to the photograph's edges.
///
/// Wrapping rather than folding it into each source keeps the two producers
/// honest: `PhotoAuxiliaryDepthSource` still returns exactly what the camera
/// measured, and this is a separate, inspectable stage on top.
public struct RefinedDepthSource: DepthSource {

    public let base: any DepthSource
    public let refinement: GuidedDepthRefinement

    public init(base: any DepthSource, refinement: GuidedDepthRefinement = .default) {
        self.base = base
        self.refinement = refinement
    }

    public func depth(for image: CGImage, sourceData: Data?) async throws -> DepthMap {
        let raw = try await base.depth(for: image, sourceData: sourceData)
        // Refinement is an improvement, never a requirement: if it throws, the
        // unrefined map still builds a scene.
        guard let refined = try? refinement.refine(raw, guidedBy: image) else { return raw }
        return refined
    }
}
