//
//  DepthSources.swift
//  SpatialMemory — where per-pixel depth comes from
//
//  Two flat layers give you lean-parallax and nothing more: a cutout sliding
//  over a backdrop. Real relief needs a depth value per pixel, and then a mesh
//  displaced by it.
//
//  Nothing in this file uses a neural network, which is deliberate — every ML
//  path on Apple platforms (Vision's segmentation, Spatial3DImage.generate())
//  refuses to run in a simulator. These two sources both work there.
//
//    PhotoAuxiliaryDepthSource   real, measured depth, read straight out of the
//                                file. Portrait mode and LiDAR captures carry
//                                it. Costs nothing and is the truth.
//    ImageCueDepthSource         an estimate from focus, contrast and a ground
//                                plane prior. Not measurement — an informed
//                                guess that is right often enough to look like
//                                a place.
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import ImageIO

// MARK: - The map

/// A normalized depth field, row-major, origin top-left to match image order.
///
/// `0` is the nearest surface in the frame, `1` the furthest. Deliberately
/// relative, not metric: the layout decides what near and far mean in metres,
/// so a guessed map and a measured one drive the same geometry.
public struct DepthMap: Sendable {

    public let width: Int
    public let height: Int
    /// `width * height` values in `0...1`.
    public let values: [Float]
    /// Whether this came from the camera or from a guess. Surface it — a viewer
    /// deserves to know which parts of a memory are measured.
    public let isMeasured: Bool

    /// The real distances `0` and `1` correspond to, in metres, when the source
    /// knew them. A metric model gives the room its true size instead of an
    /// arbitrary near/far guess.
    public let metricRange: ClosedRange<Float>?

    /// Horizontal field of view in radians, when the source recovered a focal
    /// length. Better than EXIF where EXIF is missing, which is most old photos.
    public let estimatedHorizontalFOV: Float?

    public init(
        width: Int,
        height: Int,
        values: [Float],
        isMeasured: Bool,
        metricRange: ClosedRange<Float>? = nil,
        estimatedHorizontalFOV: Float? = nil
    ) {
        precondition(values.count == width * height, "depth buffer size mismatch")
        self.width = width
        self.height = height
        self.values = values
        self.isMeasured = isMeasured
        self.metricRange = metricRange
        self.estimatedHorizontalFOV = estimatedHorizontalFOV
    }

    @inlinable
    public func value(x: Int, y: Int) -> Float {
        values[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
    }

    /// The same depth field with the near-field erased and closed over, so the
    /// background can be given its own continuous mesh.
    ///
    /// The foreground mesh tears at silhouettes and the inpainted backdrop shows
    /// through those holes — but a *flat* backdrop behind a torn mesh betrays
    /// itself the moment the viewer moves, because the hole has depth and the
    /// thing behind it does not. Filling the subject out of the depth map gives
    /// the backdrop real geometry that continues the room behind them.
    ///
    /// It is the depth equivalent of the colour inpainting, and it is a hole
    /// fill rather than a guess: distance is diffused inward from the rim of the
    /// subject one pixel per pass, so the closed region is continuous with the
    /// wall or floor that actually surrounds it.
    ///
    /// - Parameter threshold: normalized depth below which a pixel counts as
    ///   near-field. Should match whatever the near-field matte used, or the
    ///   backdrop's geometry and the tears in front of it disagree.
    public func fillingNearField(below threshold: Float) -> DepthMap {

        var filled = values
        var isHole = values.map { $0 < threshold }
        guard isHole.contains(true) else { return self }

        // One pass advances the frontier by one pixel, so the cap is the widest
        // a subject can be and still get closed. Derived from the grid rather
        // than picked, and it exits early the moment nothing changed.
        let maxPasses = max(width, height)

        for _ in 0..<maxPasses {
            var advanced = false
            var next = filled
            var nextHole = isHole

            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    guard isHole[i] else { continue }

                    var sum: Float = 0
                    var count = 0
                    // Four-neighbour rather than eight: diagonals let depth leak
                    // across a thin limb and pull the far wall through an arm.
                    if x > 0,          !isHole[i - 1]     { sum += filled[i - 1];     count += 1 }
                    if x < width - 1,  !isHole[i + 1]     { sum += filled[i + 1];     count += 1 }
                    if y > 0,          !isHole[i - width] { sum += filled[i - width]; count += 1 }
                    if y < height - 1, !isHole[i + width] { sum += filled[i + width]; count += 1 }

                    if count > 0 {
                        next[i] = sum / Float(count)
                        nextHole[i] = false
                        advanced = true
                    }
                }
            }

            filled = next
            isHole = nextHole
            if !advanced { break }
        }

