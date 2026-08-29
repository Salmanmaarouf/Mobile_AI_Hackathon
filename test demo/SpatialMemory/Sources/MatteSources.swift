//
//  MatteSources.swift
//  SpatialMemory — where the subject matte comes from
//
//  PHASE 1 SEAM. Vision's VNGenerateForegroundInstanceMaskRequest has no CPU
//  code path: forcing one returns `unsupported compute device
//  <MLCPUComputeDevice>`, which surfaces as "Could not create inference
//  context". Every simulator is CPU-only, so the real segmenter throws there.
//
//  Rather than making the simulator a dead end, matte production is a protocol
//  with three implementations. Everything downstream — the matting chain, the
//  four derived rasters, the whole scene — is identical regardless of which one
//  produced the raw matte.
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo        // CVPixelBuffer, returned by generateScaledMaskForImage.
import Foundation
import ImageIO
import Vision

// MARK: - The seam

/// A raw, un-feathered subject matte in the source image's pixel space.
///
/// White (1.0) over the subject, black (0.0) over the background. Only the red
/// channel is guaranteed meaningful — `MatteCompositor` splats it before use.
public struct RawMatte: @unchecked Sendable {
    public let image: CIImage
    /// How many discrete foreground instances the source found. Providers that
    /// cannot know report 1.
    public let instanceCount: Int

    public init(image: CIImage, instanceCount: Int = 1) {
        self.image = image
        self.instanceCount = instanceCount
    }
}

/// Produces a subject matte for an image, however it likes.
public protocol MatteSource: Sendable {
    func rawMatte(for image: CGImage) async throws -> RawMatte
}

public enum MatteSourceFactory {

    /// Picks a provider that will actually work in the current build.
    ///
    /// On device this is Vision. In the simulator it is the elliptical
    /// placeholder, because Vision cannot run there — swap in
    /// `AlphaChannelMatteSource` explicitly when you have a real cutout to feed
    /// it, which is the combination that makes a simulator demo look right.
    public static func automatic() -> any MatteSource {
        #if targetEnvironment(simulator)
        return EllipseMatteSource()
        #else
        return VisionMatteSource()
        #endif
    }

    /// Prefers a bundled cutout when one is present, and falls back to whatever
    /// `automatic()` would choose. This is the call the demo uses: drop
    /// `sample-cutout.png` into the bundle and the simulator shows a real
    /// silhouette; leave it out and you still get a running scene.
    public static func bundledCutoutOrAutomatic(
        resource name: String,
        extension ext: String = "png",
        in bundle: Bundle = .main
    ) -> any MatteSource {
        if let source = try? AlphaChannelMatteSource(bundledResource: name, extension: ext, in: bundle) {
            return source
        }
        return automatic()
    }
}

// MARK: - 1. Vision (device only)

public struct VisionMatteSource: MatteSource {

    public init() {}

    public func rawMatte(for image: CGImage) async throws -> RawMatte {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()

        do {
            try handler.perform([request])
        } catch {
            throw SegmentationError.visionRequestFailed(underlying: error)
        }

        guard let observation = request.results?.first else {
            throw SegmentationError.noForegroundDetected
        }
        let instances = observation.allInstances
        guard instances.isEmpty == false else {
            throw SegmentationError.noForegroundDetected
        }

        // The full-resolution matte. The observation's own `instanceMask` is
        // roughly 512 px on the long edge and visibly stair-steps once scaled
        // up over a 12 MP frame.
        let buffer: CVPixelBuffer
        do {
            buffer = try observation.generateScaledMaskForImage(
                forInstances: instances,
                from: handler
            )
        } catch {
            throw SegmentationError.maskGenerationFailed(underlying: error)
        }

        let cg = try buffer.makeCGImage()
        return RawMatte(image: cg.ci, instanceCount: instances.count)
    }
}

// MARK: - 2. Alpha channel of a pre-made cutout

