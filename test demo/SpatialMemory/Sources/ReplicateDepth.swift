//
//  ReplicateDepth.swift
//  SpatialMemory — depth that was measured by a model instead of guessed
//
//  ============================================================================
//  WHY THIS IS THE IMPORTANT FILE
//
//  Everything downstream of depth is exact. The pinhole inversion in `DepthMesh`
//  guarantees the displaced mesh reprojects onto the photograph. The tearing is
//  a clean contour. The layer split is correct. All of it is faithful
//  arithmetic — applied to a depth field that, for any photo without LiDAR,
//  `ImageCueDepthSource` invented out of focus, a ground-plane prior and haze.
//
//  That is what "the 3D looks off" is. Not a rendering bug. A measurement that
//  was never taken.
//
//  Depth Pro (Apple, 2024) takes it: metric depth in real metres from one image,
//  plus the focal length the camera must have had, with boundaries sharp enough
//  that the guided filter downstream has almost nothing left to correct. Two
//  consequences beyond "the shapes are right":
//
//    * SCALE. A normalized 0-1 field has to be mapped onto some arbitrary near
//      and far — this project used 1.5 m and 4.5 m — so a hallway and a
//      landscape came out the same depth, which is what makes a reconstruction
//      read as a diorama. Metres remove the arbitrariness.
//    * FIELD OF VIEW. Without an EXIF focal length the layout fell back to 63°.
//      Get that wrong and every proportion in the room is wrong with it.
//
//  ============================================================================
//  ON THE OUTPUT SHAPE
//
//  The wrapper's field names are not documented anywhere reachable, and they
//  differ between mirrors of the same model. So this does not guess once and
//  fail silently: it tries a list of candidate keys, and when none match it
//  throws an error naming the fields that WERE present, so the fix is to paste
//  one of them into `depthOutputKeys` rather than to go reading someone's
//  cog.yaml. Turn on `ReplicateAPI.logsRawOutput` to see the whole shape.
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import Foundation

// MARK: - Configuration

public struct ReplicateDepthConfiguration: Sendable {

    public var model: String
    public var version: String?

    /// The model's input field for the image, tried in order.
    ///
    /// Output keys can be discovered from a response; an INPUT key cannot — get
    /// it wrong and the model replies 422 having done nothing. Different LaMa
    /// and Depth Pro wrappers spell this differently, so rather than bet the
    /// first run on one guess, walk the list until one is accepted. Only a 4xx
    /// advances to the next candidate; a 5xx or a timeout is the network, not
    /// the spelling, and retrying with a different key would just hide it.
    public var imageInputKeys: [String]

    /// Candidate output fields holding the depth raster, tried in order.
    public var depthOutputKeys: [String]

    /// Candidate output fields holding the focal length in pixels.
    public var focalOutputKeys: [String]

    /// Candidate output fields holding the metric extent of the raster, so a
    /// normalized image can be turned back into metres.
    public var minDepthKeys: [String]
    public var maxDepthKeys: [String]

    /// Which end of the returned raster is near.
    public var polarity: Polarity

    public enum Polarity: Sendable, Equatable {
        /// Bright pixels are close. The usual convention for a depth preview.
        case nearIsBright
        /// Bright pixels are far. What you get from a raw distance buffer.
        case nearIsDark
        /// Decide per image from the ground-plane prior: in almost any
        /// handheld photograph the bottom of the frame is nearer than the top.
        /// Picking a SIGN this way is reliable in a way that estimating depth
        /// this way is not — it is one bit, from a very strong prior.
        case auto
    }

    /// Long edge the image is resampled to before upload.
    public var uploadLongEdge: Int

    /// Long edge of the grid the depth is sampled onto.
    public var resolution: Int

    public var timeout: TimeInterval
    public var maxRetries: Int

    public init(
        model: String = "garg-aayush/ml-depth-pro",
        version: String? = nil,
        imageInputKeys: [String] = ["image_path", "image", "input_image"],
        depthOutputKeys: [String] = [
            "depth_image", "grayscale_depth", "depth", "depth_map",
            "gray_depth", "output", "image"
        ],
        focalOutputKeys: [String] = [
            "focallength_px", "focal_length_px", "focal_length", "focallength"
        ],
        minDepthKeys: [String] = ["min_depth", "depth_min", "near"],
        maxDepthKeys: [String] = ["max_depth", "depth_max", "far"],
        polarity: Polarity = .auto,
        uploadLongEdge: Int = 1024,
        resolution: Int = 384,
        timeout: TimeInterval = 120,
        maxRetries: Int = 3
    ) {
        self.model = model
        self.version = version
        self.imageInputKeys = imageInputKeys
        self.depthOutputKeys = depthOutputKeys
        self.focalOutputKeys = focalOutputKeys
        self.minDepthKeys = minDepthKeys
        self.maxDepthKeys = maxDepthKeys
        self.polarity = polarity
        self.uploadLongEdge = uploadLongEdge
        self.resolution = resolution
        self.timeout = timeout
        self.maxRetries = maxRetries
    }
}

public enum ReplicateDepthError: LocalizedError {
    case colourised(model: String)

    public var errorDescription: String? {
        switch self {
        case let .colourised(model):
            return """
            \(model) returned a COLOURISED depth preview, not a depth raster. \
            Those pixels are a viridis/inferno lookup of the depth, and reading \
            them as values produces geometry that is confidently wrong rather \
            than obviously broken. Point depthOutputKeys at the model's \
            grayscale or raw output instead.
            """
        }
    }
}

