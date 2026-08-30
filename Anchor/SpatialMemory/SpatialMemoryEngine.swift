//
//  SpatialMemoryEngine.swift
//  SpatialMemory — THE INTEGRATION SURFACE
//
//  ============================================================================
//  If you are the developer plugging this into an existing visionOS app, this
//  file is the whole API. Everything else is implementation.
//
//  Three touchpoints, and nothing else is supported:
//
//    1. Build one `SpatialMemoryEngine` for the app's lifetime.
//    2. Ask it for a `MemorySceneModel` per memory you want to show.
//    3. In YOUR RealityView, `content.add(model.root)`, and in YOUR task,
//       `await model.load(...)`.
//
//  This package contributes no windows, no buttons, no navigation and no
//  ImmersiveSpace declaration. `model.root` is a plain RealityKit `Entity` —
//  parent it wherever your scene graph wants it. `model.phase` is @Published so
//  your own loading and error UI can bind to it.
//
//    struct YourImmersiveView: View {
//        @StateObject var memory = engine.makeScene()
//
//        var body: some View {
//            RealityView { content in
//                content.add(memory.root)          //  <- 1
//            }
//            .task {
//                await memory.load(image: cg, sourceData: data,   //  <- 2
//                                  prompt: InpaintingPrompt.continuation())
//            }
//            .onDisappear { memory.tearDown() }     //  <- 3
//        }
//    }
//
//  ============================================================================
//  Targets: Swift 5.10+, visionOS 1.0+
//

import Combine        // ObservableObject and @Published are Combine's, not SwiftUI's.
import CoreGraphics
import Foundation
import RealityKit
import SwiftUI

// MARK: - Engine

@MainActor
public final class SpatialMemoryEngine {

    public struct Configuration: Sendable {
        public var pipeline: PipelineOptions
        public var container: MemoryContainerOptions

        public init(
            pipeline: PipelineOptions = .default,
            container: MemoryContainerOptions = .default
        ) {
            self.pipeline = pipeline
            self.container = container
        }

        public static let `default` = Configuration()
    }

    public let configuration: Configuration
    public let matteCapability: MatteCapability
    private let pipeline: MemoryPipeline

    /// - Parameters:
    ///   - filler: how the occluded background gets produced.
    ///     `InpaintingClient` calls a real endpoint; `LocalBackgroundFiller`
    ///     works offline with no key and no spend.
    ///   - matteSource: how the subject is isolated. `nil` picks Vision on
    ///     device and the elliptical placeholder in a simulator.
    ///   - depthSource: where per-pixel depth comes from. `nil` means the
    ///     camera's own map when the file has one and an image-cue ESTIMATE when
    ///     it does not. On a photo without LiDAR that estimate is the largest
    ///     single source of wrong-looking geometry, because everything
    ///     downstream is exact arithmetic on it.
    public init(
        filler: any BackgroundFilling,
        matteSource: (any MatteSource)? = nil,
        depthSource: (any DepthSource)? = nil,
        configuration: Configuration = .default
    ) {
        let source = matteSource ?? MatteSourceFactory.automatic()
        self.configuration = configuration
        self.matteCapability = MatteCapability(source: source)
        self.pipeline = MemoryPipeline(
            filler: filler,
            segmenter: ForegroundSegmentationService(matteSource: source),
            depthSource: depthSource
        )
    }

    /// No network, no API key, no cost. Backgrounds are redistributed from the
    /// frame rather than hallucinated — see `LocalBackgroundFiller`.
    public static func offline(
        matteSource: (any MatteSource)? = nil,
        configuration: Configuration = .default
    ) -> SpatialMemoryEngine {
        SpatialMemoryEngine(
            filler: LocalBackgroundFiller(),
            matteSource: matteSource,
            configuration: configuration
        )
    }

