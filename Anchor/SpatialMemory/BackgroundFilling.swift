//
//  BackgroundFilling.swift
//  SpatialMemory — where the occluded background comes from
//
//  PHASE 2 SEAM. `InpaintingClient` is the real implementation. `LocalBackgroundFiller`
//  is an offline stand-in that needs no network, no API key and no spend — enough
//  to prove the whole pipeline end to end and to develop Phases 3 and 4 against.
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// MARK: - The seam

public protocol BackgroundFilling: Sendable {

    /// Fills the transparent region of `plate`.
    ///
    /// - Parameters:
    ///   - plate: background with the subject punched out (transparent hole).
    ///   - mask: black RGB, alpha 0 over the hole. Same pixel size as `plate`.
    ///   - prompt: what should exist behind the subject. Implementations that
    ///     cannot use language ignore it.
    /// - Returns: an opaque image the same pixel size as `plate`.
    func fill(plate: CGImage, mask: CGImage, prompt: String) async throws -> CGImage
}

extension InpaintingClient: BackgroundFilling {
    public func fill(plate: CGImage, mask: CGImage, prompt: String) async throws -> CGImage {
        try await inpaint(plate: plate, mask: mask, prompt: prompt)
    }
}

// MARK: - Never lose the scene to a failed request

/// Which filler actually produced the background, and why.
///
/// Surface this. A hosted request that 403s because the organisation is not
/// verified for `gpt-image-1`, and a hosted request that succeeded, produce
/// scenes that look different in a way nobody can diagnose by staring at them.
public struct BackgroundFillOutcome: Sendable, Equatable {

    public enum Route: Sendable, Equatable {
        /// The network endpoint answered and its pixels are on screen.
        case hosted
        /// The endpoint failed; `LocalBackgroundFiller` covered for it. The
        /// background is smeared, not hallucinated.
        case localFallback
    }

    public let route: Route
    /// The primary filler's error, when there was one.
    public let detail: String?

    public init(route: Route, detail: String? = nil) {
        self.route = route
        self.detail = detail
    }

    public var isAI: Bool { route == .hosted }

    public var summary: String {
        switch route {
        case .hosted:
            return "Background hallucinated by the inpainting endpoint."
        case .localFallback:
            return "Inpainting endpoint unavailable — background smeared locally."
                + (detail.map { " (\($0))" } ?? "")
        }
    }
}

/// Runs `primary`, and if it throws, runs `fallback` instead of taking the
/// whole memory down with it.
///
/// Without this, one 401 from a stale key or one 403 from an unverified
/// organisation turns into `phase == .failed` and an empty immersive space —
/// which reads as "the app is broken" rather than as "the network step did not
/// run". Cancellation is deliberately NOT caught: a closing space should stop
/// work, not silently fall back and keep going.
public struct ResilientBackgroundFiller: BackgroundFilling {

    public let primary: any BackgroundFilling
    public let fallback: any BackgroundFilling
    private let report: (@Sendable (BackgroundFillOutcome) -> Void)?

    public init(
        primary: any BackgroundFilling,
        fallback: any BackgroundFilling = LocalBackgroundFiller(),
        onOutcome: (@Sendable (BackgroundFillOutcome) -> Void)? = nil
    ) {
        self.primary = primary
        self.fallback = fallback
        self.report = onOutcome
    }

