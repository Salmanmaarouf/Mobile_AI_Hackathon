//
//  ForegroundSegmentationService.swift
//  SpatialMemory — PHASE 1: Advanced Segmentation & Matting
//
//  A matte comes in from a `MatteSource`; four registered rasters come out.
//  The matting chain and the derivation live in `MatteCompositor` so every
//  provider gets identical treatment — see MatteSources.swift.
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

// MARK: - Output payload

/// Every raster the rest of the pipeline needs, all at the source resolution
/// and all sharing one coordinate space.
///
/// `@unchecked Sendable`: CGImage is an immutable CF value; see ImagingCore.swift.
public struct SegmentationResult: @unchecked Sendable {

    /// The untouched source frame.
    public let source: CGImage

    /// Feathered subject matte. White (1.0) over the subject, black (0.0) over
    /// the background, with a sub-pixel ramp at the boundary. RGB and A all
    /// carry the same value.
    ///
    /// This is what RealityKit consumes as an **opacity texture** — see the
    /// note in `MemoryContainer` on why we never hand it a premultiplied cutout.
    public let matte: CGImage

    /// Subject over transparency. Convenience output for export, previews and
    /// non-RealityKit consumers. Premultiplied, as Core Image always emits.
    public let foregroundCutout: CGImage

    /// Source frame with the subject punched out — a transparent hole exactly
    /// where the matte was opaque. This is the `image` field of the inpainting
    /// upload.
    public let backgroundPlate: CGImage

    /// Black RGB, alpha = 1 − matte. This is the `mask` field of the inpainting
    /// upload: alpha 0 marks the region the model must hallucinate.
    public let inpaintMask: CGImage

    /// How many discrete foreground instances the provider found. Providers that
    /// cannot know report 1.
    public let instanceCount: Int

    public var pixelSize: CGSize { source.size }
    public var aspectRatio: CGFloat { source.aspectRatio }
}

// MARK: - Errors

public enum SegmentationError: LocalizedError {
    case noForegroundDetected
    case visionRequestFailed(underlying: Error)
    case maskGenerationFailed(underlying: Error)
    case cutoutNotFound(name: String)
    case cutoutSizeMismatch(cutout: CGSize, source: CGSize)

    public var errorDescription: String? {
        switch self {
        case .noForegroundDetected:
            return "No salient foreground instance was found in this image."
        case let .visionRequestFailed(error):
            return """
            VNGenerateForegroundInstanceMaskRequest failed: \(error.localizedDescription). \
            If this reads "Could not create inference context", you are running in a simulator — \
            that request has no CPU path and cannot run there. Use AlphaChannelMatteSource or \
            EllipseMatteSource instead.
            """
        case let .maskGenerationFailed(error):
            return "Mask generation failed: \(error.localizedDescription)"
        case let .cutoutNotFound(name):
            return "No cutout named \(name) in the bundle."
        case let .cutoutSizeMismatch(cutout, source):
            return """
            The cutout is \(Int(cutout.width))×\(Int(cutout.height)) but the source is \
            \(Int(source.width))×\(Int(source.height)) — different aspect ratios. The cutout \
            must cover the full frame; a different resolution is fine, a crop is not. \
            "Copy Subject" crops. Export a full-frame PNG, or bake one with \
            Tools/bake-cutout.swift.
            """
        }
    }
}

// MARK: - Matting configuration

public struct MattingOptions: Sendable {

    /// Radius, in source pixels, by which the matte is eroded before feathering.
    ///
    /// A subject mask tends to include a one-to-two pixel halo of *background*
    /// colour along the silhouette. Blurring without eroding first smears that
    /// halo into the composite as a bright outline. Shrinking the matte by
    /// roughly the feather radius pulls the ramp inside the subject instead.
    public var erosionRadius: CGFloat

    /// Gaussian sigma, in source pixels, for the edge feather.
    public var featherRadius: CGFloat

    /// Post-blur contrast ramp. `gain` steepens the transition, `bias` re-centres
    /// it. Defaults push the interior back to a solid 1.0 while leaving roughly
    /// two pixels of genuine gradient at the silhouette.
    public var contrastGain: CGFloat
    public var contrastBias: CGFloat

    public init(
        erosionRadius: CGFloat = 1.5,
        featherRadius: CGFloat = 2.0,
        contrastGain: CGFloat = 1.35,
        contrastBias: CGFloat = -0.16
    ) {
        self.erosionRadius = erosionRadius
        self.featherRadius = featherRadius
        self.contrastGain = contrastGain
        self.contrastBias = contrastBias
    }

    public static let `default` = MattingOptions()

    /// Scales the pixel-denominated radii for a given image so behaviour is
    /// consistent between a 12 MP capture and a 1 MP screenshot.
    /// Radii are authored against a 2048 px long edge.
    public func scaled(forLongEdge longEdge: CGFloat) -> MattingOptions {
        let k = max(longEdge / 2048.0, 0.25)
        var copy = self
        copy.erosionRadius *= k
        copy.featherRadius *= k
        return copy
    }
}

// MARK: - Service

/// Serializes matte production and compositing off the main actor.
///
/// `VNImageRequestHandler.perform(_:)` is synchronous and compute-bound. Running
/// it inside an actor keeps it on the cooperative pool — never on the main
/// thread — and serializes concurrent callers so several full-resolution
/// segmentations don't stampede the Neural Engine at once.
public actor ForegroundSegmentationService {

    private let matteSource: any MatteSource

    /// - Parameter matteSource: defaults to `MatteSourceFactory.automatic()`,
    ///   which is Vision on device and the elliptical placeholder in a
    ///   simulator. Pass `AlphaChannelMatteSource` to drive the simulator from
    ///   a real cutout.
    public init(matteSource: (any MatteSource)? = nil) {
        self.matteSource = matteSource ?? MatteSourceFactory.automatic()
    }

    public func segment(
        _ image: CGImage,
        options: MattingOptions = .default
    ) async throws -> SegmentationResult {
        let raw = try await matteSource.rawMatte(for: image)
        return try MatteCompositor.derive(source: image, rawMatte: raw, options: options)
    }

    /// The Vision-native cutout, for comparison. Device only.
    ///
    /// Not on the main path: it returns a hard-edged composite with no matte,
    /// and the matte is needed twice over — once inverted for the plate, once as
    /// RealityKit's opacity texture.
    ///
    /// Note the parameter is `croppedToInstancesExtent:`, not `croppedToInstances:`.
    public func visionNativeCutout(
        _ image: CGImage,
        croppedToInstancesExtent: Bool = false
    ) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first,
              observation.allInstances.isEmpty == false else {
            throw SegmentationError.noForegroundDetected
        }
        let buffer = try observation.generateMaskedImage(
            ofInstances: observation.allInstances,
            from: handler,
            croppedToInstancesExtent: croppedToInstancesExtent
        )
        return try buffer.makeCGImage()
    }
}