/// Reads the matte out of the alpha channel of a subject cutout you made
/// elsewhere. This is the provider that makes a good simulator demo possible.
///
/// Anything that produces a transparent-background PNG works. On a Mac, the
/// fastest route is Preview: open the photo, choose the markup toolbar's
/// **Instant Alpha / Remove Background**, and export as PNG. The Photos app's
/// "Copy Subject" and any of the usual image editors produce the same thing.
///
/// The cutout must be the same pixel dimensions as the source photo, and must
/// not have been cropped to the subject — crop it and the matte no longer lines
/// up with the frame the geometry is built from.
public struct AlphaChannelMatteSource: MatteSource {

    private let cutout: CGImage

    public init(cutout: CGImage) {
        self.cutout = cutout
    }

    /// Loads the cutout from the app bundle by resource name.
    public init(bundledResource name: String, extension ext: String = "png", in bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw SegmentationError.cutoutNotFound(name: "\(name).\(ext)")
        }
        let data = try Data(contentsOf: url)
        self.cutout = try ImageDecoder.cgImage(from: data)
    }

    public func rawMatte(for image: CGImage) async throws -> RawMatte {
        // Resolution may differ — an export at a different size is fine, and
        // MatteCompositor.conform rescales it onto the source grid. Aspect ratio
        // may NOT differ: that means the cutout was cropped to the subject, and
        // a cropped cutout carries no information about where in the frame the
        // subject sat. ("Copy Subject" in Preview and Photos crops; export a
        // full-frame PNG instead, or bake one with Tools/bake-cutout.swift.)
        let tolerance: CGFloat = 0.01
        guard abs(cutout.aspectRatio - image.aspectRatio) < tolerance else {
            throw SegmentationError.cutoutSizeMismatch(
                cutout: cutout.size,
                source: image.size
            )
        }

        // Lift alpha into the red channel. Everything downstream reads red.
        let f = CIFilter.colorMatrix()
        f.inputImage = cutout.ci
        f.rVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.gVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.bVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)

        guard let matte = f.outputImage else { throw ImagingError.rasterizationFailed }
        return RawMatte(image: matte, instanceCount: 1)
    }
}

// MARK: - 3. Elliptical placeholder

/// A hand-drawn ellipse where the subject probably is. Produces no useful
/// cutout, but it exercises every downstream stage — the matting chain, the
/// plate, the mask, the fill, the geometry, the materials, the audio — so the
/// simulator shows a real two-layer scene with real parallax instead of an
/// error.
///
/// Use it to develop Phases 2 through 4. Never ship it.
public struct EllipseMatteSource: MatteSource {

    /// Centre, as a fraction of the frame. `(0.5, 0.55)` sits a portrait
    /// subject slightly below centre, where people usually are.
    public var center: CGPoint
    /// Radii, as a fraction of the frame's smaller dimension.
    public var radii: CGSize

    public init(
        center: CGPoint = CGPoint(x: 0.5, y: 0.55),
        radii: CGSize = CGSize(width: 0.22, height: 0.42)
    ) {
        self.center = center
        self.radii = radii
    }

    public func rawMatte(for image: CGImage) async throws -> RawMatte {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let minSide = min(extent.width, extent.height)

        // Core Image's origin is bottom-left, so a centre expressed from the
        // top (how people describe photos) is flipped here.
        let cx = extent.width * center.x
        let cy = extent.height * (1 - center.y)
        let rx = minSide * radii.width
        let ry = minSide * radii.height

        // A radial gradient is an ellipse once the space is scaled anisotropically:
        // draw a unit circle, then stretch it. inputRadius0/1 give the soft rim
        // for free, which is what the matting chain expects to receive.
        let gradient = CIFilter.radialGradient()
        gradient.center = CGPoint(x: 0, y: 0)
        gradient.radius0 = Float(0.92)
        gradient.radius1 = Float(1.0)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let unit = gradient.outputImage else { throw ImagingError.rasterizationFailed }

        let shaped = unit
            .transformed(by: CGAffineTransform(scaleX: rx, y: ry))
            .transformed(by: CGAffineTransform(translationX: cx, y: cy))
            .cropped(to: extent)

        // The gradient is infinite outside radius1 only in the sense that it
        // holds color1 — composite over black to make the extent finite and the
        // background unambiguous.
        let backdrop = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: extent)
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = shaped
        over.backgroundImage = backdrop

