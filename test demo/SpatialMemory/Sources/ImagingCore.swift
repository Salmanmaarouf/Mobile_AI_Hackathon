//
//  ImagingCore.swift
//  SpatialMemory — Shared Core Image / Core Graphics substrate
//
//  Zero UI. Pure data processing.
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo        // CVPixelBuffer. Direct import, not via VideoToolbox —
                        // MemberImportVisibility stops transitive members resolving.
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

// MARK: - Sendable bridging
//
// CGImage is an immutable Core Foundation value. Older SDKs do not vend a
// Sendable conformance for it, so every payload struct that ferries CGImages
// across an actor boundary is marked @unchecked Sendable with that invariant
// documented. If your deployment SDK already declares CGImage: Sendable the
// annotation is simply redundant, never wrong.

// MARK: - Shared rendering context

/// A process-wide `CIContext`.
///
/// `CIContext` is documented as thread-safe, and allocating one is expensive
/// (it compiles and caches Metal kernels), so the whole pipeline shares one.
///
/// The working space is deliberately *linear* extended sRGB: alpha compositing
/// and Gaussian blurs are only physically correct in linear light. The output
/// space is plain sRGB so the CGImages we hand to RealityKit and to the PNG
/// encoder are display-referred.
public enum ImagingContext {

    public static let shared: CIContext = {
        var options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .useSoftwareRenderer: false
        ]
        if let working = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) {
            options[.workingColorSpace] = working
        }
        if let output = CGColorSpace(name: CGColorSpace.sRGB) {
            options[.outputColorSpace] = output
        }
        return CIContext(options: options)
    }()

    public static let sRGB: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
}

// MARK: - Errors

public enum ImagingError: LocalizedError {
    case rasterizationFailed
    case pixelBufferConversionFailed
    case emptyExtent
    case encodingFailed
    case decodingFailed
    case pngBudgetExceeded(bytes: Int, budget: Int)

    public var errorDescription: String? {
        switch self {
        case .rasterizationFailed:
            return "CIContext could not render the CIImage to a CGImage."
        case .pixelBufferConversionFailed:
            return "Could not convert the CVPixelBuffer into a CGImage."
        case .emptyExtent:
            return "The CIImage has an infinite or empty extent and cannot be rasterized."
        case .encodingFailed:
            return "CGImageDestination failed to finalize the image."
        case .decodingFailed:
            return "The response payload could not be decoded into a CGImage."
        case let .pngBudgetExceeded(bytes, budget):
            return "Encoded PNG is \(bytes) bytes, exceeding the \(budget) byte budget at every size in the ladder."
        }
    }
}

// MARK: - CIImage rasterization

public extension CIImage {

    /// Renders to a CGImage in sRGB, 8-bit RGBA (premultiplied, as Core Image
    /// always emits). Use `render(cropping:)` when the receiver's extent is
    /// infinite (e.g. after `clampedToExtent()`).
    func render(cropping rect: CGRect? = nil) throws -> CGImage {
        let target = rect ?? extent
        guard target.isEmpty == false, target.isInfinite == false else {
            throw ImagingError.emptyExtent
        }
        guard let cg = ImagingContext.shared.createCGImage(
            self,
            from: target,
            format: .RGBA8,
            colorSpace: ImagingContext.sRGB
        ) else {
            throw ImagingError.rasterizationFailed
        }
        return cg
    }

    /// Core Image places the origin at the bottom-left; a CIImage built from a
    /// CGImage therefore sits at `(0, 0, w, h)`. This normalizes an image whose
    /// extent has drifted (after transforms) back onto that origin.
    func normalizedToOrigin() -> CIImage {
        transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                          y: -extent.origin.y))
    }
}

public extension CGImage {
    var size: CGSize { CGSize(width: width, height: height) }
    var aspectRatio: CGFloat { CGFloat(width) / CGFloat(height) }
    var ci: CIImage { CIImage(cgImage: self) }
}

// MARK: - CVPixelBuffer bridging
//
// Vision hands masks back as CVPixelBuffers. `VTCreateCGImageFromCVPixelBuffer`
// handles the single-component 8-bit format that
// `generateScaledMaskForImage(forInstances:from:)` returns without us having to
// hand-roll a CGDataProvider.