    /// Real inpainting. Read the key from the keychain, the scheme's
    /// environment, or a server-side token exchange — never from a literal, and
    /// never from Info.plist, both of which ship it inside the app bundle.
    ///
    /// - Parameters:
    ///   - degradeGracefully: when the endpoint fails, fill the hole with
    ///     `LocalBackgroundFiller` instead of failing the whole memory. On by
    ///     default, because a demo that shows a smeared background is worth more
    ///     than one that shows a red error string. `onFillOutcome` tells you
    ///     which of the two you actually got.
    ///   - onFillOutcome: fired once per memory with the route the background
    ///     took. Called off the main actor.
    public static func hosted(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.openai.com/v1/images/edits")!,
        model: String = "gpt-image-1",
        matteSource: (any MatteSource)? = nil,
        configuration: Configuration = .default,
        degradeGracefully: Bool = true,
        onFillOutcome: (@Sendable (BackgroundFillOutcome) -> Void)? = nil
    ) -> SpatialMemoryEngine {
        let client = InpaintingClient(
            configuration: InpaintingConfiguration(
                endpoint: endpoint,
                apiKey: apiKey,
                model: model
            )
        )

        // Spelled out rather than as a ternary: the two branches are different
        // concrete types and only the annotation makes them the same existential.
        let filler: any BackgroundFilling
        if degradeGracefully {
            filler = ResilientBackgroundFiller(primary: client, onOutcome: onFillOutcome)
        } else {
            filler = client
        }

        return SpatialMemoryEngine(
            filler: filler,
            matteSource: matteSource,
            configuration: configuration
        )
    }

    /// Background continuation via LaMa on Replicate. **This is the one to use.**
    ///
    /// Unlike `hosted(...)`, the model behind this cannot put a person in the
    /// hole — it has no text conditioning and no concept of a subject, it only
    /// continues the structure around the mask. For a memory someone is going to
    /// treat as their own, that difference is the whole point: an invented face
    /// standing where a real one stood is a false memory, not a glitch.
    ///
    /// The pipeline's source strategy is forced to `.originalWithMaskOnly`,
    /// because LaMa decides what to erase from the mask and continues the
    /// surroundings better when it can still see what was there. Passing it a
    /// punched-out plate throws away the evidence it works from.
    ///
    /// - Parameters:
    ///   - degradeGracefully: on failure, fall back to `LocalBackgroundFiller`
    ///     rather than failing the whole memory. `onFillOutcome` reports which
    ///     ran.
    ///   - measuredDepth: run a depth model instead of estimating from image
    ///     cues. This is the change that makes the geometry real; the inpainting
    ///     only decides what colour goes in the hole.
    ///   - logsModelOutput: print each prediction's output shape. Leave it on
    ///     until the depth model's field names are pinned — a community
    ///     wrapper's output keys are not documented anywhere the app can reach,
    ///     and a wrong key is otherwise indistinguishable from a network fault.
    public static func replicate(
        apiToken: String,
        model: String = "allenhooo/lama",
        version: String? = nil,
        matteSource: (any MatteSource)? = nil,
        configuration: Configuration = .default,
        degradeGracefully: Bool = true,
        measuredDepth: Bool = true,
        depthConfiguration: ReplicateDepthConfiguration = .init(),
        logsModelOutput: Bool = true,
        onFillOutcome: (@Sendable (BackgroundFillOutcome) -> Void)? = nil
    ) -> SpatialMemoryEngine {

        let client = ReplicateInpaintingClient(
            configuration: ReplicateConfiguration(
                apiToken: apiToken,
                model: model,
                version: version
            )
        )

        // The estimator keeps its guided refinement — it needs the photograph's
        // edges to know where anything is. A depth model that already traces
        // boundaries does not, and running the filter over it would soften what
        // it was chosen for.
        var depthSource: (any DepthSource)?
        if measuredDepth {
            let api = ReplicateAPI(token: apiToken, logsRawOutput: logsModelOutput)
            depthSource = FallbackDepthSource(
                primary: ReplicateDepthSource(api: api, configuration: depthConfiguration),
                fallback: RefinedDepthSource(
                    base: DepthSourceFactory.automatic(refinement: nil),
                    refinement: .default
                )
            )
        }

        let filler: any BackgroundFilling
        if degradeGracefully {
            filler = ResilientBackgroundFiller(primary: client, onOutcome: onFillOutcome)
        } else {
            filler = client
        }

        var tuned = configuration
        tuned.pipeline.sourceStrategy = .originalWithMaskOnly

        return SpatialMemoryEngine(
            filler: filler,
            matteSource: matteSource,
            depthSource: depthSource,
            configuration: tuned
        )
    }

    /// One per memory. Hold it with `@StateObject` in the view that owns it.
    public func makeScene() -> MemorySceneModel {
        MemorySceneModel(
            pipeline: pipeline,
            pipelineOptions: configuration.pipeline,
            containerOptions: configuration.container
        )
    }
}