    public func fill(plate: CGImage, mask: CGImage, prompt: String) async throws -> CGImage {
        do {
            let filled = try await primary.fill(plate: plate, mask: mask, prompt: prompt)
            report?(BackgroundFillOutcome(route: .hosted))
            return filled
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let outcome = BackgroundFillOutcome(
                route: .localFallback,
                detail: error.localizedDescription
            )
            // Printed as well as reported: a host app that ignores the closure
            // still gets the reason in the console instead of a mystery.
            print("[SpatialMemory] \(outcome.summary)")
            report?(outcome)

            // The primary and the fallback want DIFFERENT plates, and handing
            // one the other's is a spectacular failure rather than a subtle one.
            //
            // LaMa wants the untouched photograph: it decides what to erase from
            // the mask and continues the surroundings better for having seen
            // what stood there. `LocalBackgroundFiller` invents nothing — it
            // borrows real pixels from elsewhere in the frame by compositing the
            // plate over copies of itself shifted sideways. Give THAT the
            // untouched photograph and the pixels nearest to the hole, the ones
            // it reaches for first, are the subject's own: it slides a copy of
            // the person into the space the person just vacated, and you get the
            // same face twice, smeared. Punch the hole first and there is
            // nothing of them left to borrow.
            let punched = (try? Self.punchingHole(in: plate, using: mask)) ?? plate
            return try await fallback.fill(plate: punched, mask: mask, prompt: prompt)
        }
    }

    /// `plate` with everything the mask marks as foreground removed, leaving
    /// transparency.
    static func punchingHole(in plate: CGImage, using mask: CGImage) throws -> CGImage {
        let extent = CGRect(origin: .zero, size: plate.size)
        let hole = LocalBackgroundFiller.holeMask(fromAPIMask: mask.ci).cropped(to: extent)
        // Alpha-preserving, because this mask goes to `CIBlendWithMask`, which
        // reads alpha. Plain `invert` would zero it and select the clear
        // background across the entire frame.
        let keep = MaskAlgebra.invertKeepingAlpha(hole).cropped(to: extent)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        let punched = MatteCompositor.blend(
            input: plate.ci,
            background: clear,
            mask: keep,
            extent: extent
        )
        return try punched.render(cropping: extent)
    }
}

// MARK: - Offline filler

/// Fills the hole with colour carried in from its rim, then defocuses it.
///
/// This is **not** inpainting and does not pretend to be. It invents no
/// structure — it continues colour. Against a wall, a floor, a blurred room it
/// is convincing enough that the parallax reads correctly, which is all a
/// fallback has to do. Against strong structure running behind the subject —
/// a bookshelf, a window frame, a doorway — it produces a soft smear where the
/// lines should continue, and the honest fix for that is to get the network
/// filler working, not to tune this.
///
/// Two passes:
///
///   1. **Push-pull.** A pyramid: halve the image repeatedly so every hole is
///      averaged out of existence, then walk back up letting known pixels win.
///      Scale free, so it does not care how large or how oddly shaped the hole
///      is — which the offset-and-diffuse scheme it replaced very much did.
///   2. **Defocus.** Blur re-applied *only inside the hole*, so the fill reads
///      as out-of-focus background rather than as a flat wash.
public struct LocalBackgroundFiller: BackgroundFilling {

    /// Unused since the fill became push-pull, which has no pass count. Kept so
    /// existing initializer calls still compile.
    public var diffusionPasses: Int
    /// Defocus radius as a fraction of the hole's width.
    public var defocusFraction: CGFloat
    /// Unused since the fill became push-pull. Kept for source compatibility.
    public var offsetFactor: CGFloat

    public init(
        diffusionPasses: Int = 5,
        defocusFraction: CGFloat = 0.035,
        offsetFactor: CGFloat = 1.12
    ) {
        self.diffusionPasses = diffusionPasses
        self.defocusFraction = defocusFraction
        self.offsetFactor = offsetFactor
    }