public extension CVPixelBuffer {

    func makeCGImage() throws -> CGImage {
        var out: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(self, options: nil, imageOut: &out)
        guard status == noErr, let image = out else {
            throw ImagingError.pixelBufferConversionFailed
        }
        return image
    }
}

// MARK: - Channel algebra
//
// Every mask operation in this pipeline is expressed as a CIColorMatrix so the
// behaviour is exact and independent of which channel a downstream filter
// samples. A CIColorMatrix computes, per pixel:
//
//     out.r = dot(rVector, in) + bias.x
//     out.g = dot(gVector, in) + bias.y
//     out.b = dot(bVector, in) + bias.z
//     out.a = dot(aVector, in) + bias.w
//
// where `in` is (r, g, b, a) and each vector is (x, y, z, w).

public enum MaskAlgebra {

    /// Splats the red channel into R, G, B **and** A.
    ///
    /// Vision returns a single-component mask; Core Image surfaces that as a
    /// grayscale image (value in luminance, alpha == 1). After this splat the
    /// matte value lives in every channel, so filters that sample luminance and
    /// filters that sample alpha agree — which removes an entire class of
    /// "my mask silently did nothing" bugs.
    public static func splatRedToAllChannels(_ image: CIImage) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.aVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return f.outputImage ?? image
    }

    /// Inverts all four channels: `out = 1 - in`.
    public static func invert(_ image: CIImage) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: -1, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: -1, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: -1, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: -1)
        f.biasVector = CIVector(x: 1, y: 1, z: 1, w: 1)
        return f.outputImage ?? image
    }

    /// Builds the payload the inpainting endpoint expects: **RGB black, alpha
    /// = 1 − matte**.
    ///
    /// OpenAI-style `/v1/images/edits` reads only the alpha channel of `mask`
    /// and repaints wherever alpha == 0. Our matte is 1 over the subject, so the
    /// hole we want hallucinated is exactly `1 - matte`.
    public static func inpaintAlphaMask(fromMatte matte: CIImage) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = matte
        f.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.aVector = CIVector(x: -1, y: 0, z: 0, w: 0)   // alpha = 1 - matte.r
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return f.outputImage ?? matte
    }

    /// Applies a linear gain/bias ramp, then clamps to [0, 1].
    ///
    /// Used after the feather blur to re-steepen the matte: a plain Gaussian
    /// leaves the subject's interior at ~0.97 instead of 1.0, which shows up as
    /// a faint see-through ghost over the inpainted plate.
    public static func remapContrast(_ image: CIImage, gain: CGFloat, bias: CGFloat) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: gain)
        f.biasVector = CIVector(x: bias, y: bias, z: bias, w: bias)
        guard let ramped = f.outputImage else { return image }
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = ramped
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage ?? ramped
    }
}

// MARK: - PNG encoding with a hard byte budget

public enum PNGEncoder {