// MARK: - What the host UI should tell the user

/// Whether the subject cutout will be real. Surface this rather than letting a
/// placeholder silhouette look like a bug.
public enum MatteCapability: Sendable, Equatable {

    /// Vision on real hardware. Production quality.
    case onDevice
    /// A cutout supplied by the app. Quality is whatever produced it.
    case suppliedCutout
    /// A drawn ellipse. Geometry and rendering are exercised; the silhouette is
    /// meaningless.
    case placeholder

    init(source: any MatteSource) {
        switch source {
        case is VisionMatteSource:       self = .onDevice
        case is AlphaChannelMatteSource: self = .suppliedCutout
        default:                         self = .placeholder
        }
    }

    public var isProductionQuality: Bool { self != .placeholder }

    public var explanation: String {
        switch self {
        case .onDevice:
            return "Subject isolated on device."
        case .suppliedCutout:
            return "Using a supplied cutout."
        case .placeholder:
            return """
            Placeholder silhouette. Vision's foreground segmentation has no CPU \
            path and cannot run in a simulator, so the shape is a drawn ellipse. \
            Everything else is real.
            """
        }
    }
}

// MARK: - Scene model

/// Owns one memory's entity and its loading state.
///
/// The `root` entity exists from `init` and never changes identity. That is the
/// point: `RealityViewContent` is only valid inside the `make` and `update`
/// closures, so an async task finishing forty seconds later has nothing to add
/// itself to. Adding an empty root synchronously gives it a stable attachment
/// point, and the space opens immediately instead of waiting on the pipeline.
@MainActor
public final class MemorySceneModel: ObservableObject {

    /// Parent this into your RealityView's content. Always safe to add, even
    /// before `load` is called or if `load` fails.
    public let root: Entity

    /// Bind your loading and error UI to this.
    @Published public private(set) var phase: MemorySceneModel.Phase = .idle

    /// Available once loading succeeds — exposes `setForegroundDistance(_:)` and
    /// `stopAudio()` if you want runtime controls.
    public private(set) var container: MemoryContainer?

    /// The computed layout, for a host UI that wants to show or tune the numbers.
    public private(set) var layout: ParallaxLayout?

    /// Try Apple's own spatial-scene generator before the custom pipeline.
    ///
    /// On real hardware it is the better result — same model Photos uses, depth
    /// and parallax solved in one component. In the Simulator `generate()`
    /// throws, and the custom pipeline picks the memory up in the same call. So
    /// this stays on for both: one binary, best available result on whatever it
    /// is running.
    public var prefersAppleSpatialScene = true

    /// Which renderer produced the memory on screen. `nil` until one has.
    @Published public private(set) var usedAppleSpatialScene: Bool?

    /// Where Apple's scene sits relative to the immersive space's origin, which
    /// is the floor beneath the wearer.
    ///
    /// The default puts it at eye height, two metres out — a picture across the
    /// room. Pulling it in (less negative Z) turns it into a window you are
    /// standing at rather than looking towards. Below about a metre the stereo
    /// disparity gets uncomfortable to hold for long, so treat 1.0 as the floor
    /// rather than a target.
    public var appleScenePosition: SIMD3<Float> = [0, 1.5, -2]

    /// Present a spatial photo's captured stereo pair rather than generating
    /// depth from its flat master. See `AppleSpatialScene.makeEntity`.
    public var prefersCapturedStereo = true

    /// Where the CUSTOM container sits, and it is not the same convention as
    /// `appleScenePosition`.
    ///
    /// Every equation in `ParallaxGeometry` is written from the viewer's HEAD:
    /// the layers sit at negative Z from the eye, and the container's own
    /// transform is assumed to be identity relative to that. A `.full`
    /// ImmersiveSpace, though, puts its origin on the FLOOR — so adding the
    /// container at identity drops the entire reconstruction to ankle height
    /// and the room appears to have sunk. Lifting it to eye height restores the
    /// assumption the geometry was written under.
    public var customScenePosition: SIMD3<Float> = [0, 1.5, 0]

    /// Also paint the enclosing ambient sphere when Apple's renderer wins.
    ///
    /// Off by default, and that is a judgement rather than an oversight:
    /// `.spatial3DImmersive` already extends Apple's own presentation outward,
    /// so a second surround mostly duplicates it. Turn it on if the periphery
    /// still reads as black on your hardware — it is one draw call.
    public var appleSceneAmbientSurround = false

