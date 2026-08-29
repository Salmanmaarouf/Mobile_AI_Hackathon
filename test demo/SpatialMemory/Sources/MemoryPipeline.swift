//
//  MemoryPipeline.swift
//  SpatialMemory — PHASE 4a: Orchestration
//
//  Segment → inpaint → hand back a MainActor-ready asset bundle.
//
//  Everything expensive happens here, off the main actor. Nothing in this file
//  touches RealityKit, which is the point: by the time the scene builder runs,
//  the only remaining work is uploading textures.
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

// MARK: - Configuration

public struct PipelineOptions: Sendable {

    /// Which raster is sent as the `image` field of the edits request.
    public enum SourceStrategy: Sendable {
        /// The punched-out plate. Unambiguous — the model cannot "helpfully"
        /// keep the subject, because the pixels are simply gone.
        case plate
        /// The untouched photograph, with the hole expressed only in the mask.
        /// Usually hallucinates better (the model sees the subject's lighting,
        /// shadow and contact points and continues them), at the cost of
        /// occasionally leaving a ghost of the original subject.
        case originalWithMaskOnly
    }

    public var sourceStrategy: SourceStrategy
    public var matting: MattingOptions
    public var layoutBackgroundDistance: Float
    public var layoutForegroundDistance: Float
    /// Used when EXIF carries no 35 mm-equivalent focal length.
    /// 63° ≈ a 28 mm-equivalent phone main camera.
    public var fallbackHorizontalFOV: Float

    /// How far the backdrop is padded beyond the photograph's own field of view,
    /// as a multiple. The padding is a blurred continuation of the photo's edges
    /// and fades to nothing, so the frame dissolves instead of stopping. 1.0
    /// disables it and gives you a hard rectangle.
    public var backdropOverscan: Float

    /// Paint a large enclosing sphere with a darkened wash of the photograph.
    /// Costs one 128 px texture and removes the black void around the frame.
    public var ambientSurround: Bool

    /// Continue the photograph outward into the overscan ring with the filler,
    /// instead of padding it with a blurred smear of its own edges.
    ///
    /// A 63° photograph does not fill a 100°+ headset, so the frame has to go
    /// somewhere. Blur-extending it reads as fog; continuing walls, floors and
    /// furniture outward reads as a room that carries on past what the camera
    /// caught. LaMa is a good fit here — a border continuation with intact
    /// context on the inside edge is the same problem as a hole with context on
    /// both sides, and it still cannot invent a person into the periphery.
    ///
    /// Costs one extra prediction per memory. Off leaves the blurred padding.
    public var outpaintSurround: Bool

    /// Build the foreground as a depth-displaced, torn mesh rather than a flat
    /// plane. This is what turns a cutout that slides into a scene with shape.
    ///
    /// It also replaces segmentation: what needs inventing behind the subject is
    /// whatever the near geometry occludes, which is a depth question rather
    /// than a "which pixels are a person" question — and unlike Vision, it runs
    /// in the simulator.
    public var useDepthMesh: Bool

    /// Normalized depth below which a pixel counts as near-field and gets
    /// punched out for inpainting. Raise it to treat more of the frame as
    /// foreground.
    public var nearFieldThreshold: Float

    /// Ask the filler only for the ribbon a moving viewer actually uncovers,
    /// rather than for every pixel behind the near field.
    ///
    /// Leave this on. With it off the mask on a group photo covers most of the
    /// frame, and an inpainting model given a mask that size has no surrounding
    /// structure left to continue — it returns smooth low-frequency colour,
    /// which reads as flat grey shapes exactly where the people were. That is
    /// not the model failing; it is the model being asked the wrong question.
    public var occlusionBandOnly: Bool

    /// Width of that ribbon as a fraction of the long edge. See
    /// `DepthMesh.occlusionBand` for the parallax derivation and the measured
    /// trade-off — 0.04 covers roughly a 10 cm lean and shrinks the mask by
    /// about 60% on a group photo, which is what pulls it out of the regime
    /// where an inpainting model returns featureless colour.
    public var occlusionBandFraction: CGFloat

    public var audioResourceName: String?