        // A subject touching the frame edge can leave a residue with no rim to
        // pull from. Push it to the far plane rather than leaving it near, so a
        // stray patch sits in the wall instead of hovering in the room.
        for i in filled.indices where isHole[i] { filled[i] = 1 }

        // Two smoothing passes over the originally-filled region only. The
        // diffusion front leaves faint ridges where opposing rims met, and a
        // ridge in a depth map is a crease in the mesh.
        let originalHoles = values.map { $0 < threshold }
        for _ in 0..<2 {
            var smoothed = filled
            for y in 1..<max(height - 1, 1) {
                for x in 1..<max(width - 1, 1) {
                    let i = y * width + x
                    guard originalHoles[i] else { continue }
                    smoothed[i] = (filled[i] * 4
                                   + filled[i - 1] + filled[i + 1]
                                   + filled[i - width] + filled[i + width]) / 8
                }
            }
            filled = smoothed
        }

        return DepthMap(
            width: width,
            height: height,
            values: filled,
            isMeasured: isMeasured,
            metricRange: metricRange,
            estimatedHorizontalFOV: estimatedHorizontalFOV
        )
    }
}

// MARK: - The seam

public protocol DepthSource: Sendable {
    /// - Parameter sourceData: original file bytes. Required to find embedded
    ///   depth; ignored by estimators.
    func depth(for image: CGImage, sourceData: Data?) async throws -> DepthMap
}

public enum DepthSourceFactory {

    /// Real depth when the file carries it, an estimate when it doesn't.
    ///
    /// This ordering matters more than it looks for memory work: a photo taken
    /// last year in Portrait mode has measured depth, and a photo from 1975 has
    /// none and never will. The archive that matters most is the one that needs
    /// the estimator.
    /// - Parameter refinement: guided upsampling applied on top of whichever
    ///   source wins. Estimated depth needs it — the cue-based map is smooth and
    ///   blobby, and snapping its edges onto the photograph's own is most of
    ///   what stops silhouettes reading as cut polygons.
    ///
    ///   Pass `nil` to get the raw source. That is the right call in front of a
    ///   depth *model*, which already traces boundaries: refining it again only
    ///   softens the thing it was chosen for.
    public static func automatic(
        resolution: Int = 320,
        refinement: GuidedDepthRefinement? = .default
    ) -> any DepthSource {

        let base = FallbackDepthSource(
            primary: PhotoAuxiliaryDepthSource(resolution: resolution),
            fallback: ImageCueDepthSource(resolution: resolution)
        )

        guard let refinement else { return base }
        return RefinedDepthSource(base: base, refinement: refinement)
    }
}

public struct FallbackDepthSource: DepthSource {
    let primary: any DepthSource
    let fallback: any DepthSource

    public init(primary: any DepthSource, fallback: any DepthSource) {
        self.primary = primary
        self.fallback = fallback
    }

    public func depth(for image: CGImage, sourceData: Data?) async throws -> DepthMap {
        if let measured = try? await primary.depth(for: image, sourceData: sourceData) {
            return measured
        }
        return try await fallback.depth(for: image, sourceData: sourceData)
    }
}

public enum DepthError: LocalizedError {
    case noEmbeddedDepth
    case unreadableDepthBuffer

    public var errorDescription: String? {
        switch self {
        case .noEmbeddedDepth:
            return "This image carries no depth or disparity map."
        case .unreadableDepthBuffer:
            return "The embedded depth buffer could not be read."
        }
    }
}

// MARK: - 1. Measured depth, straight from the file

/// Reads the depth or disparity map that Portrait mode and LiDAR captures embed
/// as auxiliary data.
///
/// Pure file parsing — no compute device involved — so unlike every ML depth
/// path this works in the simulator. Drag a Portrait photo from your iPhone onto
/// the simulator window and you get genuine measured geometry.
public struct PhotoAuxiliaryDepthSource: DepthSource {

    public var resolution: Int

    public init(resolution: Int = 320) {
        self.resolution = resolution
    }

    public func depth(for image: CGImage, sourceData: Data?) async throws -> DepthMap {
        guard let data = sourceData,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DepthError.noEmbeddedDepth
        }

