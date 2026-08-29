//
//  MemoryContainer.swift
//  SpatialMemory — PHASE 3b: Scene reconstruction & spatial audio
//
//  Assembles the two-layer parallax rig. The container's own transform is
//  identity and it is added at the ImmersiveSpace origin, so "the viewer's
//  starting head position" and "the container's origin" are the same point —
//  which is the assumption every equation in ParallaxGeometry is built on.
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import Foundation
import RealityKit
import simd

#if canImport(UIKit)
import UIKit          // `UnlitMaterial.BaseColor(tint:texture:)` takes a UIColor on visionOS.
#endif

// MARK: - Assembly inputs

/// `@unchecked Sendable`: CGImage is an immutable CF value; see ImagingCore.swift.
public struct MemoryAssets: @unchecked Sendable {

    /// The hallucinated background, restored to the source aspect ratio.
    public let background: CGImage

    /// The ORIGINAL, un-premultiplied source frame. This becomes the foreground
    /// layer's base colour.
    ///
    /// Deliberately not the RGBA cutout: Core Image emits premultiplied alpha,
    /// so a cutout's edge pixels have already been multiplied toward black. Feed
    /// that in as base colour and every silhouette picks up a dark rim. Handing
    /// RealityKit the untouched RGB and steering opacity from a *separate*
    /// texture keeps the edge colours honest.
    public let foregroundColor: CGImage

    /// The feathered matte. Drives `blending`'s opacity texture.
    public let foregroundMatte: CGImage

    /// Opacity ramp for the backdrop: solid across the photograph, falling to
    /// zero at the padded rim. Without it the backdrop ends in a hard rectangle
    /// hanging in space, which is the single biggest reason a reconstruction
    /// reads as "a picture in a void" rather than as a place.
    public let backdropVignette: CGImage?

    /// Small, darkened wash of the same photograph, painted on a large
    /// enclosing sphere so the periphery is lit by the memory's own colours
    /// instead of by black.
    public let ambient: CGImage?

    /// How much larger `background` is than the original frame. Must match what
    /// the mesh is built with or the texture will not line up.
    public let backdropOverscan: Float

    /// Per-pixel depth. When present the foreground stops being a flat plane and
    /// becomes a displaced, torn mesh — every pixel at its own distance, and
    /// holes at the silhouettes where the backdrop shows through. This is the
    /// difference between a cutout that slides and a scene with shape.
    public let depth: DepthMap?

    /// Colour for the background layer: the photograph with the model's work
    /// composited into the occluded region and nowhere else. Same pixel grid as
    /// `foregroundColor`, un-padded — the padding lives on `background`, which
    /// is a different surface.
    public let backgroundLayer: CGImage?

    /// Depth for the background layer: `depth` with the near field removed and
    /// its geometry diffused in from the rim. Present together with
    /// `backgroundLayer` or not at all.
    public let backgroundDepth: DepthMap?

    /// The near/far cut the two layers are split on. Must be the value the
    /// inpainting matte was built at, or the colour and the geometry disagree
    /// about where the subject ends.
    public let nearFieldThreshold: Float

    /// How far BEYOND that cut the foreground mesh is allowed to extend, in
    /// normalized depth.
    ///
    /// This margin is the whole reason the silhouettes stop being a staircase.
    /// A mesh can only be cut on a cell boundary, so any geometric edge is
    /// quantised to the grid — that fringe of spikes around every head is a
    /// binary coverage test aliasing at 1/384 of the frame, and no threshold
    /// tuning fixes it because the problem is that the edge is geometry at all.
    ///
    /// So the visible edge stops being geometry. The matte — feathered, at full
    /// image resolution — drives opacity, and the mesh is grown past where that
    /// matte has already fallen to zero. The staircase still exists; it is just
    /// out in a region that is fully transparent, where nobody can see it.
    public let foregroundCoverageMargin: Float

    /// Optional looping ambience anchored to the subject.
    public let audioResourceName: String?