    public func fill(plate: CGImage, mask: CGImage, prompt: String) async throws -> CGImage {
        // `prompt` is deliberately unused. Say so rather than let a caller
        // believe the words are doing something.
        _ = prompt

        let extent = CGRect(x: 0, y: 0, width: plate.width, height: plate.height)
        let plateCI = plate.ci

        // hole = 1 where the API mask said alpha 0.
        let hole = Self.holeMask(fromAPIMask: mask.ci).cropped(to: extent)
        let holeRect = try Self.bounds(ofHole: hole, in: extent)
        let holeWidth = max(holeRect.width, 8)

        // ---- Fill, by pyramid push-pull ---------------------------------
        //
        // This replaces two passes that both assumed ONE hole of MODEST size,
        // and fail together on a group photo.
        //
        // The old pass 1 composited the plate over copies of itself shifted by
        // 1.12 × the hole's width, to back the gap with real background from
        // either side. But the hole's width is the bounding box of EVERY hole,
        // so with five people spread across the frame it is nearly the frame —
        // the shifted copies land almost entirely outside it and contribute
        // nothing. The old pass 2 then diffused inward starting at a radius of
        // a third of the frame, which cannot reach the middle of a hole that
        // size either. What survived was transparency, and the step that
        // "guaranteed opacity" flattened it over the frame's MEAN COLOUR.
        //
        // That is where the grey blobs came from: not a fill at all, just the
        // average of the photograph, in the exact silhouette of the people
        // removed from it.
        //
        // Push-pull has no characteristic length, so no hole is too big for it.
        // PULL: halve the image repeatedly. Core Image composites in
        // premultiplied alpha, so a downsample is already an alpha-WEIGHTED
        // colour average — a transparent pixel contributes nothing and an
        // opaque one contributes fully, which is exactly the pull rule. By the
        // coarsest level every hole has been averaged out of existence. PUSH:
        // walk back up, letting the known pixels of each finer level win over
        // the upsampled coarser one. Colour flows in from the whole rim at
        // every scale at once.
        var filled = Self.pushPull(plateCI, extent: extent)

        // ---- Pass 3: defocus, inside the hole only ----------------------
        let defocus = CIFilter.gaussianBlur()
        defocus.inputImage = filled.clampedToExtent()
        defocus.radius = Float(max(holeWidth * defocusFraction, 1.0))
        let soft = (defocus.outputImage ?? filled).cropped(to: extent)

        // Feather the hole mask itself so the sharp/soft boundary is a ramp and
        // not a visible cut following the subject's silhouette.
        let rampBlur = CIFilter.gaussianBlur()
        rampBlur.inputImage = hole.clampedToExtent()
        rampBlur.radius = Float(max(holeWidth * 0.04, 2.0))
        let ramp = (rampBlur.outputImage ?? hole).cropped(to: extent)

        filled = MatteCompositor.blend(input: soft, background: filled, mask: ramp, extent: extent)

        return try filled.render(cropping: extent)
    }

    // MARK: Push-pull

    /// Fills every transparent region with colour carried in from its rim, at
    /// every scale, for holes of any size or shape.
    static func pushPull(_ image: CIImage, extent: CGRect) -> CIImage {

        var sizes: [CGSize] = [extent.size]
        var levels: [CIImage] = [image.cropped(to: extent)]

        while let last = sizes.last, min(last.width, last.height) > 2 {
            let next = CGSize(
                width: max(1, (last.width / 2).rounded(.down)),
                height: max(1, (last.height / 2).rounded(.down))
            )
            let down = levels[levels.count - 1]
                .samplingLinear()
                .transformed(by: CGAffineTransform(
                    scaleX: next.width / last.width,
                    y: next.height / last.height
                ))
                .cropped(to: CGRect(origin: .zero, size: next))
            levels.append(down)
            sizes.append(next)
        }

        // The coarsest level is a couple of pixels of the whole photograph, and
        // its alpha is the fraction of the frame that survived — 0.6, say, if
        // the subjects covered 40% of it. Left like that the push would carry
        // that translucency all the way back up and the fill would composite
        // toward black. Un-premultiplying turns it into the true alpha-weighted
        // colour and lets the alpha be forced to 1 without darkening anything.
        var result = Self.forcedOpaque(levels.removeLast())
        var resultSize = sizes.removeLast()

        while let finer = levels.popLast() {
            let finerSize = sizes.removeLast()
            let finerExtent = CGRect(origin: .zero, size: finerSize)
            let up = result
                .samplingLinear()
                .transformed(by: CGAffineTransform(
                    scaleX: finerSize.width / resultSize.width,
                    y: finerSize.height / resultSize.height
                ))
                .cropped(to: finerExtent)
            result = Self.over(finer, up, extent: finerExtent)
            resultSize = finerSize
        }

        return result.cropped(to: extent)
    }