        // Disparity first: it is what Portrait mode writes, and it degrades more
        // gracefully than depth when the capture had no absolute scale.
        let candidates = [
            kCGImageAuxiliaryDataTypeDisparity,
            kCGImageAuxiliaryDataTypeDepth
        ]

        var depthData: AVDepthData?
        for type in candidates {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type)
                    as? [AnyHashable: Any] else { continue }
            if let parsed = try? AVDepthData(fromDictionaryRepresentation: info) {
                depthData = parsed
                break
            }
        }

        guard var parsed = depthData else { throw DepthError.noEmbeddedDepth }

        // Normalize the representation so the arithmetic below has one case.
        if parsed.depthDataType != kCVPixelFormatType_DisparityFloat32 {
            parsed = parsed.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        }

        let buffer = parsed.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let bw = CVPixelBufferGetWidth(buffer)
        let bh = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard bw > 0, bh > 0, let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw DepthError.unreadableDepthBuffer
        }

        // Resample onto our working grid, preserving the image's aspect.
        let (gw, gh) = Self.gridSize(for: image, longEdge: resolution)
        var raw = [Float](repeating: 0, count: gw * gh)
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude

        for y in 0..<gh {
            let sy = min(bh - 1, Int((Float(y) + 0.5) / Float(gh) * Float(bh)))
            let row = base.advanced(by: sy * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<gw {
                let sx = min(bw - 1, Int((Float(x) + 0.5) / Float(gw) * Float(bw)))
                let v = row[sx]
                let clean = v.isFinite ? v : 0
                raw[y * gw + x] = clean
                lo = min(lo, clean)
                hi = max(hi, clean)
            }
        }

        // Disparity is inversely proportional to distance: HIGH disparity means
        // NEAR. Our convention is 0 = near, so the normalization flips it.
        let span = max(hi - lo, 1e-6)
        let values = raw.map { 1 - (($0 - lo) / span) }

        return DepthMap(width: gw, height: gh, values: values, isMeasured: true)
    }

    static func gridSize(for image: CGImage, longEdge: Int) -> (Int, Int) {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        if w >= h {
            return (longEdge, max(2, Int((CGFloat(longEdge) * h / w).rounded())))
        }
        return (max(2, Int((CGFloat(longEdge) * w / h).rounded())), longEdge)
    }
}

// MARK: - 2. Estimated depth, from image cues

/// Estimates relative depth from three classical cues, entirely in Core Image.
///
/// This is a guess and the code says so. It is not a depth model and will be
/// wrong on scenes that break its assumptions — a poster of a landscape on a
/// near wall reads as far away, because to these cues it is. What it does
/// reliably is produce *smooth, plausible relief* rather than a flat plane,
/// which is the difference between a cutout that slides and a scene that has
/// shape.
///
/// On device, replace this with `ImagePresentationComponent.Spatial3DImage` or
/// a Core ML depth model. The seam exists for exactly that swap.
public struct ImageCueDepthSource: DepthSource {

    /// Weight of the focus cue: sharp detail reads as near, soft as far.
    public var focusWeight: Float
    /// Weight of the ground-plane prior: the bottom of a frame is usually
    /// nearer than the top. The single most reliable monocular cue there is.
    public var groundWeight: Float
    /// Weight of the aerial-perspective cue: distance washes out contrast.
    public var hazeWeight: Float
    /// Smoothing, as a fraction of the long edge. Heavy on purpose — a noisy
    /// depth map turns into a crumpled mesh.
    public var smoothing: CGFloat
    public var resolution: Int

    public init(
        focusWeight: Float = 0.45,
        groundWeight: Float = 0.40,
        hazeWeight: Float = 0.15,
        smoothing: CGFloat = 0.035,
        resolution: Int = 320
    ) {
        self.focusWeight = focusWeight
        self.groundWeight = groundWeight
        self.hazeWeight = hazeWeight
        self.smoothing = smoothing
        self.resolution = resolution
    }