    public init(
        background: CGImage,
        foregroundColor: CGImage,
        foregroundMatte: CGImage,
        backdropVignette: CGImage? = nil,
        ambient: CGImage? = nil,
        backdropOverscan: Float = 1.0,
        depth: DepthMap? = nil,
        backgroundLayer: CGImage? = nil,
        backgroundDepth: DepthMap? = nil,
        nearFieldThreshold: Float = 0.42,
        foregroundCoverageMargin: Float = 0.10,
        audioResourceName: String? = nil
    ) {
        self.background = background
        self.foregroundColor = foregroundColor
        self.foregroundMatte = foregroundMatte
        self.backdropVignette = backdropVignette
        self.ambient = ambient
        self.backdropOverscan = backdropOverscan
        self.depth = depth
        self.backgroundLayer = backgroundLayer
        self.backgroundDepth = backgroundDepth
        self.nearFieldThreshold = nearFieldThreshold
        self.foregroundCoverageMargin = foregroundCoverageMargin
        self.audioResourceName = audioResourceName
    }
}

public struct MemoryContainerOptions: Sendable {

    public enum BackdropStyle: Sendable {
        /// Spherical cap at constant radius with perspective-exact UVs.
        /// Overscan comes from `MemoryAssets.backdropOverscan`, because the mesh
        /// and the padded texture have to agree on it.
        case curved
        /// Flat plane. The literal reconstruction of the film plane.
        case flat
    }

    /// Radius of the enclosing ambient sphere, in metres. Well outside the
    /// backdrop so it never occludes anything.
    public var ambientRadius: Float

    /// Normalized depth jump above which a depth-mesh triangle is discarded.
    /// Lower tears more eagerly: cleaner silhouettes, more holes for the
    /// backdrop to show through. Raise it if the scene is coming apart into
    /// confetti; lower it if the subject is smearing into the wall.
    /// Default 0.15 — see the initializer for why.
    public var tearThreshold: Float

    public var backdropStyle: BackdropStyle
    /// Relative decibels. `Audio.Decibel` is a `Double`, and the useful range is
    /// `[-Double.infinity, 0]` — 0 is nominal, not "off".
    public var audioGain: Double
    public var audioDirectivityFocus: Double
    public var audioRolloffFactor: Double
    /// Where the emitter sits inside the foreground plane's local space, in
    /// metres. `[0, 0, 0]` is the plane's centre. Nudge it to sit on the
    /// subject's head or mouth.
    public var audioOffset: SIMD3<Float>
    public var loopAudio: Bool

    public init(
        backdropStyle: BackdropStyle = .curved,
        ambientRadius: Float = 14,
        // 0.15, not the 0.055 this started at. A measured iPhone depth map
        // carries sensor noise at the silhouettes, and at 0.055 that noise
        // alone clears the bar — the mesh drops triangles all over the
        // subject's edge and comes apart into confetti. 0.15 rides over the
        // noise and still tears at a real depth cliff. If the subject starts
        // smearing back into the wall, come down from here; do not go back
        // below ~0.08 on measured depth.
        tearThreshold: Float = 0.15,
        audioGain: Double = -6,
        audioDirectivityFocus: Double = 0.4,
        audioRolloffFactor: Double = 2,
        audioOffset: SIMD3<Float> = .zero,
        loopAudio: Bool = true
    ) {
        self.backdropStyle = backdropStyle
        self.ambientRadius = ambientRadius
        self.tearThreshold = tearThreshold
        self.audioGain = audioGain
        self.audioDirectivityFocus = audioDirectivityFocus
        self.audioRolloffFactor = audioRolloffFactor
        self.audioOffset = audioOffset
        self.loopAudio = loopAudio
    }

    public static let `default` = MemoryContainerOptions()
}

// MARK: - The container

@MainActor
public final class MemoryContainer: Entity {

    public private(set) var backdropEntity: ModelEntity?
    /// The room's own depth mesh, when the pipeline produced a background layer.
    public private(set) var backgroundLayerEntity: ModelEntity?
    public private(set) var ambientEntity: ModelEntity?
    public private(set) var foregroundEntity: ModelEntity?
    public private(set) var audioEmitter: Entity?
    public private(set) var layout: ParallaxLayout?
    private var audioController: AudioPlaybackController?

    /// Metre dimensions the foreground mesh was actually generated at. Runtime
    /// re-seating scales relative to this, never relative to the current scale,
    /// so repeated adjustments cannot drift.
    private var baseForegroundSize: SIMD2<Float> = .one

    /// True when the foreground is a displaced depth mesh rather than a plane.
    public private(set) var isDepthMeshed = false