    /// Audio attached to an Apple-rendered scene, which has no MemoryContainer
    /// to hold it. Tracked here so `tearDown()` can stop it.
    private var ambienceAudio: AudioPlaybackController?

    /// `true` when the relief came from the camera's own depth or disparity
    /// map, `false` when it was estimated from image cues, `nil` before a
    /// memory has loaded.
    ///
    /// Worth putting in front of the user. "Wavy and confused" geometry is what
    /// the estimator looks like when it is wrong, and it is indistinguishable
    /// from a broken measured path unless something says which one ran.
    @Published public private(set) var depthWasMeasured: Bool?

    /// A one-line summary of what the pipeline actually produced, for reading
    /// back on device where no debugger or console is attached.
    ///
    /// Reports the MEAN COLOUR of the textures the scene is about to be painted
    /// with, because "the room looks dark" and "the textures are black" are
    /// different faults with different fixes, and from inside a headset they
    /// are indistinguishable.
    @Published public private(set) var diagnostics: String?

    public enum Phase: Sendable, Equatable {
        case idle
        case segmenting
        case fillingBackground
        case building
        case ready
        case failed(String)

        public var isLoading: Bool {
            switch self {
            case .segmenting, .fillingBackground, .building: return true
            default: return false
            }
        }
    }

    private let pipeline: MemoryPipeline
    private let pipelineOptions: PipelineOptions
    private let containerOptions: MemoryContainerOptions

    init(
        pipeline: MemoryPipeline,
        pipelineOptions: PipelineOptions,
        containerOptions: MemoryContainerOptions
    ) {
        let root = Entity()
        root.name = "SpatialMemoryRoot"
        self.root = root
        self.pipeline = pipeline
        self.pipelineOptions = pipelineOptions
        self.containerOptions = containerOptions
    }

    /// Runs the pipeline and installs the result under `root`.
    ///
    /// Call from a `.task`, so closing the space cancels it — that unwinds the
    /// URLSession upload rather than leaking a 60-second request. Safe to call
    /// again; the previous memory is torn down first.
    ///
    /// - Parameter sourceData: the original file bytes. Optional, but without
    ///   them the field of view cannot be read from EXIF and falls back to a
    ///   63° default — which is the difference between the reconstruction
    ///   feeling like the photograph and feeling like a poster of it.
    public func load(
        image: CGImage,
        sourceData: Data? = nil,
        prompt: String
    ) async {
        tearDown()

        // ------------------------------------------------------------------
        // Apple's path first, when the hardware can run it.
        //
        // Not gated on `targetEnvironment(simulator)`: Apple's own note is that
        // a Spatial3DImage can be CONSTRUCTED in the Simulator and only
        // `generate()` throws, so the honest test is whether it worked, not
        // where we think we are. Needs the original bytes — it reads the file,
        // not our decoded raster.
        // ------------------------------------------------------------------
        if prefersAppleSpatialScene, let bytes = sourceData {
            if #available(visionOS 26.0, *) {
                do {
                    let entity = try await AppleSpatialScene.makeEntity(
                        from: bytes,
                        position: appleScenePosition,
                        preferCapturedStereo: prefersCapturedStereo
                    )
                    root.addChild(entity)

                    // Apple solves the picture. The room around it and the sound
                    // inside it are still ours — and they are what turn a very
                    // good spatial photo into somewhere a person is standing.
                    //
                    // Both are best-effort: a memory that renders without its
                    // soundtrack is a lesser memory, not a failed one, so
                    // neither is allowed to take the scene down with it.
                    if appleSceneAmbientSurround,
                       let sphere = try? await MemoryAmbience.ambientSphere(
                           from: image,
                           radius: containerOptions.ambientRadius
                       ) {
                        root.addChild(sphere)
                    }

                    if let track = pipelineOptions.audioResourceName {
                        ambienceAudio = try? await MemoryAmbience.attachSpatialAudio(
                            named: track,
                            to: entity,
                            gain: containerOptions.audioGain,
                            directivityFocus: containerOptions.audioDirectivityFocus,
                            rolloffFactor: containerOptions.audioRolloffFactor,
                            offset: containerOptions.audioOffset,
                            loop: containerOptions.loopAudio
                        )
                    }

                    usedAppleSpatialScene = true
                    phase = .ready
                    return
                } catch is CancellationError {
                    phase = .idle
                    return
                } catch {
                    print("[SpatialMemory] Apple spatial scene unavailable — "
                          + "\(error.localizedDescription) Falling back to the custom pipeline.")
                }
            }
        }
        usedAppleSpatialScene = false