    public func depth(for image: CGImage, sourceData: Data?) async throws -> DepthMap {
        let (gw, gh) = PhotoAuxiliaryDepthSource.gridSize(for: image, longEdge: resolution)
        let extent = CGRect(x: 0, y: 0, width: CGFloat(gw), height: CGFloat(gh))

        // Work at grid resolution throughout. Everything downstream is a heavy
        // blur anyway, so full-resolution filtering would only cost time.
        let scale = CGFloat(gw) / CGFloat(image.width)
        let shrink = CIFilter.lanczosScaleTransform()
        shrink.inputImage = image.ci
        shrink.scale = Float(scale)
        shrink.aspectRatio = 1
        let small = (shrink.outputImage ?? image.ci).normalizedToOrigin().cropped(to: extent)

        // Luminance only — colour tells us nothing about distance here.
        let mono = CIFilter.colorControls()
        mono.inputImage = small
        mono.saturation = 0
        mono.brightness = 0
        mono.contrast = 1
        let luma = (mono.outputImage ?? small).cropped(to: extent)

        // --- cue 1: focus -------------------------------------------------
        // Difference of Gaussians. High where local detail survives, i.e. where
        // the lens was focused, which is usually the subject.
        let fine = Self.blur(luma, radius: 1.0, extent: extent)
        let coarse = Self.blur(luma, radius: 5.0, extent: extent)
        let dog = CIFilter.differenceBlendMode()
        dog.inputImage = fine
        dog.backgroundImage = coarse
        var detail = (dog.outputImage ?? luma).cropped(to: extent)
        // Spread detail into a region rather than an edge map, then lift it —
        // raw DoG output is very dark.
        detail = Self.blur(detail, radius: CGFloat(gw) * 0.05, extent: extent)
        detail = MaskAlgebra.remapContrast(detail, gain: 9.0, bias: 0.0)
        // Sharp = near, so invert into depth.
        let focusDepth = MaskAlgebra.invert(detail)

        // --- cue 2: ground plane ------------------------------------------
        // Core Image's origin is bottom-left, so point0 at y = 0 is the BOTTOM
        // of the photograph. Black there means near.
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.point1 = CGPoint(x: 0, y: extent.height)
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        let groundDepth = (gradient.outputImage ?? luma).cropped(to: extent)

        // --- cue 3: aerial perspective ------------------------------------
        // Washed-out, low-contrast, bright regions tend to be distant.
        let hazeDepth = Self.blur(luma, radius: CGFloat(gw) * 0.08, extent: extent)

        // --- combine -------------------------------------------------------
        var combined = Self.scaled(focusDepth, by: focusWeight, extent: extent)
        combined = Self.add(combined, Self.scaled(groundDepth, by: groundWeight, extent: extent), extent: extent)
        combined = Self.add(combined, Self.scaled(hazeDepth, by: hazeWeight, extent: extent), extent: extent)

        // Smooth hard. A mesh inherits every wrinkle in this map.
        combined = Self.blur(combined, radius: CGFloat(gw) * smoothing, extent: extent)

        // --- read back ------------------------------------------------------
        var pixels = [UInt8](repeating: 0, count: gw * gh * 4)
        ImagingContext.shared.render(
            combined,
            toBitmap: &pixels,
            rowBytes: gw * 4,
            bounds: extent,
            format: .RGBA8,
            colorSpace: ImagingContext.sRGB
        )

        // render(toBitmap:) writes with Core Image's bottom-left origin, and a
        // DepthMap is top-left. Flip rows on the way out.
        var values = [Float](repeating: 0, count: gw * gh)
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for y in 0..<gh {
            let srcRow = gh - 1 - y
            for x in 0..<gw {
                let v = Float(pixels[(srcRow * gw + x) * 4]) / 255
                values[y * gw + x] = v
                lo = min(lo, v)
                hi = max(hi, v)
            }
        }

        // Stretch to the full range so the layout's near/far always get used.
        let span = max(hi - lo, 1e-6)
        for i in values.indices { values[i] = (values[i] - lo) / span }

        return DepthMap(width: gw, height: gh, values: values, isMeasured: false)
    }

    // MARK: Core Image helpers

    static func blur(_ image: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        guard radius > 0.01 else { return image }
        let f = CIFilter.gaussianBlur()
        f.inputImage = image.clampedToExtent()
        f.radius = Float(radius)
        return (f.outputImage ?? image).cropped(to: extent)
    }

    static func scaled(_ image: CIImage, by k: Float, extent: CGRect) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: CGFloat(k), y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: CGFloat(k), z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: CGFloat(k), w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return (f.outputImage ?? image).cropped(to: extent)
    }

    static func add(_ a: CIImage, _ b: CIImage, extent: CGRect) -> CIImage {
        let f = CIFilter.additionCompositing()
        f.inputImage = a
        f.backgroundImage = b
        return (f.outputImage ?? a).cropped(to: extent)
    }
}