    public init(
        sourceStrategy: SourceStrategy = .plate,
        matting: MattingOptions = .default,
        layoutBackgroundDistance: Float = 5.0,
        layoutForegroundDistance: Float = 1.5,
        fallbackHorizontalFOV: Float = 63.0 * .pi / 180.0,
        backdropOverscan: Float = 1.45,
        ambientSurround: Bool = true,
        outpaintSurround: Bool = true,
        useDepthMesh: Bool = true,
        nearFieldThreshold: Float = 0.42,
        occlusionBandOnly: Bool = true,
        occlusionBandFraction: CGFloat = 0.04,
        audioResourceName: String? = nil
    ) {
        self.sourceStrategy = sourceStrategy
        self.matting = matting
        self.layoutBackgroundDistance = layoutBackgroundDistance
        self.layoutForegroundDistance = layoutForegroundDistance
        self.fallbackHorizontalFOV = fallbackHorizontalFOV
        self.backdropOverscan = backdropOverscan
        self.ambientSurround = ambientSurround
        self.outpaintSurround = outpaintSurround
        self.useDepthMesh = useDepthMesh
        self.nearFieldThreshold = nearFieldThreshold
        self.occlusionBandOnly = occlusionBandOnly
        self.occlusionBandFraction = occlusionBandFraction
        self.audioResourceName = audioResourceName
    }

    public static let `default` = PipelineOptions()
}

// MARK: - Progress

public enum MemoryPipelinePhase: Sendable, Equatable {
    case segmenting
    case inpainting
    case ready
    case failed(String)
}

/// `@unchecked Sendable`: CGImage is an immutable CF value; see ImagingCore.swift.
public struct MemoryBuildResult: @unchecked Sendable {
    public let assets: MemoryAssets
    public let layout: ParallaxLayout
    public let segmentation: SegmentationResult
}

// MARK: - Pipeline