    /// Encodes a CGImage as PNG.
    /// - Parameter preserveAlpha: pass `false` to drop the alpha channel, which
    ///   typically cuts PNG size by 20–30% for photographic content.
    public static func encode(_ image: CGImage, preserveAlpha: Bool = true) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ImagingError.encodingFailed
        }

        let source: CGImage
        if preserveAlpha {
            source = image
        } else {
            source = try flattenAlpha(image)
        }

        CGImageDestinationAddImage(destination, source, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImagingError.encodingFailed
        }
        return data as Data
    }

    /// Encodes `image` at the largest side in `ladder` whose PNG fits inside
    /// `maxBytes`, returning both the bytes and the side actually used.
    ///
    /// The endpoint requires the `image` and `mask` uploads to share exact
    /// dimensions, so callers must feed the returned side back into the mask
    /// encode rather than letting the two negotiate independently.
    public static func encodeSquare(
        _ image: CGImage,
        ladder: [Int] = [1024, 768, 512],
        maxBytes: Int = 4 * 1_000_000,
        preserveAlpha: Bool = true
    ) throws -> (data: Data, side: Int) {

        var lastCount = 0
        for side in ladder {
            let resized = try resizeSquare(image, to: side)
            let data = try encode(resized, preserveAlpha: preserveAlpha)
            lastCount = data.count
            if data.count <= maxBytes {
                return (data, side)
            }
        }
        throw ImagingError.pngBudgetExceeded(bytes: lastCount, budget: maxBytes)
    }

    /// Nearest-neighbour-free Lanczos resample onto an exact `side × side` grid.
    /// Input is assumed already square (see `SquareCanvas`).
    public static func resizeSquare(_ image: CGImage, to side: Int) throws -> CGImage {
        guard image.width != side || image.height != side else { return image }
        let scale = CGFloat(side) / CGFloat(image.width)
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image.ci
        f.scale = Float(scale)
        f.aspectRatio = 1
        guard let scaled = f.outputImage else { throw ImagingError.rasterizationFailed }
        return try scaled
            .normalizedToOrigin()
            .render(cropping: CGRect(x: 0, y: 0, width: side, height: side))
    }

    /// Composites over opaque black and drops the alpha channel.
    private static func flattenAlpha(_ image: CGImage) throws -> CGImage {
        let ci = image.ci
        let backdrop = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: ci.extent)
        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = ci
        composite.backgroundImage = backdrop
        guard let flattened = composite.outputImage else { throw ImagingError.encodingFailed }
        guard let cg = ImagingContext.shared.createCGImage(
            flattened,
            from: ci.extent,
            format: .RGBA8,
            colorSpace: ImagingContext.sRGB
        ) else {
            throw ImagingError.encodingFailed
        }
        return cg
    }
}

// MARK: - PNG / arbitrary payload decoding

public enum ImageDecoder {

    /// The image exactly as stored, ignoring EXIF orientation.
    ///
    /// Use this only when there is no orientation tag to honour — an inpainting
    /// response, for instance. For anything that came out of a camera, use
    /// `upright(from:)`: an iPhone photo taken in portrait is *stored*
    /// landscape, and rendering the stored raster puts the memory on its side.
    public static func cgImage(from data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImagingError.decodingFailed
        }
        return image
    }

    /// The EXIF orientation tag, or `.up` when the file carries none.
    public static func orientation(in data: Data) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
              let tag = CGImagePropertyOrientation(rawValue: raw) else {
            return .up
        }
        return tag
    }

    /// The image rotated and flipped into the orientation it is meant to be
    /// *seen* in, plus the tag that was applied.
    ///
    /// Everything downstream — the aspect ratio the layout is built from, the
    /// UVs on the depth mesh, the plate that goes to the inpainting endpoint —
    /// assumes an upright raster. The one thing that does NOT arrive upright is
    /// the auxiliary depth buffer, which is stored in the same native
    /// orientation as the pixels; `PhotoAuxiliaryDepthSource` applies the
    /// returned tag to keep the two registered.
    public static func upright(
        from data: Data
    ) throws -> (image: CGImage, orientation: CGImagePropertyOrientation) {
        let stored = try cgImage(from: data)
        let tag = Self.orientation(in: data)
        guard tag != .up else { return (stored, .up) }

        let rotated = stored.ci
            .oriented(tag)
            .normalizedToOrigin()
        let extent = CGRect(
            x: 0,
            y: 0,
            width: rotated.extent.width.rounded(),
            height: rotated.extent.height.rounded()
        )
        return (try rotated.render(cropping: extent), tag)
    }

    /// Reads the 35 mm-equivalent focal length from EXIF so the scene can
    /// reconstruct the *actual* field of view the photo was taken at, rather
    /// than guessing. Returns `nil` when the tag is absent (screenshots,
    /// scanned prints, most social-media re-encodes).
    public static func horizontalFOV(fromEXIFIn data: Data) -> Float? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double,
              focal35 > 0 else {
            return nil
        }
        // 35 mm "full frame" is 36 mm wide. Horizontal FOV of a rectilinear lens:
        //     θ_h = 2 · atan( sensorWidth / (2 · focalLength) )
        return Float(2 * atan(36.0 / (2 * focal35)))
    }
}