    public required init() {
        super.init()
        self.name = "MemoryContainer"
    }

    // MARK: Factory

    /// Builds the full rig. Every RealityKit resource type is `@MainActor`, so
    /// this is too — which is exactly why the expensive Vision and network work
    /// happens in `MemoryPipeline` *before* we get here. By the time this runs
    /// there is nothing left to do but upload textures.
    public static func make(
        assets: MemoryAssets,
        layout: ParallaxLayout,
        options: MemoryContainerOptions = .default
    ) async throws -> MemoryContainer {

        let container = MemoryContainer()
        container.layout = layout

        // ------------------------------------------------------------------
        // AMBIENT SURROUND
        //
        // Painted first and furthest out. A photograph reconstructed at its true
        // field of view subtends about 63°; a headset sees past 100°. Without
        // this the remaining 40° is black, and black is what makes the result
        // read as a picture hanging in a void rather than as a place.
        // ------------------------------------------------------------------
        if let ambient = assets.ambient {
            let ambientTexture = try await TextureFactory.make(
                ambient,
                name: "memory.ambient",
                semantic: .color
            )
            var ambientMaterial = UnlitMaterial()
            ambientMaterial.color = .init(tint: .white, texture: .init(ambientTexture))
            ambientMaterial.blending = .opaque

            // With metric depth the backdrop is wherever the room's far wall
            // actually was, which can be well past a fixed 14 m. The surround
            // has to stay outside it or it starts occluding the scene it is
            // supposed to be behind.
            let ambientRadius = max(options.ambientRadius, layout.backgroundDistance * 1.6)

            let sphere = ModelEntity(
                mesh: .generateSphere(radius: ambientRadius),
                materials: [ambientMaterial]
            )
            sphere.name = "MemoryAmbient"
            // generateSphere winds its triangles for an outside viewer, and we
            // are inside it. Mirroring on X reverses the winding so the inner
            // surface becomes front-facing. It mirrors the texture too, which is
            // invisible on a 128 px wash stretched across a 14 m sphere.
            sphere.scale = [-1, 1, 1]
            container.addChild(sphere)
            container.ambientEntity = sphere
        }

        // ------------------------------------------------------------------
        // BACKGROUND
        // ------------------------------------------------------------------
        let backdropTexture = try await TextureFactory.make(
            assets.background,
            name: "memory.backdrop",
            semantic: .color
        )

        var backdropMaterial = UnlitMaterial()
        backdropMaterial.color = .init(tint: .white, texture: .init(backdropTexture))

        if let vignette = assets.backdropVignette {
            // `.raw`, not `.color`: an opacity ramp is a linear coverage value,
            // and the sRGB transfer function would bend the falloff.
            let vignetteTexture = try await TextureFactory.make(
                vignette,
                name: "memory.backdrop.vignette",
                semantic: .raw
            )
            backdropMaterial.blending = .transparent(
                opacity: .init(scale: 1.0, texture: .init(vignetteTexture))
            )
        } else {
            // No ramp supplied: opaque, and the backdrop ends in a hard edge.
            backdropMaterial.blending = .opaque
        }

        let backdropMesh: MeshResource
        let backdropPosition: SIMD3<Float>

        switch options.backdropStyle {
        case .curved:
            backdropMesh = try BackdropGeometry.curvedBackdrop(
                layout: layout,
                projection: .rectilinear,
                overscan: assets.backdropOverscan
            )
            // The cap's vertices are already absolute offsets from the viewer
            // (position = direction × radius), so its entity transform MUST stay
            // identity. Translating it to −5 m would push it to 10 m.
            backdropPosition = .zero

        case .flat:
            backdropMesh = try BackdropGeometry.flatBackdrop(layout: layout)
            // generatePlane builds in the xy-plane with its normal along +Z, so
            // an untouched plane already faces the viewer. Just push it back.
            backdropPosition = layout.backgroundPosition
        }

        let backdrop = ModelEntity(mesh: backdropMesh, materials: [backdropMaterial])
        backdrop.name = "MemoryBackdrop"
        backdrop.position = backdropPosition
        container.addChild(backdrop)
        container.backdropEntity = backdrop

        // ------------------------------------------------------------------
        // FOREGROUND
        // ------------------------------------------------------------------
        let colorTexture = try await TextureFactory.make(
            assets.foregroundColor,
            name: "memory.foreground.color",
            semantic: .color
        )

        // ------------------------------------------------------------------
        // BACKGROUND LAYER — the room, with its own relief.
        //
        // Tearing the foreground open is only half the trick. Something has to
        // be visible through the holes, and if that something is the flat
        // backdrop five metres away then every silhouette is a window onto a
        // wall at a single uniform distance — which is exactly what "it doesn't
        // look like the room" means when someone says it.
        //
        // So the background is a mesh too: the same depth field with the near
        // field removed and its gap diffused in from the rim, wearing the
        // composited colour. Complete, continuous, and receding properly. The
        // foreground then sits in front of it at its own distances, and moving
        // your head slides one against the other the way a room does.
        // ------------------------------------------------------------------
        if let backgroundDepth = assets.backgroundDepth,
           let backgroundColor = assets.backgroundLayer {

            let layerTexture = try await TextureFactory.make(
                backgroundColor,
                name: "memory.background.layer",
                semantic: .color
            )
            var layerMaterial = UnlitMaterial()
            layerMaterial.color = .init(tint: .white, texture: .init(layerTexture))
            layerMaterial.blending = .opaque

            // No contour test and no coverage limit: this layer must have no
            // holes of its own. Its near field has already been filled in, so
            // the only thing left for `tearThreshold` to catch is a genuine
            // depth cliff in the background itself.
            let backgroundMesh = try DepthMesh.generate(
                depth: backgroundDepth,
                layout: layout,
                nearDistance: layout.foregroundDistance,
                farDistance: layout.backgroundDistance * 0.9,
                tearThreshold: options.tearThreshold,
                contourThreshold: nil,
                coverage: .whole
            )

            let roomLayer = ModelEntity(mesh: backgroundMesh, materials: [layerMaterial])
            roomLayer.name = "MemoryBackgroundLayer"
            // Vertices are absolute offsets from the viewer, as with every other
            // perspective-built surface here, so the transform stays identity.
            roomLayer.position = .zero
            container.addChild(roomLayer)
            container.backgroundLayerEntity = roomLayer
        }

        let foreground: ModelEntity

        if let depth = assets.depth {
            // ----------------------------------------------------------------
            // DEPTH MESH — every pixel at its own distance.
            //
            // No matte and no transparency: the mesh *is* the frame. Where the
            // depth jumps, triangles are dropped rather than blended, so the
            // silhouettes are genuine holes and the inpainted backdrop shows
            // through them. That is what makes the scene hold together when the
            // viewer moves, instead of a cutout sliding over a picture.
            // ----------------------------------------------------------------
            var meshMaterial = UnlitMaterial()
            meshMaterial.color = .init(tint: .white, texture: .init(colorTexture))

            if assets.backgroundDepth != nil {
                // `.raw`, not `.color`. A matte is linear coverage, not
                // perceptual colour, and tagging it `.color` applies the
                // sRGB→linear transfer function — which drags every mid-tone in
                // the feather downward and hands back the hard, thin edge the
                // feather existed to avoid.
                let matteTexture = try await TextureFactory.make(
                    assets.foregroundMatte,
                    name: "memory.depthmesh.matte",
                    semantic: .raw
                )
                // `opacityThreshold` stays UNSET on purpose: setting it switches
                // RealityKit to alpha-test, which quantises every fragment to
                // fully on or fully off and throws the feather away — putting
                // the staircase straight back, this time at pixel resolution.
                meshMaterial.blending = .transparent(
                    opacity: .init(scale: 1.0, texture: .init(matteTexture))
                )
            } else {
                meshMaterial.blending = .opaque
            }

            // Far is pulled inside the backdrop's radius so the most distant
            // surfaces cannot punch through it.
            // Two changes from a single-layer build, and both are what stops
            // the fringe of spikes around every silhouette.
            //
            // `coverage` limits this mesh to the near field, so the boundary is
            // a clean closed contour rather than whatever the gradient test
            // happened to catch cell by cell — no more tearing on one cell and
            // stretching across its neighbour because the hair and the panel
            // behind it are the same brightness.
            //
            // `contourThreshold` says the same thing for any triangle that
            // slips through, and costs one comparison.
            //
            // Everything beyond the near field is drawn by the background layer,
            // so nothing is lost by not drawing it twice.
            // Without a background layer there is nothing behind to reveal, so
            // the foreground has to be the whole frame and tear the old way.
            //
            // With one, the cut moves OUTWARD by the coverage margin. The matte
            // decides what you see; the geometry is cut further out, in fully
            // transparent territory, so its unavoidable grid-scale staircase is
            // invisible. Cutting the geometry at the same contour the matte uses
            // is what produced the fringe of spikes — two edges in the same
            // place, one soft and one quantised, and the quantised one wins.
            let layered = assets.backgroundDepth != nil
            var contour: Float?
            var coverage: DepthMesh.Coverage = .whole
            if layered {
                let outer = assets.nearFieldThreshold + assets.foregroundCoverageMargin
                contour = outer
                coverage = .nearerThan(outer)
            }

            let mesh = try DepthMesh.generate(
                depth: depth,
                layout: layout,
                nearDistance: layout.foregroundDistance,
                farDistance: layout.backgroundDistance * 0.9,
                tearThreshold: options.tearThreshold,
                contourThreshold: contour,
                coverage: coverage
            )

            foreground = ModelEntity(mesh: mesh, materials: [meshMaterial])
            foreground.name = "MemoryDepthMesh"
            // Vertices are already absolute offsets from the viewer, exactly as
            // with the curved backdrop, so the transform stays identity.
            foreground.position = .zero
            container.baseForegroundSize = layout.foregroundSize
            container.isDepthMeshed = true

        } else {
            // ----------------------------------------------------------------
            // FLAT PLANE — the two-layer fallback.
            // ----------------------------------------------------------------

            // `.raw` is load-bearing. A matte is not perceptual colour — it is a
            // linear coverage value. Tagging it `.color` makes RealityKit apply
            // the sRGB→linear transfer function, which drags every mid-tone in
            // the feather ramp downward and produces a visibly thin, hard edge.
            let matteTexture = try await TextureFactory.make(
                assets.foregroundMatte,
                name: "memory.foreground.matte",
                semantic: .raw
            )

            var planeMaterial = UnlitMaterial()
            planeMaterial.color = .init(tint: .white, texture: .init(colorTexture))
            // Per Apple's documentation, when `texture` is non-nil RealityKit
            // reads opacity from it and ignores `scale` — so `scale: 1.0` is the
            // documented no-op and the matte is fully in charge.
            planeMaterial.blending = .transparent(
                opacity: .init(scale: 1.0, texture: .init(matteTexture))
            )
            // `opacityThreshold` is deliberately LEFT UNSET. Assigning it
            // switches RealityKit to alpha-test rendering, which quantises every
            // fragment to fully-on or fully-off and throws the feather away.

            let size = layout.foregroundSize
            foreground = ModelEntity(
                mesh: .generatePlane(width: size.x, height: size.y),
                materials: [planeMaterial]
            )
            foreground.name = "MemoryForeground"
            foreground.position = layout.foregroundPosition
            container.baseForegroundSize = size
        }

        container.addChild(foreground)
        container.foregroundEntity = foreground

        // ------------------------------------------------------------------
        // SPATIAL AUDIO
        // ------------------------------------------------------------------
        if let resourceName = assets.audioResourceName {
            try await container.attachSpatialAudio(
                named: resourceName,
                to: foreground,
                options: options
            )
        }

        return container
    }