public actor MemoryPipeline {

    private let segmenter: ForegroundSegmentationService
    private let filler: any BackgroundFilling
    private let depthSource: any DepthSource

    /// - Parameters:
    ///   - filler: `InpaintingClient` in production, `LocalBackgroundFiller`
    ///     for offline work. See BackgroundFilling.swift.
    ///   - segmenter: defaults to a service using
    ///     `MatteSourceFactory.automatic()`, which is Vision on device and the
    ///     elliptical placeholder in a simulator.
    ///   - depthSource: real depth from the file when it carries one, an
    ///     estimate from image cues otherwise. Both run in the simulator.
    /// - Parameter depthSource: where per-pixel depth comes from. `nil` picks
    ///   `DepthSourceFactory.automatic()`, which reads the camera's own map when
    ///   the file carries one and otherwise ESTIMATES from image cues — an
    ///   informed guess, and the single largest source of "the 3D looks off"
    ///   on any photo without LiDAR. Pass `ReplicateDepthSource` to replace the
    ///   guess with a measurement.
    public init(
        filler: any BackgroundFilling,
        segmenter: ForegroundSegmentationService = .init(),
        depthSource: (any DepthSource)? = nil
    ) {
        self.filler = filler
        self.segmenter = segmenter
        self.depthSource = depthSource ?? DepthSourceFactory.automatic()
    }

    /// The whole 2D → 6DOF transformation, minus the RealityKit upload.
    ///
    /// - Parameter sourceData: the original file bytes, used only to read EXIF.
    ///   Pass `nil` and the pipeline falls back to `options.fallbackHorizontalFOV`.
    /// - Parameter onPhase: fired as each stage begins. Non-isolated and
    ///   `Sendable` so callers can hop to the main actor themselves.
    public func build(
        from image: CGImage,
        sourceData: Data? = nil,
        prompt: String,
        options: PipelineOptions = .default,
        onPhase: (@Sendable (MemoryPipelinePhase) -> Void)? = nil
    ) async throws -> MemoryBuildResult {

        // ------------------------------------------------------------------
        // 1. Segment. CPU/ANE-bound, ~200–900 ms for a 12 MP frame.
        // ------------------------------------------------------------------
        onPhase?(.segmenting)
        try Task.checkCancellation()

        var depth: DepthMap?
        let segmentation: SegmentationResult

        if options.useDepthMesh {
            // Depth first, and it does double duty: it shapes the mesh, and the
            // near-field it identifies is what needs inventing behind. One pass
            // replaces segmentation entirely — and works where Vision cannot.
            let map = try await depthSource.depth(for: image, sourceData: sourceData)
            depth = map

            let nearField = try DepthMesh.nearFieldMatte(
                depth: map,
                matching: image.size,
                threshold: options.nearFieldThreshold
            )
            segmentation = try MatteCompositor.derive(
                source: image,
                rawMatte: RawMatte(image: nearField.ci, instanceCount: 1),
                options: options.matting
            )
        } else {
            segmentation = try await segmenter.segment(image, options: options.matting)
        }

        // ------------------------------------------------------------------
        // 2. Inpaint. Network-bound, tens of seconds. Cancellation is checked
        //    on the way in and honoured inside the client's retry loop.
        // ------------------------------------------------------------------
        onPhase?(.inpainting)
        try Task.checkCancellation()

        let uploadImage: CGImage
        switch options.sourceStrategy {
        case .plate:
            uploadImage = segmentation.backgroundPlate
        case .originalWithMaskOnly:
            uploadImage = segmentation.source
        }

        // What the filler is actually asked for. The full near-field matte is
        // the WRONG question — see `DepthMesh.occlusionBand`. Only the ribbon
        // around each silhouette is ever uncovered, and a narrow gap with intact
        // context on both sides is the regime an inpainting model is good in.
        var occlusion = segmentation.inpaintMask
        if options.occlusionBandOnly, let map = depth {
            occlusion = (try? DepthMesh.occlusionBand(
                depth: map,
                matching: image.size,
                threshold: options.nearFieldThreshold,
                bandFraction: options.occlusionBandFraction
            )) ?? segmentation.inpaintMask
        }

        let filled = try await filler.fill(
            plate: uploadImage,
            mask: occlusion,
            prompt: prompt
        )

        // ------------------------------------------------------------------
        // 2b. Put the model's work ONLY where the model was needed.
        //
        // Every filler returns a whole frame, and it is tempting to just use it
        // — that is what this pipeline used to do, and it is why reconstructions
        // came back subtly wrong everywhere at once. The whiteboard was never
        // occluded. The pattern on the wall was never occluded. Handing those
        // pixels to a model and taking back its versions of them trades known
        // truth for plausible invention across the entire frame, and a viewer
        // reads the result as "that isn't quite the room" without being able to
        // say why.
        //
        // For a memory someone is being asked to recognise, that is the whole
        // ballgame. So: original pixels wherever the camera actually saw them,
        // model pixels strictly inside the hole, one blend along the mask.
        // ------------------------------------------------------------------
        var inpainted = try Self.composite(
            fill: filled,
            over: segmentation.source,
            hole: occlusion
        )

        // ------------------------------------------------------------------
        // 2c. Take the subject out of the BACKGROUND layer.
        //
        // Asking the model only for the ribbon leaves the photograph's own
        // pixels everywhere else — the people included. Those pixels then get
        // painted onto the background mesh, which sits at the filled depth,
        // metres behind where the people actually stood. So each person is drawn
        // twice at two distances, and the far copy slides out from behind the
        // near one the moment the viewer moves. Ghost twins.
        //
        // The interior of a subject's footprint is never revealed by parallax,
        // so it does not need the model — it only needs to stop being a face.
        // Push-pull floods it with colour drawn in from the ribbon, which by now
        // carries the model's real continuation, so the two agree at the seam.
        // ------------------------------------------------------------------
        if options.occlusionBandOnly, let map = depth {
            if let core = try? DepthMesh.nearFieldCore(
                depth: map,
                matching: image.size,
                threshold: options.nearFieldThreshold,
                bandFraction: options.occlusionBandFraction
            ), let cleaned = try? Self.floodBehindSubject(in: inpainted, core: core) {
                inpainted = cleaned
            }
        }

        // ------------------------------------------------------------------
        // 3. Derive the layout.
        //
        // The FOV is the one number that decides whether the reconstruction
        // feels like the original photograph or like a poster of it, so we read
        // it from EXIF whenever the file still carries the tag.
        // ------------------------------------------------------------------
        // EXIF is ground truth when the file still has it. A depth model that
        // estimates the camera is a good second. The 63° fallback is a guess
        // that makes every proportion in the room wrong when it is wrong.
        let fov = sourceData.flatMap(ImageDecoder.horizontalFOV(fromEXIFIn:))
            ?? depth?.estimatedHorizontalFOV
            ?? options.fallbackHorizontalFOV

        // If the depth came back in metres, the room is the size it really was
        // and the fixed 1.5 m / 5 m are not needed. Clamped, because a single
        // wild value in a depth raster should not put the backdrop in orbit.
        var foregroundDistance = options.layoutForegroundDistance
        var backgroundDistance = options.layoutBackgroundDistance
        if let metric = depth?.metricRange {
            foregroundDistance = min(max(metric.lowerBound, 0.4), 8)
            backgroundDistance = min(max(metric.upperBound, foregroundDistance + 0.5), 30)
        }

        let layout = ParallaxLayout(
            horizontalFOV: fov,
            aspect: Float(segmentation.aspectRatio),
            backgroundDistance: backgroundDistance,
            foregroundDistance: foregroundDistance
        )

        // ------------------------------------------------------------------
        // 4. Dissolve the frame's edges.
        //
        // Geometrically the reconstruction is finished at this point. It will
        // still look like a picture hanging in a void, because a 63° photograph
        // does not fill a 100°+ headset. Padding the backdrop with a blurred
        // continuation, fading its rim to nothing, and washing the periphery
        // with the photo's own colours is what turns the frame into a place.
        // ------------------------------------------------------------------
        let backdrop = try BackdropTextures.make(
            from: inpainted,
            overscan: options.ambientSurround ? options.backdropOverscan : 1.0
        )

        // ------------------------------------------------------------------
        // 5. Split the frame into layers.
        //
        // The foreground mesh is torn open at every silhouette, and something
        // has to be visible through those holes that is not a flat plane. So
        // the background gets its own complete depth mesh: the same depth field
        // with the near field removed and the gap's geometry diffused in from
        // its rim, wearing the composited colour. The room keeps receding
        // behind the people instead of ending in a wall at five metres.
        // ------------------------------------------------------------------
        let backgroundDepth = depth?.fillingNearField(below: options.nearFieldThreshold)

        // ------------------------------------------------------------------
        // 4b. Continue the frame outward, rather than smearing it outward.
        //
        // `BackdropTextures` has already filled the overscan ring with a blurred
        // extension of the edge pixels, which is why the periphery reads as fog.
        // The ring is a border-continuation problem with intact photograph on
        // its inner edge — the same shape of problem as the occlusion ribbon —
        // so the same filler handles it, and the result is walls and floors that
        // carry on instead of dissolving.
        // ------------------------------------------------------------------
        var widened = backdrop.padded
        if options.outpaintSurround, backdrop.overscan > 1.01 {
            try Task.checkCancellation()
            if let ring = try? Self.overscanRingMask(
                canvas: backdrop.padded.size,
                overscan: CGFloat(backdrop.overscan)
            ),
               let painted = try? await filler.fill(
                   plate: backdrop.padded,
                   mask: ring,
                   prompt: prompt
               ),
               let merged = try? Self.composite(
                   fill: painted,
                   over: backdrop.padded,
                   hole: ring
               ) {
                widened = merged
            }
        }

        let assets = MemoryAssets(
            background: widened,
            // Original RGB, not the premultiplied cutout — see MemoryAssets.
            foregroundColor: segmentation.source,
            foregroundMatte: segmentation.matte,
            backdropVignette: backdrop.vignette,
            ambient: options.ambientSurround ? backdrop.ambient : nil,
            backdropOverscan: backdrop.overscan,
            depth: depth,
            backgroundLayer: backgroundDepth == nil ? nil : inpainted,
            backgroundDepth: backgroundDepth,
            nearFieldThreshold: options.nearFieldThreshold,
            audioResourceName: options.audioResourceName
        )

        onPhase?(.ready)
        return MemoryBuildResult(assets: assets, layout: layout, segmentation: segmentation)
    }
}