        do {
            let result = try await pipeline.build(
                from: image,
                sourceData: sourceData,
                prompt: prompt,
                options: pipelineOptions,
                onPhase: { [weak self] phase in
                    // Fired from the pipeline actor, so hop back.
                    Task { @MainActor in self?.apply(phase) }
                }
            )

            try Task.checkCancellation()

            diagnostics = Self.summarise(result)

            phase = .building

            let container = try await MemoryContainer.make(
                assets: result.assets,
                layout: result.layout,
                options: containerOptions
            )

            // Attach invisible, then fade in, so the scene does not pop into
            // existence the instant the last texture uploads. OpacityComponent
            // multiplies through the subtree, so one component fades backdrop
            // and foreground together and keeps their relative alpha intact —
            // fading the two materials separately would let the backdrop show
            // through the subject mid-transition.
            container.components.set(OpacityComponent(opacity: 0))
            container.position = customScenePosition
            root.addChild(container)
            self.container = container
            self.layout = result.layout
            self.depthWasMeasured = result.assets.depth?.isMeasured

            let fade = FromToByAnimation<Float>(
                name: "memoryFadeIn",
                from: 0.0,
                to: 1.0,
                duration: 0.8,
                timing: .easeOut,
                bindTarget: .opacity      // requires the OpacityComponent set above
            )
            if let resource = try? AnimationResource.generate(with: fade) {
                container.playAnimation(resource)
            } else {
                container.components.set(OpacityComponent(opacity: 1))
            }

            phase = .ready

        } catch is CancellationError {
            // The space closed mid-flight. Nothing to report.
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Removes the memory and stops its audio. Call from `onDisappear`.
    public func tearDown() {
        container?.stopAudio()
        ambienceAudio?.stop()
        ambienceAudio = nil
        container?.removeFromParent()
        root.children.removeAll()
        container = nil
        layout = nil
        depthWasMeasured = nil
        usedAppleSpatialScene = nil
        if phase != .idle { phase = .idle }
    }

    /// Mean RGB of the textures the scene will wear, plus the facts that decide
    /// whether the geometry is measured or guessed.
    private static func summarise(_ result: MemoryBuildResult) -> String {
        var parts: [String] = []

        parts.append("depth " + (result.assets.depth?.isMeasured == true ? "MEASURED" : "estimated"))
        parts.append(String(format: "fov %.0f°", result.layout.horizontalFOV * 180 / .pi))
        parts.append(String(
            format: "fg %.1fm bg %.1fm",
            result.layout.foregroundDistance,
            result.layout.backgroundDistance
        ))
        parts.append("bg " + meanDescription(result.assets.background))
        if let layer = result.assets.backgroundLayer {
            parts.append("layer " + meanDescription(layer))
        }
        parts.append("fg " + meanDescription(result.assets.foregroundColor))
        if let ambient = result.assets.ambient {
            parts.append("amb " + meanDescription(ambient))
        }
        return parts.joined(separator: "  ·  ")
    }

    /// Mean of the raw RGBA bytes, sampled sparsely. Deliberately reads the
    /// CGImage's own buffer rather than re-rendering: the question being asked
    /// is what is actually IN the texture.
    private static func meanDescription(_ image: CGImage) -> String {
        guard let data = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else { return "?" }
        let length = CFDataGetLength(data)
        let stride = image.bitsPerPixel / 8
        guard stride >= 3, length >= stride else { return "?" }

        var sums = [Int](repeating: 0, count: min(stride, 4))
        var count = 0
        var i = 0
        while i + stride <= length {
            for c in 0..<sums.count { sums[c] += Int(pointer[i + c]) }
            count += 1
            i += stride * 97
        }
        guard count > 0 else { return "?" }
        return sums.map { String(Int(Double($0) / Double(count))) }.joined(separator: "/")
    }

    private func apply(_ pipelinePhase: MemoryPipelinePhase) {
        switch pipelinePhase {
        case .segmenting:     phase = .segmenting
        case .inpainting:     phase = .fillingBackground
        case .ready:          break            // .building follows on this actor
        case .failed(let m):  phase = .failed(m)
        }
    }
}