    // MARK: Spatial audio

    /// Anchors a looping audio source to the foreground subject.
    @discardableResult
    public func attachSpatialAudio(
        named resourceName: String,
        to host: Entity,
        bundle: Bundle? = nil,
        options: MemoryContainerOptions = .default
    ) async throws -> AudioPlaybackController {

        // A dedicated child entity, not the plane itself. Two reasons:
        //
        // 1. Apple's documented convention is that a spatial audio source
        //    radiates along its own NEGATIVE z-axis. Our foreground plane is
        //    built by generatePlane with its normal along +Z so that it faces
        //    the viewer — put the emitter on the plane and any non-zero
        //    directivity beams the sound directly away from the listener.
        //    Rotating 180° about Y flips the emitter's −Z onto the plane's +Z.
        //
        // 2. It lets the sound originate from the subject's head rather than
        //    the plane's geometric centre, without moving the plane.
        let emitter = Entity()
        emitter.name = "MemoryAudioEmitter"
        emitter.position = options.audioOffset
        emitter.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])

        // Construct with `gain:` and set the rest as properties. The full
        // memberwise initializer that also takes directivity and
        // distanceAttenuation is visionOS 2.0+; this two-step form is what
        // Apple's own SpatialAudioComponent documentation shows and it compiles
        // against a visionOS 1.0 deployment target.
        var spatial = SpatialAudioComponent(gain: options.audioGain)
        spatial.directivity = .beam(focus: options.audioDirectivityFocus)
        // Rolloff factor 2 approximates inverse-square falloff: every doubling
        // of distance costs roughly 6 dB. At the foreground's 1.5 m the source
        // sits just outside arm's reach, so the viewer leaning in gets an
        // audible, and correct, level increase.
        spatial.distanceAttenuation = .rolloff(factor: options.audioRolloffFactor)
        emitter.components.set(spatial)

        host.addChild(emitter)
        self.audioEmitter = emitter

        let configuration = AudioFileResource.Configuration(shouldLoop: options.loopAudio)
        let resource = try await AudioFileResource(
            named: resourceName,
            in: bundle,
            configuration: configuration
        )

        // prepareAudio returns a controller without starting playback, so the
        // caller can fade in, seek, or gate on the fade-in of the visuals.
        let controller = emitter.prepareAudio(resource)
        controller.play()
        self.audioController = controller
        return controller
    }

    public func stopAudio() {
        audioController?.stop()
    }

    // MARK: Runtime tuning

    /// Re-seats both layers at new distances without rebuilding any resource.
    ///
    /// Only the foreground plane needs rescaling: the ratio D_fg / D_bg changes,
    /// and the plane's metre dimensions must track it or the layers stop
    /// registering. The backdrop's own size is baked into its mesh, so changing
    /// `backgroundDistance` for a *curved* backdrop requires a mesh rebuild —
    /// this fast path therefore only moves the foreground.
    public func setForegroundDistance(_ distance: Float) {
        guard let current = layout, let foreground = foregroundEntity else { return }
        guard distance > 0, distance < current.backgroundDistance else { return }
        // A depth mesh has no single foreground distance to move — its vertices
        // span near to far. Changing the range means rebuilding the mesh.
        guard isDepthMeshed == false else { return }

        let updated = ParallaxLayout(
            horizontalFOV: current.horizontalFOV,
            aspect: current.aspect,
            backgroundDistance: current.backgroundDistance,
            foregroundDistance: distance
        )
        self.layout = updated

        // Same similar-triangles rule, applied as a transform instead of a mesh
        // rebuild. Scale is measured against the size the mesh was BUILT at, so
        // calling this repeatedly cannot compound rounding error.
        //
        //     s = W_fg(new) / W_fg(built)
        //       = (W_bg · D_fg(new) / D_bg) / W_fg(built)
        //
        // Moving the plane without rescaling it — or rescaling without moving
        // it — breaks registration between the layers and the illusion with it.
        let s = updated.foregroundSize.x / baseForegroundSize.x
        foreground.position = updated.foregroundPosition
        foreground.scale = SIMD3(repeating: s)
    }
}

// MARK: - Texture creation across OS versions

public enum TextureFactory {

    /// `TextureResource.generate(from:withName:options:)` is deprecated as of
    /// visionOS 2.0 in favour of the async `init(image:withName:options:)`,
    /// which was introduced in visionOS 2.0. Deployment targets of visionOS 1.0
    /// need both paths.
    ///
    /// Note `CreateOptions.init(semantic:mipmapsMode:)` — the three-argument
    /// overload that also takes `compression:` is visionOS 2.0+ only.
    @MainActor
    public static func make(
        _ image: CGImage,
        name: String,
        semantic: TextureResource.Semantic
    ) async throws -> TextureResource {

        let options = TextureResource.CreateOptions(
            semantic: semantic,
            mipmapsMode: .allocateAndGenerateAll
        )

        if #available(visionOS 2.0, iOS 18.0, macOS 15.0, *) {
            return try await TextureResource(image: image, withName: name, options: options)
        } else {
            return try TextureResource.generate(from: image, withName: name, options: options)
        }
    }
}