// MARK: - Keeping the photograph

extension MemoryPipeline {

    /// `fill` inside the hole, `original` everywhere else.
    ///
    /// `blendWithMask` takes the input where the mask is white. The project's
    /// API mask is the other convention — black RGB with alpha 0 over the hole —
    /// so it is converted to a hole mask first, which is the same one-line
    /// conversion the local filler and the Replicate client both make.
    /// A mask marking everything OUTSIDE the original photograph's rectangle
    /// within the overscanned canvas, in the project's convention: black RGB,
    /// alpha 0 over the region to fill.
    ///
    /// The inner edge is feathered so the seam between photograph and
    /// continuation is a ramp rather than a rectangle the eye can find.
    static func overscanRingMask(
        canvas: CGSize,
        overscan: CGFloat,
        feather: CGFloat = 0.01
    ) throws -> CGImage {

        let extent = CGRect(origin: .zero, size: canvas)
        let inner = CGSize(
            width: (canvas.width / overscan).rounded(),
            height: (canvas.height / overscan).rounded()
        )
        let innerRect = CGRect(
            x: ((canvas.width - inner.width) / 2).rounded(),
            y: ((canvas.height - inner.height) / 2).rounded(),
            width: inner.width,
            height: inner.height
        )

        // `inpaintAlphaMask` wants the region to FILL as white — that is the
        // convention every other mask in this pipeline follows, and getting it
        // backwards here would have asked the model to repaint the photograph
        // and preserve the blurred smear around it.
        //
        // So: white everywhere, then the photograph's own rectangle knocked
        // black on top of it. White ring, black centre.
        let fillRegion0 = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: extent)
        let centre = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: innerRect)
        var fillRegion = centre.composited(over: fillRegion0).cropped(to: extent)

        if feather > 0 {
            let soften = CIFilter.gaussianBlur()
            soften.inputImage = fillRegion.clampedToExtent()
            soften.radius = Float(max(canvas.width, canvas.height) * feather)
            fillRegion = (soften.outputImage ?? fillRegion).cropped(to: extent)
        }

        return try MaskAlgebra.inpaintAlphaMask(fromMatte: fillRegion)
            .cropped(to: extent)
            .render(cropping: extent)
    }

    /// Removes whatever `core` marks and floods the gap with surrounding colour.
    static func floodBehindSubject(in image: CGImage, core: CGImage) throws -> CGImage {
        let extent = CGRect(origin: .zero, size: image.size)
        let punched = try ResilientBackgroundFiller.punchingHole(in: image, using: core)
        return try LocalBackgroundFiller
            .pushPull(punched.ci, extent: extent)
            .render(cropping: extent)
    }

    static func composite(fill: CGImage, over original: CGImage, hole: CGImage) throws -> CGImage {
        let extent = CGRect(origin: .zero, size: original.size)
        let holeMask = LocalBackgroundFiller.holeMask(fromAPIMask: hole.ci).cropped(to: extent)

        // A filler is free to return a different pixel size — LaMa is resolution
        // robust and every client resamples on the way back, but not all of them
        // land exactly on the source grid.
        let conformed = MatteCompositor.conform(fill.ci, to: extent)

        let merged = MatteCompositor.blend(
            input: conformed,
            background: original.ci,
            mask: holeMask,
            extent: extent
        )
        return try merged.render(cropping: extent)
    }
}

// MARK: - Prompt construction

public enum InpaintingPrompt {

    /// A prompt shaped for *continuation* rather than *invention*.
    ///
    /// Two failure modes dominate here, and both come from the prompt rather
    /// than the model. Asking for a scene description ("a sunny beach") makes
    /// the model compose a new picture in the hole, which then does not line up
    /// with the surviving pixels. Asking for a person or object reintroduces a
    /// subject into the space we just cleared — and it lands at the wrong depth,
    /// pinned flat to the backdrop.
    ///
    /// So: describe the *operation*, not the content.
    public static func continuation(sceneHint: String? = nil) -> String {
        var prompt = """
        Fill the transparent region by continuing the surrounding scene exactly. \
        Match the existing perspective, horizon line, lighting direction, colour \
        temperature, focus falloff and film grain. Extend walls, floors, \
        furniture and landscape naturally through the gap so the seam is \
        invisible. Do not add any people, animals, text or new focal objects.
        """
        if let sceneHint, sceneHint.isEmpty == false {
            prompt += " The scene is: \(sceneHint)."
        }
        return prompt
    }
}