        guard let matte = over.outputImage else { throw ImagingError.rasterizationFailed }
        return RawMatte(image: matte.cropped(to: extent), instanceCount: 1)
    }
}

// MARK: - Shared derivation
//
// Everything from a raw matte to the four rasters the pipeline consumes. Pulled
// out of ForegroundSegmentationService so every MatteSource gets identical
// treatment — a cutout from Preview goes through exactly the same erode,
// feather and re-contrast as Vision's own mask.

public enum MatteCompositor {

    public static func derive(
        source image: CGImage,
        rawMatte: RawMatte,
        options: MattingOptions
    ) throws -> SegmentationResult {

        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let tuned = options.scaled(forLongEdge: max(extent.width, extent.height))

        // Force the matte onto the source pixel grid. Vision's upsample can land
        // a pixel short, and a hand-supplied cutout may be off by rounding.
        let conformed = conform(rawMatte.image, to: extent)
        let matteImage = buildMatte(from: conformed, extent: extent, options: tuned)
        let matteCG = try matteImage.render(cropping: extent)

        // blendWithMask(input, background, mask):
        //     mask == 1 -> input,  mask == 0 -> background
        // Compositing against a fully clear image therefore carves alpha.
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: extent)
        let sourceCI = image.ci

        let cutout = blend(input: sourceCI, background: clear, mask: matteImage, extent: extent)
        let inverted = MaskAlgebra.invert(matteImage)
        let plate = blend(input: sourceCI, background: clear, mask: inverted, extent: extent)
        let apiMask = MaskAlgebra.inpaintAlphaMask(fromMatte: matteImage).cropped(to: extent)

        return SegmentationResult(
            source: image,
            matte: matteCG,
            foregroundCutout: try cutout.render(cropping: extent),
            backgroundPlate: try plate.render(cropping: extent),
            inpaintMask: try apiMask.render(cropping: extent),
            instanceCount: rawMatte.instanceCount
        )
    }

    // MARK: Matting chain — splat, erode, feather, re-steepen

    static func buildMatte(
        from rawMask: CIImage,
        extent: CGRect,
        options: MattingOptions
    ) -> CIImage {

        // (a) Matte value into R, G, B and A alike, so filters that sample
        //     luminance and filters that sample alpha agree.
        var matte = MaskAlgebra.splatRedToAllChannels(rawMask)

        // (b) Erode. The silhouette carries a one-to-two pixel band of
        //     background colour; blurring without shrinking first smears that
        //     band into the composite as a bright outline.
        if options.erosionRadius > 0 {
            let erode = CIFilter.morphologyMinimum()
            erode.inputImage = matte.clampedToExtent()
            erode.radius = Float(options.erosionRadius)
            matte = (erode.outputImage ?? matte).cropped(to: extent)
        }

        // (c) Feather. Clamp before, crop after: a Gaussian grows the extent by
        //     ~3σ and would otherwise leave a soft transparent frame.
        if options.featherRadius > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = matte.clampedToExtent()
            blur.radius = Float(options.featherRadius)
            matte = (blur.outputImage ?? matte).cropped(to: extent)
        }

        // (d) Re-steepen. Without this the interior sits near 0.97 and the
        //     filled plate ghosts through the subject.
        matte = MaskAlgebra.remapContrast(
            matte,
            gain: options.contrastGain,
            bias: options.contrastBias
        )

        return matte.cropped(to: extent)
    }

    static func blend(
        input: CIImage,
        background: CIImage,
        mask: CIImage,
        extent: CGRect
    ) -> CIImage {
        let f = CIFilter.blendWithMask()
        f.inputImage = input
        f.backgroundImage = background
        f.maskImage = mask
        return (f.outputImage ?? input).cropped(to: extent)
    }

    static func conform(_ image: CIImage, to extent: CGRect) -> CIImage {
        let current = image.extent
        guard current.isEmpty == false, current.isInfinite == false else { return image }
        if current.width == extent.width && current.height == extent.height {
            return image.normalizedToOrigin()
        }
        return image
            .transformed(by: CGAffineTransform(
                scaleX: extent.width / current.width,
                y: extent.height / current.height
            ))
            .normalizedToOrigin()
    }
}