// MARK: - The source

public struct ReplicateDepthSource: DepthSource {

    public let api: ReplicateAPI
    public let configuration: ReplicateDepthConfiguration

    public init(api: ReplicateAPI, configuration: ReplicateDepthConfiguration = .init()) {
        self.api = api
        self.configuration = configuration
    }

    public func depth(for image: CGImage, sourceData: Data?) async throws -> DepthMap {

        let upload = try ReplicateInpaintingClient.fit(image, longEdge: configuration.uploadLongEdge)
        let png = try PNGEncoder.encode(upload, preserveAlpha: false)

        let uri = ReplicateAPI.dataURI(png)
        var output: ReplicateValue?
        var lastError: Error?

        for key in configuration.imageInputKeys {
            do {
                output = try await api.run(
                    model: configuration.model,
                    version: configuration.version,
                    input: [key: uri],
                    timeout: configuration.timeout,
                    maxRetries: configuration.maxRetries
                )
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ReplicateAPIError {
                guard case let .http(status, _) = error, (400..<500).contains(status) else {
                    throw error          // not a naming problem
                }
                print("[SpatialMemory] \(configuration.model) rejected input key "
                      + "\"\(key)\" — \(error.localizedDescription)")
                lastError = error
            }
        }

        guard let output else {
            throw lastError ?? ReplicateAPIError.noOutput
        }

        guard let reference = output.string(forAnyOf: configuration.depthOutputKeys) else {
            throw ReplicateAPIError.outputShape(
                expected: "depth raster under any of \(configuration.depthOutputKeys)",
                keysPresent: output.availableKeys
            )
        }

        let raster = try await api.image(at: reference)
        guard try Self.isGrayscale(raster) else {
            throw ReplicateDepthError.colourised(model: configuration.model)
        }

        // --- sample onto the working grid --------------------------------
        let (gw, gh) = PhotoAuxiliaryDepthSource.gridSize(for: image, longEdge: configuration.resolution)
        var values = try GuidedDepthRefinement.luminance(of: raster, width: gw, height: gh)

        let nearIsBright: Bool
        switch configuration.polarity {
        case .nearIsBright: nearIsBright = true
        case .nearIsDark:   nearIsBright = false
        case .auto:         nearIsBright = Self.brightEndIsNear(values, width: gw, height: gh)
        }
        // Project convention is 0 = nearest.
        if nearIsBright {
            for i in values.indices { values[i] = 1 - values[i] }
        }

        // --- stretch, and carry the metric scale if the model gave one ----
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for v in values { lo = min(lo, v); hi = max(hi, v) }
        let span = max(hi - lo, 1e-6)
        for i in values.indices { values[i] = (values[i] - lo) / span }

        var metricRange: ClosedRange<Float>?
        if let near = output.number(forAnyOf: configuration.minDepthKeys).map(Float.init),
           let far = output.number(forAnyOf: configuration.maxDepthKeys).map(Float.init),
           near.isFinite, far.isFinite, far > near, near > 0 {
            metricRange = near...far
        }

        // f in pixels and the width it was measured against are in the same
        // space, so the ratio — and therefore the angle — is scale invariant.
        var fov: Float?
        if let focal = output.number(forAnyOf: configuration.focalOutputKeys).map(Float.init),
           focal > 1 {
            let width = Float(raster.width)
            let angle = 2 * atan(width / (2 * focal))
            // Anything outside 20°–140° is a parse gone wrong, not a lens.
            if angle > 0.35, angle < 2.45 { fov = angle }
        }

        return DepthMap(
            width: gw,
            height: gh,
            values: values,
            isMeasured: true,
            metricRange: metricRange,
            estimatedHorizontalFOV: fov
        )
    }

    // MARK: Sanity checks

    /// True when the raster is (near enough) grayscale.
    ///
    /// A colourmapped preview read as data does not look broken, it looks
    /// plausible and is wrong — the geometry follows the colour ramp's
    /// luminance, which is not monotonic in depth. Better to refuse.
    static func isGrayscale(_ image: CGImage, samples: Int = 24) throws -> Bool {
        let w = min(samples, image.width)
        let h = min(samples, image.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &bytes,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: ImagingContext.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImagingError.rasterizationFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var chromatic = 0
        for i in 0..<(w * h) {
            let r = Int(bytes[i * 4]), g = Int(bytes[i * 4 + 1]), b = Int(bytes[i * 4 + 2])
            if max(r, max(g, b)) - min(r, min(g, b)) > 24 { chromatic += 1 }
        }
        // A little chroma is JPEG ringing; a third of the frame is a colourmap.
        return Float(chromatic) / Float(w * h) < 0.15
    }

    /// The ground-plane prior, used only to pick a sign: the bottom eighth of a
    /// handheld frame is nearer than the top eighth far more often than not.
    static func brightEndIsNear(_ values: [Float], width: Int, height: Int) -> Bool {
        let band = max(1, height / 8)
        var top: Float = 0, bottom: Float = 0
        for y in 0..<band {
            for x in 0..<width {
                top += values[y * width + x]
                bottom += values[(height - 1 - y) * width + x]
            }
        }
        // If the bottom of the frame is brighter, bright means near.
        return bottom > top
    }
}