    /// Straight-alpha colour at full opacity.
    static func forcedOpaque(_ image: CIImage) -> CIImage {
        let straight = image.unpremultiplyingAlpha()
        let f = CIFilter.colorMatrix()
        f.inputImage = straight
        f.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return f.outputImage ?? image
    }

    // MARK: Helpers

    /// `1 − alpha` of the API mask: 1 inside the hole, 0 everywhere else.
    static func holeMask(fromAPIMask mask: CIImage) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = mask
        f.rVector = CIVector(x: 0, y: 0, z: 0, w: -1)
        f.gVector = CIVector(x: 0, y: 0, z: 0, w: -1)
        f.bVector = CIVector(x: 0, y: 0, z: 0, w: -1)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.biasVector = CIVector(x: 1, y: 1, z: 1, w: 1)
        return f.outputImage ?? mask
    }

    static func over(_ top: CIImage, _ bottom: CIImage, extent: CGRect) -> CIImage {
        let f = CIFilter.sourceOverCompositing()
        f.inputImage = top
        f.backgroundImage = bottom
        return (f.outputImage ?? top).cropped(to: extent)
    }

    /// Bounding box of the hole, found by rasterizing a small probe and scanning
    /// it. A 96 px probe is a few thousand pixels — cheaper than any filter
    /// chain, and exact enough to size a shift.
    static func bounds(ofHole hole: CIImage, in extent: CGRect, probe: Int = 96) throws -> CGRect {
        let w = probe
        let h = max(1, Int((CGFloat(probe) * extent.height / extent.width).rounded()))

        let scaled = hole.transformed(by: CGAffineTransform(
            scaleX: CGFloat(w) / extent.width,
            y: CGFloat(h) / extent.height
        ))

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        ImagingContext.shared.render(
            scaled,
            toBitmap: &pixels,
            rowBytes: w * 4,
            bounds: CGRect(x: 0, y: 0, width: w, height: h),
            format: .RGBA8,
            colorSpace: ImagingContext.sRGB
        )

        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4] > 128 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }

        // No hole at all — the caller gave us a plate with nothing removed.
        guard maxX >= minX, maxY >= minY else {
            return CGRect(x: extent.midX, y: extent.midY, width: 0, height: 0)
        }

        let sx = extent.width / CGFloat(w)
        let sy = extent.height / CGFloat(h)
        return CGRect(
            x: CGFloat(minX) * sx,
            y: CGFloat(minY) * sy,
            width: CGFloat(maxX - minX + 1) * sx,
            height: CGFloat(maxY - minY + 1) * sy
        )
    }

    /// Mean colour, un-premultiplied so a partially transparent input does not
    /// come back darker than it looks.
    static func meanColor(of image: CIImage, extent: CGRect) -> CIColor {
        let f = CIFilter.areaAverage()
        f.inputImage = image
        f.extent = extent
        guard let out = f.outputImage else { return CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1) }

        var px = [UInt8](repeating: 0, count: 4)
        ImagingContext.shared.render(
            out,
            toBitmap: &px,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: ImagingContext.sRGB
        )

        let a = CGFloat(px[3]) / 255
        guard a > 0.01 else { return CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1) }
        return CIColor(
            red:   min(CGFloat(px[0]) / 255 / a, 1),
            green: min(CGFloat(px[1]) / 255 / a, 1),
            blue:  min(CGFloat(px[2]) / 255 / a, 1),
            alpha: 1
        )
    }
}
